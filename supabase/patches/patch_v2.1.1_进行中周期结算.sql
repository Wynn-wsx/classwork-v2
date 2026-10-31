-- ============================================================
-- V2.1.1 允许对「进行中」的月周期结算（多次结算以最新一次为准）
--   1) monthly_settle：允许 end_date 为空，结算范围截至今天；
--      进行中周期重复结算时，旧结算标记 rolled_back 并清理旧次数/抽选；
--      进行中周期结算不进入 30 分钟维护锁；快照标记 in_progress。
--   2) admin_run_monthly_summary：默认优先「进行中」的月周期，返回体带 in_progress。
-- 幂等：仅 create or replace function，可重复执行。
-- ============================================================

create or replace function public.monthly_settle(p_boundary_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b          public.boundaries;
  v_st         public.settlements;
  v_start      timestamptz;
  v_end        timestamptz;
  v_sd         date;
  v_ed         date;
  v_month_key  text;
  v_individuals jsonb;
  v_groups     jsonb;
  v_second     jsonb;
  v_second_ids uuid[] := '{}';
  v_thr        numeric;
  v_n          int := 10;
  v_reward_thr numeric := 10;
  v_penalty_thr numeric := 5;
  v_top_n      int := 15;
  v_summary    jsonb;
  v_auto_total int := 0;
  v_cards_exp  int := 0;
  v_p          record;
  v_amt        int;
  v_forfeit    jsonb := '[]'::jsonb;
  v_reward_rows jsonb;
  v_penalty_rows jsonb;
  v_auto       int;
  v_rec_cnt    int := 0;
  v_in_progress boolean := false;
begin
  select * into v_b from public.boundaries where id = p_boundary_id;
  if v_b.id is null then
    raise exception '分隔点不存在';
  end if;
  if v_b.type <> 'month' then
    raise exception '该分隔点不是月分隔点';
  end if;

  if v_b.start_date is null then
    raise exception '该月周期缺少起始日期，请先在「设置 → 周期定义」补全';
  end if;

  -- V2.1.1：允许对「进行中」的月周期结算，结算范围截至今天；同一周期多次结算以最新一次为准
  v_in_progress := v_b.end_date is null;
  v_sd := v_b.start_date;
  v_ed := coalesce(v_b.end_date, public.bj_today()) + 1;   -- 取不含上界
  v_start := v_sd::timestamp at time zone 'Asia/Shanghai';
  v_end   := v_ed::timestamp at time zone 'Asia/Shanghai';
  v_month_key := v_b.period_key;

  select * into v_st from public.settlements
   where boundary_id = p_boundary_id and status <> 'rolled_back';
  if v_st.id is not null and v_st.status = 'done' then
    if not v_in_progress then
      return v_st.summary;                        -- 已结束的周期：幂等返回既有结算
    end if;
    -- 进行中的周期：允许重算，把上一次结算标记为回滚，并清掉上次生成的次数与抽选
    update public.settlements
       set status = 'rolled_back',
           note = coalesce(nullif(note, ''), '') || '（进行中周期重新结算覆盖）'
     where id = v_st.id;
    delete from public.lottery_draws
     where period_key = v_month_key
       and source in ('auto', 'monthly_group_penalty', 'weekly_group', 'weekly_group_reward', 'weekly_group_penalty');
    delete from public.lottery_chances where period_key = v_month_key;
    delete from public.lottery_group_chances where period_key = v_month_key;
    update public.boundaries set settled = false where id = p_boundary_id;
  end if;

  -- 维护窗口（设计：月结算期间全站只读 30 分钟）；进行中的周期结算不加维护锁，避免锁住正在录分的班级
  if not v_in_progress then
    update public.app_config
       set maintenance_until = greatest(coalesce(maintenance_until, v_b.boundary_at), v_b.boundary_at)
                               + make_interval(mins => maintenance_minutes),
           updated_at = now()
     where id = 1;
  end if;

  select coalesce((public.cfg()->>'second_class_count')::int, 10),
         coalesce((public.cfg()->>'reward_threshold')::numeric, 10),
         coalesce((public.cfg()->>'penalty_threshold')::numeric, 5),
         coalesce((public.cfg()->>'month_reward_top_n')::int, 15)
    into v_n, v_reward_thr, v_penalty_thr, v_top_n;

  insert into public.settlements (period_key, boundary_id, started_at, status, note)
  values (v_month_key, p_boundary_id, now(), 'running',
          case when v_in_progress
               then format('进行中周期结算（截至 %s）', to_char(public.bj_today(), 'YYYY-MM-DD'))
               else null end);

  -- V2.0.14：当月没有任何有效记录时只写空结算，不产生任何次数/抽选/第二类名单
  select count(*) into v_rec_cnt
    from public.records
   where status = '正常'
     and record_date >= to_char(v_sd, 'YYYY-MM-DD')
     and record_date <  to_char(v_ed, 'YYYY-MM-DD');
  if v_rec_cnt = 0 then
    v_summary := jsonb_build_object(
      'type', 'month', 'month_key', v_month_key,
      'range_start', v_start, 'range_end', (v_ed - 1),
      'groups', '[]'::jsonb, 'individuals', '[]'::jsonb,
      'second_class', '[]'::jsonb, 'second_class_count', 0,
      'reward', jsonb_build_object('rows', '[]'::jsonb, 'forfeit', '[]'::jsonb),
      'penalty', jsonb_build_object('rows', '[]'::jsonb),
      'auto_draw_count', 0, 'cards_expired', 0,
      'empty_month', true, 'in_progress', v_in_progress, 'generated_at', now());
    update public.settlements
       set status = 'done', finished_at = now(), summary = v_summary,
           second_class = '[]'::jsonb, auto_draw_count = 0
     where boundary_id = p_boundary_id and status <> 'rolled_back';
    update public.boundaries set settled = true where id = p_boundary_id;
    perform public.write_audit('monthly_settle_empty', 'boundary', p_boundary_id::text,
      jsonb_build_object('month_key', v_month_key, 'records', 0));
    return v_summary;
  end if;

  -- 个人月积分（加分 / 扣分 / 净分）
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', p.id, 'name', p.name, 'group_name', p.group_name,
           'add', p.add_total, 'ded', p.ded_total, 'net', p.net,
           'rank_add', p.rank_add, 'rank_net', p.rank_net) order by p.rank_add, p.name), '[]'::jsonb)
    into v_individuals
    from (
      select s.id, s.name, s.group_name,
             coalesce(x.add_total, 0) as add_total,
             coalesce(x.ded_total, 0) as ded_total,
             coalesce(x.add_total, 0) - coalesce(x.ded_total, 0) as net,
             rank() over (order by coalesce(x.add_total, 0) desc) as rank_add,
             rank() over (order by coalesce(x.add_total, 0) - coalesce(x.ded_total, 0)) as rank_net
        from public.students s
        left join (
          select rec.student_id,
                 sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                 sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) x on x.student_id = s.id
    ) p;

  -- 小组月积分（参考）
  select coalesce(jsonb_agg(jsonb_build_object(
           'group_name', g.group_name, 'add', g.add_total, 'ded', g.ded_total,
           'net', g.add_total - g.ded_total, 'rank', g.rnk) order by g.rnk), '[]'::jsonb)
    into v_groups
    from (
      select q.group_name,
             sum(q.add_total) as add_total,
             sum(q.ded_total) as ded_total,
             rank() over (order by sum(q.add_total) desc) as rnk
        from (
          select s.group_name,
                 coalesce(x.add_total, 0) as add_total,
                 coalesce(x.ded_total, 0) as ded_total
            from public.students s
            left join (
              select rec.student_id,
                     sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                     sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
                from public.records rec
               where rec.status = '正常'
                 and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
                 and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
               group by rec.student_id
            ) x on x.student_id = s.id
           where s.group_name is not null and s.group_name <> ''
        ) q
       group by q.group_name
    ) g;

  -- 第二类：月净积分倒数十名（并列同分一并计入）
  -- 阈值 = 倒数第 N 名那位的净分（即倒数 N 名里最高的净分），net <= 阈值 的人全部入选（含并列）
  select max(net) into v_thr from (
    select net, row_number() over (order by net asc, name) as rn
      from (
        select s.name, coalesce(x.add_total,0) - coalesce(x.ded_total,0) as net
          from public.students s
          left join (
            select rec.student_id,
                   sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                   sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
              from public.records rec
             where rec.status = '正常'
               and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
               and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
             group by rec.student_id
          ) x on x.student_id = s.id
      ) z
  ) w
   where w.rn <= greatest(coalesce(v_n, 1), 1);

  if v_thr is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'student_id', s.id, 'name', s.name, 'net', coalesce(net.net, 0)) order by coalesce(net.net,0) asc, s.name), '[]'::jsonb),
           coalesce(array_agg(s.id), array[]::uuid[])
      into v_second, v_second_ids
      from public.students s
      left join (
        select rec2.student_id,
               coalesce(sum(case when rec2.points > 0 then rec2.points else 0 end), 0)
             - coalesce(sum(case when rec2.points < 0 then abs(rec2.points) else 0 end), 0) as net
          from public.records rec2
         where rec2.status = '正常'
           and rec2.record_date >= to_char(v_sd, 'YYYY-MM-DD')
           and rec2.record_date <  to_char(v_ed, 'YYYY-MM-DD')
         group by rec2.student_id
      ) net on net.student_id = s.id
     where coalesce(net.net, 0) <= v_thr;
  else
    v_second := '[]'::jsonb;
    v_second_ids := '{}';
  end if;

  -- 奖励次数（V2.0.16 口径，用户确认）：
  --   (a) 月净积分排名前 v_top_n（默认 15）名，不论净分正负，每人 1 次 → chance_type = monthly_top15
  --   (b) 净分正分部分每满 v_reward_thr（默认 10）分追加 1 次，不足不计 → chance_type = monthly_points
  --   并列同分同名次、一并计入
  insert into public.lottery_chances (student_id, period_key, pool_type, chance_type, amount, source_week_key)
  select q.student_id, v_month_key, 'reward', 'monthly_top15', 1, ''
    from (
      select s.id as student_id,
             rank() over (order by coalesce(x.add_total,0) - coalesce(x.ded_total,0) desc) as rk
        from public.students s
        left join (
          select rec.student_id,
                 sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                 sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) x on x.student_id = s.id
    ) q
   where q.rk <= v_top_n
  on conflict (student_id, period_key, chance_type, source_week_key) do nothing;

  insert into public.lottery_chances (student_id, period_key, pool_type, chance_type, amount, source_week_key)
  select q.student_id, v_month_key, 'reward', 'monthly_points', q.amount, ''
    from (
      select s.id as student_id,
             floor(greatest(coalesce(x.add_total,0) - coalesce(x.ded_total,0), 0) / v_reward_thr)::int as amount
        from public.students s
        left join (
          select rec.student_id,
                 sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                 sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) x on x.student_id = s.id
    ) q
   where q.amount > 0
  on conflict (student_id, period_key, chance_type, source_week_key) do nothing;

  -- 惩罚次数（V2.0.16 口径，用户确认）：
  --   基础惩罚 = floor(负分绝对值 / v_penalty_thr)
  --   排名惩罚 = 名单内（月净分倒数 v_n 名，含并列）且本月奖励次数 = 0 → 追加 1 次
  --   抵消     = 基础惩罚与排名惩罚重合时自动减 1（等价于：名单内 final = max(基础, 1)）
  --   封顶     = 单人单月惩罚最多 3 次
  insert into public.lottery_chances (student_id, period_key, pool_type, chance_type, amount, source_week_key)
  select q.student_id, v_month_key, 'penalty',
         case when q.base_points > 0 then 'penalty_points' else 'second_class' end,
         q.final_amount, ''
    from (
      select a.student_id, a.base_points,
             least(
               case when a.in_list and a.reward_total = 0
                    then greatest(a.base_points, 1)
                    else a.base_points end,
               3) as final_amount
        from (
          select s.id as student_id,
                 floor(greatest(-(coalesce(x.add_total,0) - coalesce(x.ded_total,0)), 0) / v_penalty_thr)::int as base_points,
                 (s.id = any(v_second_ids)) as in_list,
                 (case when rank() over (order by coalesce(x.add_total,0) - coalesce(x.ded_total,0) desc) <= v_top_n
                       then 1 else 0 end)
                 + floor(greatest(coalesce(x.add_total,0) - coalesce(x.ded_total,0), 0) / v_reward_thr)::int as reward_total
            from public.students s
            left join (
              select rec.student_id,
                     sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                     sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
                from public.records rec
               where rec.status = '正常'
                 and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
                 and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
               group by rec.student_id
            ) x on x.student_id = s.id
        ) a
    ) q
   where q.final_amount > 0
  on conflict (student_id, period_key, chance_type, source_week_key) do nothing;


  -- 功能卡过期
  v_cards_exp := public.expire_function_cards();

  -- 记录本月应得/已抽情况（供快照与 reward_forfeit 标注）
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', g.student_id, 'name', g.name,
           'amount', g.amount, 'used_before_auto', g.used,
           'remaining_before_auto', g.amount - g.used,
           'top15_bonus', g.top15_bonus, 'net_bonus', g.net_bonus) order by g.name), '[]'::jsonb)
    into v_reward_rows
    from (
      select c.student_id, s.name,
             sum(c.amount)::int as amount,
             sum(c.used_count)::int as used,
             sum(case when c.chance_type = 'monthly_top15' then c.amount else 0 end)::int as top15_bonus,
             sum(case when c.chance_type = 'monthly_points' then c.amount else 0 end)::int as net_bonus
        from public.lottery_chances c join public.students s on s.id = c.student_id
       where c.period_key = v_month_key and c.pool_type = 'reward'
       group by c.student_id, s.name
    ) g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', g.student_id, 'name', g.name, 'chance_type', g.chance_type,
           'amount', g.amount, 'base_amount', g.base_amount, 'rank_amount', g.rank_amount,
           'in_list', g.in_list,
           'used_before_auto', g.used,
           'remaining_before_auto', g.amount - g.used) order by g.name), '[]'::jsonb)
    into v_penalty_rows
    from (
      select c.student_id, s.name,
             min(c.chance_type) as chance_type,
             sum(c.amount)::int as amount,
             sum(case when c.chance_type = 'penalty_points' then c.amount else 0 end)::int as base_amount,
             sum(case when c.chance_type = 'second_class' then c.amount else 0 end)::int as rank_amount,
             (s.id = any(v_second_ids)) as in_list,
             sum(c.used_count)::int as used
        from public.lottery_chances c join public.students s on s.id = c.student_id
       where c.period_key = v_month_key and c.pool_type = 'penalty'
       group by c.student_id, s.name, s.id
    ) g;

  -- 第二类学生未使用的奖励次数：账面标 reward_forfeit（结果照常自动抽、不追回）
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', g.student_id, 'name', g.name,
           'remaining', g.remaining, 'reward_forfeit', true) order by g.name), '[]'::jsonb)
    into v_forfeit
    from (
      select c.student_id, s.name, sum(c.amount - c.used_count)::int as remaining
        from public.lottery_chances c join public.students s on s.id = c.student_id
       where c.period_key = v_month_key and c.pool_type = 'reward'
         and c.used_count < c.amount
         and c.student_id = any(v_second_ids)
       group by c.student_id, s.name
    ) g
   where true;

  -- 未用次数自动抽选（奖励池 + 惩罚池）
  for v_p in
    select distinct c.student_id from public.lottery_chances c
     where c.period_key = v_month_key and c.used_count < c.amount
  loop
    v_auto := public.auto_draw_chances(v_p.student_id, 'reward', v_month_key, 'auto');
    v_auto_total := v_auto_total + v_auto;
    v_auto := public.auto_draw_chances(v_p.student_id, 'penalty', v_month_key, 'auto');
    v_auto_total := v_auto_total + v_auto;
  end loop;

  v_summary := jsonb_build_object(
    'type', 'month',
    'month_key', v_month_key,
    'range_start', v_start,
    'range_end', (v_ed - 1),
    'groups', v_groups,
    'individuals', v_individuals,
    'second_class', v_second,
    'second_class_count', jsonb_array_length(v_second),
    'reward', jsonb_build_object('rows', v_reward_rows, 'forfeit', v_forfeit),
    'penalty', jsonb_build_object('rows', v_penalty_rows),
    'auto_draw_count', v_auto_total,
    'cards_expired', v_cards_exp,
    'in_progress', v_in_progress,
    'generated_at', now()
  );

  update public.settlements
     set status = 'done', finished_at = now(), summary = v_summary,
         second_class = v_second, auto_draw_count = v_auto_total
   where boundary_id = p_boundary_id and status <> 'rolled_back';
  update public.boundaries set settled = true where id = p_boundary_id;

  perform public.notify_audience('admins', '月度结算完成',
    format('%s %s：第二类 %s 人，自动抽选 %s 次，过期功能卡 %s 张。请核对汇总。',
           v_month_key, case when v_in_progress then '周期进行中结算完成' else '月结算完成' end,
           jsonb_array_length(v_second), v_auto_total, v_cards_exp),
    'period', 'settlement', (select id from public.settlements
                              where boundary_id = p_boundary_id and status <> 'rolled_back' limit 1));
  perform public.write_audit('monthly_settle', 'boundary', p_boundary_id::text,
    jsonb_build_object('month_key', v_month_key, 'penalty_rank_list', jsonb_array_length(v_second),
                       'auto_draw_count', v_auto_total, 'cards_expired', v_cards_exp,
                       'in_progress', v_in_progress));
  return v_summary;
end;
$$;
revoke all on function public.monthly_settle(uuid) from public, anon, authenticated;

create or replace function public.admin_run_monthly_summary(p_boundary_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b   public.boundaries;
  v_key text;
  v_res jsonb;
begin
  perform public.require_role(array['super_admin','admin','executive'], '只有管理员、班主任或执行小组可以手动汇总');

  if p_boundary_id is null then
    -- V2.1.1：优先「进行中」的月周期（end_date 为空），否则取最近已开始的月周期
    select * into v_b from public.boundaries
     where type = 'month' and start_date is not null and end_date is null
       and start_date <= public.bj_today()
     order by start_date desc limit 1;
    if v_b.id is null then
      select * into v_b from public.boundaries
       where type = 'month' and start_date is not null and start_date <= public.bj_today()
       order by start_date desc limit 1;
    end if;
  else
    select * into v_b from public.boundaries where id = p_boundary_id;
  end if;

  if v_b.id is null then
    raise exception '没有找到可汇总的月分隔点';
  end if;
  if v_b.type <> 'month' then
    raise exception '该分隔点不是月分隔点';
  end if;
  if v_b.boundary_at is not null and v_b.boundary_at > now() then
    raise exception '该月尚未开始，不能汇总';
  end if;

  -- 月分隔点关闭的是「上一个月」，周期键按被结算的月份推导（settlements.period_key 用的是这个）
  v_key := v_b.period_key;

  -- 覆盖：旧结算记录标记为已回滚（保留审计痕迹），清掉该月已生成的次数与自动抽选
  update public.settlements
     set status = 'rolled_back',
         note = coalesce(nullif(note, ''), '') || '（手动重新汇总覆盖）'
   where boundary_id = v_b.id
     and status <> 'rolled_back';

  delete from public.lottery_draws
   where period_key = v_key
     and source in ('auto', 'monthly_group_penalty', 'weekly_group', 'weekly_group_reward', 'weekly_group_penalty');
  delete from public.lottery_chances where period_key = v_key;
  delete from public.lottery_group_chances where period_key = v_key;
  update public.boundaries set settled = false where id = v_b.id;

  v_res := public.monthly_settle(v_b.id);

  perform public.write_audit('admin_run_monthly_summary', 'boundary', v_b.id::text,
    jsonb_build_object('month_key', v_key));

  return jsonb_build_object('month_key', v_key, 'boundary_id', v_b.id,
    'in_progress', (v_b.end_date is null), 'summary', v_res);
end;
$$;
revoke all on function public.admin_run_monthly_summary(uuid) from public, anon, authenticated;
grant execute on function public.admin_run_monthly_summary(uuid) to authenticated;

-- 自检（全部应为 ok）
select 'monthly_settle 存在' as item, case when count(*)=1 then 'ok' else 'missing' end as r
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='monthly_settle'
union all
select 'admin_run_monthly_summary 存在', case when count(*)=1 then 'ok' else 'missing' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='admin_run_monthly_summary'
union all
select '允许进行中结算（源码含 v_in_progress）',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='monthly_settle'
                            and p.prosrc like '%v_in_progress%') then 'ok' else 'missing' end;

-- 刷新 PostgREST 缓存，让新函数立即生效
notify pgrst, 'reload schema';
