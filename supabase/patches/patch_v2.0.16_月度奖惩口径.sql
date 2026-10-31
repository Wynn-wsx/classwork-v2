-- ============================================================
-- 班级积分系统 V2.0.16 补丁：月度奖惩口径（2026-10-31 用户确认版）
-- 适用：已在运行 V2.0.14 / V2.0.15 的数据库；可重复执行（幂等）
-- 变更：仅重写 monthly_settle()
--   奖励 = (月净积分排名前 15 名 → 每人 1 次) + floor(max(净分,0) ÷ 10)   [并列同分同名次]
--   惩罚 = floor(负分 ÷ 5)；惩罚名单（净分倒数 10 名含并列）内且本月无奖励 → 追加 1 次，
--          与基础惩罚重合时抵消（等价：名单内无奖励者 = max(基础,1)）；
--          单人单月惩罚封顶 3 次
-- 执行后请刷新 API 缓存：notify pgrst, 'reload schema';
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
    jsonb_build_object('month_key', v_month_key, 'penalty_rank_list', jsonb_array_length(v_second),
                       'auto_draw_count', v_auto_total, 'cards_expired', v_cards_exp));
  return v_summary;
end;
$$;
revoke all on function public.monthly_settle(uuid) from public, anon, authenticated;

-- 自检：确认函数已更新
select case
         when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'public' and p.proname = 'monthly_settle')
         then 'OK：monthly_settle 已更新'
         else 'FAIL：monthly_settle 缺失'
       end as patch_v2_0_16_check;
