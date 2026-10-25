-- ============================================================
-- V2.0.10 补丁：月度个人惩罚次数规则调整
-- 适用：已部署 V2.0.9（含 V2.0.9 全部热修复）的库
-- 内容：只重定义 public.monthly_settle(uuid) 一个函数，不动表结构与数据
-- 规则：普通学生 惩罚次数 = floor(当月扣分 ÷ 惩罚阈值)
--       按排名惩罚（后 N 名，N = app_config.second_class_count）：
--         当月扣分 ÷ 阈值 ≥ 1 时按扣分算（不再额外 +1）
--         不足 1 次时保底 1 次（记在 chance_type='second_class'）
-- 幂等：create or replace + 末尾 revoke/grant，可重复执行
-- 执行后务必：notify pgrst, 'reload schema';
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
               case when rank() over (order by coalesce(x.add_total,0) desc) <= v_top_n then 1 else 0 end
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

  -- 惩罚次数（V2.0.10 规则）：
  --   普通学生 = floor(月扣分/阈值)
  --   按排名惩罚（后 N 名）= max(floor(月扣分/阈值), 1) 作为基础次数；
  --     若该生本月可通过积分获得奖励（加分/阈值 ≥ 1，或月加分前 N 名兜底 1 次），
  --     则用 1 次奖励抵消 1 次惩罚（基础次数 -1，最低 0）；
  --   基础次数为 0 时不再额外发放（即「不能通过积分结算惩罚」才记这一次）。
  --   次数归属：来自扣分的记 penalty_points，保底补的那 1 次记 second_class。
  insert into public.lottery_chances (student_id, period_key, pool_type, chance_type, amount, source_week_key)
  select q.student_id, v_month_key, 'penalty',
         case when q.base_points > 0 then 'penalty_points' else 'second_class' end,
         q.final_amount, ''
    from (
      select s.id as student_id,
             floor(coalesce(x.ded_total,0) / v_penalty_thr)::int as base_points,
             greatest(
               (case when s.id = any(v_second_ids)
                     then greatest(floor(coalesce(x.ded_total,0) / v_penalty_thr)::int, 1)
                     else floor(coalesce(x.ded_total,0) / v_penalty_thr)::int end)
               - (case when s.id = any(v_second_ids)
                        and floor(coalesce(x.add_total,0) / v_reward_thr) >= 1 then 1 else 0 end),
               0
             ) as final_amount
        from public.students s
        left join (
          select rec.student_id,
                 sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total,
                 sum(case when rec.points > 0 then rec.points else 0 end) as add_total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) x on x.student_id = s.id
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
-- 自检：函数存在且可调用（应返回 1 行、无报错）
select p.proname as 函数,
       pg_get_function_identity_arguments(p.oid) as 参数
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'monthly_settle';
