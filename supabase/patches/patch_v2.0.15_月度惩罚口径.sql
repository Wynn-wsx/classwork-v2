-- ============================================================
-- 班级积分管理系统 V2.0.15 补丁：月度惩罚口径 + 手动汇总周期键修正（可重复执行）
-- 适用：已部署 V2.0.14 的数据库（也兼容更早的 V2.0.x）
--
-- 一、月度惩罚口径（用户确认）
--   1) 按排名惩罚名单 = 月净积分倒数 N 名（含并列），不再要求「阈值为负分」；
--      空月（整月 0 条正常记录）仍由空结算守卫直接返回；
--   2) 名单内学生本月若已获得奖励次数 → 不计任何惩罚（0 次）；
--      否则 = max(floor(月扣分/阈值), 1)，保底 1 次记 second_class；
--   3) 名单外学生仍按 floor(月扣分/阈值)，不受奖励影响。
--
-- 二、手动汇总周期键修正
--   admin_run_weekly_summary / admin_run_monthly_summary 之前用「分隔点自身所在周期」
--   作为清理键，导致手动重新汇总时清不掉旧次数/旧抽选（表现为 auto_draw_count 为 0、
--   used_before_auto 已用满）。现统一按「分隔点关闭的那个周/月」推导。
--
-- 执行方式：Supabase SQL Editor 整段执行（幂等）。
-- 执行后请执行：notify pgrst, 'reload schema';
-- 然后到「周期汇总 → 月度结算」对目标月份点「重新结算」即可按新口径重算。
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
begin
  select * into v_b from public.boundaries where id = p_boundary_id;
  if v_b.id is null then
    raise exception '分隔点不存在';
  end if;
  if v_b.type <> 'month' then
    raise exception '该分隔点不是月分隔点';
  end if;

  select * into v_st from public.settlements
   where boundary_id = p_boundary_id and status <> 'rolled_back';
  if v_st.id is not null and v_st.status = 'done' then
    return v_st.summary;
  end if;

  v_end := v_b.boundary_at;
  v_start := coalesce(
    (select max(b.boundary_at) from public.boundaries b
      where b.type = 'month' and b.boundary_at < v_end),
    v_end - interval '1 month');
  v_sd := (v_start at time zone 'Asia/Shanghai')::date;
  v_ed := (v_end at time zone 'Asia/Shanghai')::date;
  v_month_key := to_char((v_end - interval '1 second') at time zone 'Asia/Shanghai', 'YYYY-MM');

  -- 维护窗口（设计：月结算期间全站只读 30 分钟）
  update public.app_config
     set maintenance_until = greatest(coalesce(maintenance_until, v_b.boundary_at), v_b.boundary_at)
                             + make_interval(mins => maintenance_minutes),
         updated_at = now()
   where id = 1;

  select coalesce((public.cfg()->>'second_class_count')::int, 10),
         coalesce((public.cfg()->>'reward_threshold')::numeric, 10),
         coalesce((public.cfg()->>'penalty_threshold')::numeric, 5),
         coalesce((public.cfg()->>'month_reward_top_n')::int, 15)
    into v_n, v_reward_thr, v_penalty_thr, v_top_n;

  insert into public.settlements (period_key, boundary_id, started_at, status)
  values (v_month_key, p_boundary_id, now(), 'running');

  -- V2.0.14：当月没有任何有效记录时只写空结算，不产生任何次数/抽选/第二类名单
  select count(*) into v_rec_cnt
    from public.records
   where status = '正常'
     and record_date >= to_char(v_sd, 'YYYY-MM-DD')
     and record_date <  to_char(v_ed, 'YYYY-MM-DD');
  if v_rec_cnt = 0 then
    v_summary := jsonb_build_object(
      'type', 'month', 'month_key', v_month_key,
      'range_start', v_start, 'range_end', v_end,
      'groups', '[]'::jsonb, 'individuals', '[]'::jsonb,
      'second_class', '[]'::jsonb, 'second_class_count', 0,
      'reward', jsonb_build_object('rows', '[]'::jsonb, 'forfeit', '[]'::jsonb),
      'penalty', jsonb_build_object('rows', '[]'::jsonb),
      'auto_draw_count', 0, 'cards_expired', 0,
      'empty_month', true, 'generated_at', now());
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

  -- 奖励次数 = max(floor(月加分/阈值), 月加分前 N 名则 1)，max 去重后写成一条
  insert into public.lottery_chances (student_id, period_key, pool_type, chance_type, amount, source_week_key)
  select q.student_id, v_month_key, 'reward', 'monthly_points', q.amount, ''
    from (
      select s.id as student_id,
             greatest(
               floor(coalesce(x.add_total,0) / v_reward_thr)::int,
               case when coalesce(x.add_total,0) > 0
                     and rank() over (order by coalesce(x.add_total,0) desc) <= v_top_n
                    then 1 else 0 end
             ) as amount
        from public.students s
        left join (
          select rec.student_id,
                 sum(case when rec.points > 0 then rec.points else 0 end) as add_total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) x on x.student_id = s.id
    ) q
   where q.amount > 0
  on conflict (student_id, period_key, chance_type, source_week_key) do nothing;

  -- 惩罚次数（V2.0.15 口径）：
  --   普通学生 = floor(月扣分/阈值)
  --   按排名惩罚名单（月净积分倒数 N 名，含并列）= 若该生本月已获得奖励次数（奖励抽选 > 0）
  --     则**不计任何惩罚**（0 次）；否则 = max(floor(月扣分/阈值), 1)（保底 1 次）。
  --   次数归属：来自扣分的记 penalty_points，保底补的那 1 次记 second_class。
  insert into public.lottery_chances (student_id, period_key, pool_type, chance_type, amount, source_week_key)
  select q.student_id, v_month_key, 'penalty',
         case when q.base_points > 0 then 'penalty_points' else 'second_class' end,
         q.final_amount, ''
    from (
      select s.id as student_id,
             floor(coalesce(x.ded_total,0) / v_penalty_thr)::int as base_points,
             case
               when s.id = any(v_second_ids) then
                 case when coalesce(rc.amount, 0) > 0 then 0
                      else greatest(floor(coalesce(x.ded_total,0) / v_penalty_thr)::int, 1)
                 end
               else floor(coalesce(x.ded_total,0) / v_penalty_thr)::int
             end as final_amount
        from public.students s
        left join (
          select rec.student_id,
                 sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) x on x.student_id = s.id
        left join public.lottery_chances rc
               on rc.student_id = s.id
              and rc.period_key = v_month_key
              and rc.pool_type = 'reward'
              and rc.chance_type = 'monthly_points'
              and rc.source_week_key = ''
    ) q
   where q.final_amount > 0
  on conflict (student_id, period_key, chance_type, source_week_key) do nothing;


  -- 功能卡过期
  v_cards_exp := public.expire_function_cards();

  -- 记录本月应得/已抽情况（供快照与 reward_forfeit 标注）
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', c.student_id, 'name', s.name,
           'amount', c.amount, 'used_before_auto', c.used_count,
           'remaining_before_auto', c.amount - c.used_count) order by s.name), '[]'::jsonb)
    into v_reward_rows
    from public.lottery_chances c join public.students s on s.id = c.student_id
   where c.period_key = v_month_key and c.pool_type = 'reward';

  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', c.student_id, 'name', s.name, 'chance_type', c.chance_type,
           'amount', c.amount, 'used_before_auto', c.used_count,
           'remaining_before_auto', c.amount - c.used_count) order by s.name), '[]'::jsonb)
    into v_penalty_rows
    from public.lottery_chances c join public.students s on s.id = c.student_id
   where c.period_key = v_month_key and c.pool_type = 'penalty';

  -- 第二类学生未使用的奖励次数：账面标 reward_forfeit（结果照常自动抽、不追回）
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', c.student_id, 'name', s.name,
           'remaining', c.amount - c.used_count, 'reward_forfeit', true) order by s.name), '[]'::jsonb)
    into v_forfeit
    from public.lottery_chances c join public.students s on s.id = c.student_id
   where c.period_key = v_month_key and c.pool_type = 'reward'
     and c.used_count < c.amount
     and c.student_id = any(v_second_ids);

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
    'range_end', v_end,
    'groups', v_groups,
    'individuals', v_individuals,
    'second_class', v_second,
    'second_class_count', jsonb_array_length(v_second),
    'reward', jsonb_build_object('rows', v_reward_rows, 'forfeit', v_forfeit),
    'penalty', jsonb_build_object('rows', v_penalty_rows),
    'auto_draw_count', v_auto_total,
    'cards_expired', v_cards_exp,
    'generated_at', now()
  );

  update public.settlements
     set status = 'done', finished_at = now(), summary = v_summary,
         second_class = v_second, auto_draw_count = v_auto_total
   where boundary_id = p_boundary_id and status <> 'rolled_back';
  update public.boundaries set settled = true where id = p_boundary_id;

  perform public.notify_audience('admins', '月度结算完成',
    format('%s 月结算完成：第二类 %s 人，自动抽选 %s 次，过期功能卡 %s 张。请核对汇总。',
           v_month_key, jsonb_array_length(v_second), v_auto_total, v_cards_exp),
    'period', 'settlement', (select id from public.settlements
                              where boundary_id = p_boundary_id and status <> 'rolled_back' limit 1));
  perform public.write_audit('monthly_settle', 'boundary', p_boundary_id::text,
    jsonb_build_object('month_key', v_month_key, 'second_class', jsonb_array_length(v_second),
                       'auto_draw_count', v_auto_total, 'cards_expired', v_cards_exp));
  return v_summary;
end;
$$;
revoke all on function public.monthly_settle(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 轮询作业入口（pg_cron 每 10 分钟；也可管理员手动触发）
-- ------------------------------------------------------------

create or replace function public.admin_run_weekly_summary(p_boundary_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b      public.boundaries;
  v_key    text;
  v_month  text;
  v_res    jsonb;
  v_added  int := 0;
  v_draws  int := 0;
begin
  perform public.require_role(array['super_admin','admin','executive'], '只有管理员、班主任或执行小组可以手动汇总');

  if p_boundary_id is null then
    select * into v_b from public.boundaries
     where type = 'week' and boundary_at <= now()
     order by boundary_at desc limit 1;
  else
    select * into v_b from public.boundaries where id = p_boundary_id;
  end if;

  if v_b.id is null then
    raise exception '没有找到可汇总的周分隔点';
  end if;
  if v_b.type <> 'week' then
    raise exception '该分隔点不是周分隔点';
  end if;
  if v_b.boundary_at > now() then
    raise exception '该周尚未结束，不能汇总';
  end if;

  -- 周分隔点关闭的是「上一周」，周期键必须按关闭的那一周推导（不能用分隔点自身所在周）
  v_key   := to_char((v_b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'IYYY-IW');
  v_month := to_char((v_b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'YYYY-MM');

  -- 覆盖：清掉本周期已有结果
  delete from public.weekly_summaries where boundary_id = v_b.id;
  delete from public.lottery_chances
   where chance_type = 'weekly_group'
     and source_week_key = v_key;
  delete from public.lottery_group_chances where source_week_key = v_key;
  delete from public.lottery_draws
   where source in ('monthly_group_penalty', 'weekly_group_penalty', 'weekly_group_reward')
     and period_key = v_month;
  update public.boundaries set settled = false where id = v_b.id;

  v_res   := public.weekly_snapshot(v_b.id);
  v_added := coalesce((v_res->>'reward_group_chances')::int, 0);
  v_draws := coalesce((v_res->>'penalty_group_chances')::int, 0);

  perform public.write_audit('admin_run_weekly_summary', 'boundary', v_b.id::text,
    jsonb_build_object('week_key', v_key, 'reward_chances', v_added, 'penalty_draws', v_draws));

  return jsonb_build_object(
    'week_key', v_key, 'boundary_id', v_b.id,
    'reward_chances', v_added, 'penalty_draws', v_draws, 'summary', v_res);
end;
$$;
revoke all on function public.admin_run_weekly_summary(uuid) from public, anon, authenticated;
grant execute on function public.admin_run_weekly_summary(uuid) to authenticated;

-- ------------------------------------------------------------
-- 7.3 手动月汇总（覆盖重算）
-- ------------------------------------------------------------

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
    select * into v_b from public.boundaries
     where type = 'month' and boundary_at <= now()
     order by boundary_at desc limit 1;
  else
    select * into v_b from public.boundaries where id = p_boundary_id;
  end if;

  if v_b.id is null then
    raise exception '没有找到可汇总的月分隔点';
  end if;
  if v_b.type <> 'month' then
    raise exception '该分隔点不是月分隔点';
  end if;
  if v_b.boundary_at > now() then
    raise exception '该月尚未结束，不能汇总';
  end if;

  -- 月分隔点关闭的是「上一个月」，周期键按被结算的月份推导（settlements.period_key 用的是这个）
  v_key := to_char((v_b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'YYYY-MM');

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

  return jsonb_build_object('month_key', v_key, 'boundary_id', v_b.id, 'summary', v_res);
end;
$$;
revoke all on function public.admin_run_monthly_summary(uuid) from public, anon, authenticated;
grant execute on function public.admin_run_monthly_summary(uuid) to authenticated;

-- ============================================================
-- 7.5 废弃功能清理（V2.0.4：申诉功能取消）
--   幂等：重复执行无副作用
-- ============================================================



-- 自检
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('monthly_settle','admin_run_weekly_summary','admin_run_monthly_summary')) as patched_funcs,
  (select count(*) from public.lottery_chances) as chances,
  (select count(*) from public.settlements) as settlements;
