-- =====================================================================
-- 班级积分 V2.0.14 补丁：周汇总只汇总 + 小组人工抽奖 + 月度空月守卫
-- 适用：已部署 V2.0.13（或更早 V2.0.x）的库；全新建库请直接用 schema.sql
-- 执行：Supabase SQL Editor 整段执行；可重复执行（幂等）
-- 完成后执行：notify pgrst, 'reload schema';
-- =====================================================================
set check_function_bodies = off;

-- 1) 抽选记录增加「目标周」列（用于每组每池每周限一次）
alter table public.lottery_draws add column if not exists source_week_key text not null default '';

-- 2) 来源约束扩展
alter table public.lottery_draws drop constraint if exists lottery_draws_source_check;
alter table public.lottery_draws
  add constraint lottery_draws_source_check check (source = any (array[
    'manual','auto','weekly_group','weekly_group_reward','weekly_group_penalty',
    'monthly_group_penalty','weekly_group_manual_reward','weekly_group_manual_penalty']));


-- ------------------------------------------------------------
-- weekly_snapshot(uuid)
-- ------------------------------------------------------------
create or replace function public.weekly_snapshot(p_boundary_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b        public.boundaries;
  v_exist    jsonb;
  v_start    timestamptz;
  v_end      timestamptz;
  v_sd       date;
  v_ed       date;
  v_week_key text;
  v_month_key text;
  v_top      int := 3;
  v_bottom   int := 3;
  v_individuals jsonb;
  v_groups   jsonb;
  v_star_ind jsonb;
  v_star_grp jsonb;
  v_group_cnt int := 0;
  v_summary  jsonb;
  v_added    int := 0;
  v_penalty_draws int := 0;
  v_reward_chances int := 0;
  v_penalty_chances int := 0;
  v_p        record;
  v_p2       record;
  v_item     public.lottery_items;
  v_repr     uuid;
  v_members  jsonb;
  v_draw_id  uuid;
begin
  select * into v_b from public.boundaries where id = p_boundary_id;
  if v_b.id is null then
    raise exception '分隔点不存在';
  end if;
  if v_b.type <> 'week' then
    raise exception '该分隔点不是周分隔点';
  end if;

  select summary into v_exist from public.weekly_summaries where boundary_id = p_boundary_id;
  if v_exist is not null then
    return v_exist;
  end if;

  v_end := v_b.boundary_at;
  v_start := coalesce(
    (select max(b.boundary_at) from public.boundaries b
      where b.type = 'week' and b.boundary_at < v_end),
    v_end - interval '7 days');
  v_sd := (v_start at time zone 'Asia/Shanghai')::date;
  v_ed := (v_end at time zone 'Asia/Shanghai')::date;
  -- 周期键 = 分隔点关闭的那一周（周一~周日）的 ISO 周号；分隔点本身在下一周的周一 00:00
  v_week_key := to_char((v_b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'IYYY-IW');
  -- 本周（结算覆盖的那段）所属自然月 → 奖励次数入该月
  v_month_key := to_char((v_end - interval '1 second') at time zone 'Asia/Shanghai', 'YYYY-MM');

  select coalesce((public.cfg()->>'week_reward_top_groups')::int, 3),
         coalesce((public.cfg()->>'week_penalty_bottom_groups')::int, 3)
    into v_top, v_bottom;

  -- 个人周积分
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', p.id, 'name', p.name, 'group_name', p.group_name,
           'total', p.total, 'rank', p.rnk) order by p.rnk, p.name), '[]'::jsonb)
    into v_individuals
    from (
      select s.id, s.name, s.group_name, coalesce(r.total, 0) as total,
             rank() over (order by coalesce(r.total, 0) desc) as rnk
        from public.students s
        left join (
          select rec.student_id, sum(rec.points) as total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) r on r.student_id = s.id
    ) p;

  -- 小组周积分
  select coalesce(jsonb_agg(jsonb_build_object(
           'group_name', g.group_name, 'total', g.total, 'rank', g.rnk, 'pos', g.pos) order by g.pos), '[]'::jsonb)
    into v_groups
    from (
      select q.group_name, sum(q.total) as total,
             rank() over (order by sum(q.total) desc) as rnk,
             row_number() over (order by sum(q.total) desc, q.group_name) as pos
        from (
          select s.group_name, coalesce(r.total, 0) as total
            from public.students s
            left join (
              select rec.student_id, sum(rec.points) as total
                from public.records rec
               where rec.status = '正常'
                 and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
                 and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
               group by rec.student_id
            ) r on r.student_id = s.id
           where s.group_name is not null and s.group_name <> ''
        ) q
       group by q.group_name
    ) g;
  select jsonb_array_length(v_groups) into v_group_cnt;

  -- 本周星光增减（荣誉标记）
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', x.student_id, 'name', x.name, 'change', x.change) order by x.change desc), '[]'::jsonb)
    into v_star_ind
    from (
      select l.student_id, s.name, sum(l.change_amount) as change
        from public.starlight_logs l
        join public.students s on s.id = l.student_id
       where l.created_at >= v_start and l.created_at < v_end
       group by l.student_id, s.name
      having sum(l.change_amount) <> 0
    ) x;

  select coalesce(jsonb_agg(jsonb_build_object(
           'group_name', y.group_name, 'change', y.change) order by y.change desc), '[]'::jsonb)
    into v_star_grp
    from (
      select s.group_name, sum(l.change_amount) as change
        from public.starlight_logs l
        join public.students s on s.id = l.student_id
       where l.created_at >= v_start and l.created_at < v_end
       group by s.group_name
      having sum(l.change_amount) <> 0
    ) y;

  v_summary := jsonb_build_object(
    'type', 'week',
    'week_key', v_week_key,
    'range_start', v_start,
    'range_end', v_end,
    'groups', v_groups,
    'individuals', v_individuals,
    'reward_groups', (select coalesce(jsonb_agg(g), '[]'::jsonb)
                        from jsonb_array_elements(v_groups) g
                       where (g->>'pos')::int <= v_top),
    'penalty_groups', (select coalesce(jsonb_agg(g), '[]'::jsonb)
                         from jsonb_array_elements(v_groups) g
                        where v_group_cnt >= v_top + v_bottom
                          and (g->>'pos')::int > greatest(v_top, v_group_cnt - v_bottom)),
    'starlight_individuals', v_star_ind,
    'starlight_groups', v_star_grp,
    'effects_done', false,
    'generated_at', now()
  );
  insert into public.weekly_summaries (period_key, boundary_id, range_start, range_end, summary)
  values (v_week_key, p_boundary_id, v_start, v_end, v_summary);

  -- V2.0.14：周结算只写汇总快照，不再发放抽选次数、也不再自动抽惩罚。
  --   小组抽奖改为人工：由执行小组及以上在「奖惩抽选 → 小组」里选择小组后抽取（每组每池每周限一次）。
  --   summary 中的 reward_groups / penalty_groups 仅作为「建议名单」展示。
  v_summary := v_summary || jsonb_build_object(
    'effects_done', true,
    'snapshot_only', true,
    'reward_chances_added', 0,
    'penalty_draws', 0,
    'reward_group_chances', 0,
    'penalty_group_chances', 0);
  update public.weekly_summaries set summary = v_summary where boundary_id = p_boundary_id;
  update public.boundaries set settled = true where id = p_boundary_id;

  -- 通知执行小组及以上：周汇总已生成，可开始人工小组抽奖
  perform public.notify_audience('executive_plus',
    format('%s 周汇总已生成', v_week_key),
    format('奖励建议：%s；惩罚建议：%s。请到「奖惩抽选 → 小组」选择小组抽奖（每组每池每周限一次；奖励全组每人一份，惩罚全组共担）。',
      coalesce((select string_agg(g->>'group_name', '、')
                  from jsonb_array_elements(v_groups) g
                 where (g->>'pos')::int <= v_top), '无'),
      coalesce((select string_agg(g->>'group_name', '、')
                  from jsonb_array_elements(v_groups) g
                 where v_group_cnt >= v_top + v_bottom
                   and (g->>'pos')::int > greatest(v_top, v_group_cnt - v_bottom)), '无')),
    'period', 'weekly_summary',
    (select id from public.weekly_summaries where boundary_id = p_boundary_id limit 1));

  perform public.write_audit('weekly_snapshot', 'boundary', p_boundary_id::text,
    jsonb_build_object('week_key', v_week_key, 'snapshot_only', true));
  return v_summary;
end;
$$;;


-- ------------------------------------------------------------
-- monthly_settle(uuid)
-- ------------------------------------------------------------
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

  if v_thr is not null and v_thr < 0 then
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
$$;;


-- ------------------------------------------------------------
-- draw_group_lottery(text, text, uuid)
-- ------------------------------------------------------------
create or replace function public.draw_group_lottery(
  p_group_name text,
  p_pool_type  text default 'reward',
  p_chance_id  uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role    text := public.caller_role();
  v_group   text := nullif(btrim(coalesce(p_group_name, '')), '');
  v_chance  public.lottery_group_chances;
  v_item    public.lottery_items;
  v_members jsonb;
  v_ids     uuid[] := '{}';
  v_draw_id uuid;
  v_prof    uuid;
  v_cnt     int := 0;
  v_period  text;
begin
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能抽选';
  end if;
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  if v_group is null then
    raise exception '请选择小组';
  end if;
  if p_pool_type not in ('reward','penalty') then
    raise exception '奖池类型不合法';
  end if;

  -- V2.0.14：小组抽奖收回小组记录员/学生的代抽权限，统一由执行小组及以上操作
  if v_role not in ('system','super_admin','admin','executive') then
    raise exception '小组抽奖仅限执行小组及以上操作，请在「奖惩抽选」里选择小组由班干部抽取';
  end if;

  -- 同一小组同一奖池同一周期串行执行：多人同时点，只有最早一次写入生效
  perform pg_advisory_xact_lock(hashtext('group_draw:' || v_group || ':' || p_pool_type || ':' || public.current_month_key()));

  select * into v_chance
    from public.lottery_group_chances c
   where (p_chance_id is null or c.id = p_chance_id)
     and c.group_name = v_group
     and c.pool_type = p_pool_type
     and c.used_count < c.amount
     and c.period_key = public.current_month_key()
   order by c.created_at, c.id
   limit 1
   for update;
  if v_chance.id is null then
    -- 已经抽过（或被别的成员抢先写完）时，按最早一次为准给出明确提示
    declare
      v_earliest record;
    begin
      select d.drawn_at, coalesce(pr.name, '其他成员') as who
        into v_earliest
        from public.lottery_draws d
        left join public.profiles pr on pr.id = d.drawn_by
       where d.group_name = v_group and d.is_group
         and d.source = 'weekly_group_' || p_pool_type
         and d.period_key = public.current_month_key()
       order by d.drawn_at
       limit 1;
      if v_earliest.drawn_at is not null then
        raise exception '「%」小组本轮%抽选已由 % 于 % 完成，以最早一次写入为准',
          v_group,
          case when p_pool_type = 'reward' then '奖励' else '惩罚' end,
          v_earliest.who,
          to_char(v_earliest.drawn_at at time zone 'Asia/Shanghai', 'MM-DD HH24:MI');
      end if;
    end;
    raise exception '「%s」小组本周没有可用的%s抽选次数', v_group,
      case when p_pool_type = 'reward' then '奖励' else '惩罚' end;
  end if;

  v_period  := v_chance.period_key;
  v_members := to_jsonb(public.group_members(v_group));
  v_item    := public._pick_lottery_item(p_pool_type);

  if v_item.id is null then
    insert into public.lottery_draws (student_id, pool_type, item_id, item_snapshot, item_kind,
      period_key, source, group_name, is_group, member_ids, status, note)
    values (null, p_pool_type, null, '{}'::jsonb, 'plain_text',
      v_period, 'weekly_group_' || p_pool_type, v_group, true, v_members, 'void',
      '本期奖池为空，未抽中');
    update public.lottery_group_chances set used_count = used_count + 1 where id = v_chance.id;
    return jsonb_build_object('ok', true, 'group_name', v_group, 'empty', true, 'draws', '[]'::jsonb);
  end if;

  -- 全组每人各得一份
  for v_prof in
    select s.id from public.students s where s.group_name = v_group order by s.created_at, s.id
  loop
    v_draw_id := public._apply_draw(v_prof, p_pool_type, v_item.id, v_period,
      'weekly_group_' || p_pool_type, v_group, v_members, true,
      format('小组集体抽选（%s）', v_chance.source_week_key), auth.uid(), false);
    v_ids := v_ids || v_draw_id;
    v_cnt := v_cnt + 1;
  end loop;

  update public.lottery_group_chances
     set used_count = used_count + 1
   where id = v_chance.id;

  -- 通知全组成员
  for v_prof in
    select p.id from public.profiles p
      join public.students s on s.id = p.student_id
     where s.group_name = v_group and p.status = 'active'
  loop
    perform public.notify(v_prof, '小组集体抽选结果',
      format('你所在的「%s」小组抽中：%s', v_group, v_item.title),
      'lottery', 'lottery_draw', v_ids[1]);
  end loop;

  perform public.write_audit('draw_group_lottery', 'lottery_draw', v_ids[1]::text,
    jsonb_build_object('group_name', v_group, 'pool', p_pool_type,
      'members', v_cnt, 'item', v_item.title, 'source_week', v_chance.source_week_key));

  return jsonb_build_object(
    'ok', true,
    'group_name', v_group,
    'pool_type', p_pool_type,
    'item', to_jsonb(v_item),
    'members', v_cnt,
    'draws', (select coalesce(jsonb_agg(to_jsonb(d) order by d.drawn_at), '[]'::jsonb)
                from public.lottery_draws d where d.id = any(v_ids))
  );
end;
$$;;


-- ------------------------------------------------------------
-- list_summary_periods(text, int)
-- ------------------------------------------------------------
create or replace function public.list_summary_periods(
  p_type  text default 'week',
  p_limit int default 60
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_list jsonb;
begin
  if v_role not in ('system', 'super_admin', 'admin', 'executive', 'group_recorder') then
    raise exception '没有权限查看周期汇总列表';
  end if;
  if p_type not in ('week', 'month') then
    raise exception '汇总类型只能是 week 或 month';
  end if;

  if p_type = 'week' then
    select coalesce(jsonb_agg(x order by x->>'boundary_at' desc), '[]'::jsonb) into v_list
      from (
        select jsonb_build_object(
                 'period_key', to_char((b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'IYYY-IW'),
                 'boundary_id', b.id,
                 'boundary_at', b.boundary_at,
                 'settled', b.settled,
                 'has_summary', exists (select 1 from public.weekly_summaries w where w.boundary_id = b.id),
                 'label', b.label
               ) as x
          from public.boundaries b
         where b.type = 'week'
           and b.boundary_at <= now()
         order by b.boundary_at desc
         limit greatest(coalesce(p_limit, 60), 1)
      ) q;
  else
    -- 月分隔点：结算的是“刚结束的那个月”，所以对外的 period_key 用结算月（分隔点所在月 - 1 个月）
    select coalesce(jsonb_agg(x order by x->>'boundary_at' desc), '[]'::jsonb) into v_list
      from (
        select jsonb_build_object(
                 'period_key', coalesce(
                     (select s.period_key from public.settlements s
                       where s.boundary_id = b.id and s.status <> 'rolled_back'
                       order by s.started_at desc limit 1),
                     to_char((b.boundary_at at time zone 'Asia/Shanghai') - interval '1 month', 'YYYY-MM')),
                 'boundary_id', b.id,
                 'boundary_at', b.boundary_at,
                 'settled', b.settled,
                 'has_summary', exists (select 1 from public.settlements s
                                         where s.boundary_id = b.id and s.status <> 'rolled_back'),
                 'status', (select s.status from public.settlements s
                             where s.boundary_id = b.id and s.status <> 'rolled_back'
                             order by s.started_at desc limit 1),
                 'label', b.label
               ) as x
          from public.boundaries b
         where b.type = 'month'
           and b.boundary_at <= now()
         order by b.boundary_at desc
         limit greatest(coalesce(p_limit, 60), 1)
      ) q;
  end if;

  return jsonb_build_object('type', p_type, 'items', v_list);
end;
$$;;


-- ------------------------------------------------------------
-- get_period_summary(text, text)
-- ------------------------------------------------------------
create or replace function public.get_period_summary(
  p_type       text default 'week',
  p_period_key text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_me   uuid := public.my_student_id();
  v_key  text := p_period_key;
  v_bd   public.boundaries;
  v_out  jsonb;
begin
  if v_role not in ('system', 'super_admin', 'admin', 'executive', 'group_recorder', 'student') then
    raise exception '没有权限查看周期汇总';
  end if;
  if p_type not in ('week', 'month') then
    raise exception '汇总类型只能是 week 或 month';
  end if;
  if v_key is null then
    raise exception '请选择要查看的周期';
  end if;

  if p_type = 'week' then
    select * into v_bd from public.boundaries
     where type = 'week' and boundary_at <= now()
      and to_char((boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'IYYY-IW') = v_key
     order by boundary_at desc limit 1;
    if v_bd.id is null then
      raise exception '找不到周「%」的分隔点', v_key;
    end if;
    select to_jsonb(w) into v_out from public.weekly_summaries w where w.boundary_id = v_bd.id;
    if v_out is null then
      raise exception '周「%」还没有汇总记录，可由管理员点击「立即汇总」生成', v_key;
    end if;
    if v_role = 'student' then
      v_out := v_out || jsonb_build_object('summary',
        jsonb_build_object('me', coalesce((select jsonb_build_object('total', i->>'total', 'rank', i->>'rank')
                                            from jsonb_array_elements(coalesce(v_out->'summary'->'individuals', '[]'::jsonb)) i
                                           where (i->>'student_id') = v_me::text limit 1), null)));
    end if;
    return v_out || jsonb_build_object('type', 'week', 'period_key', v_key,
                                       'boundary_at', v_bd.boundary_at,
                                       'range_start', v_out #>> '{summary,range_start}');
  end if;

  -- 月度：结算记录里保存的是“被结算的月份”（period_key），直接按它定位，避免分隔点月份错位
  select to_jsonb(s) into v_out from public.settlements s
   where s.period_key = v_key and s.status <> 'rolled_back'
   order by s.started_at desc limit 1;
  if v_out is null then
    raise exception '月「%」还没有结算记录，可由管理员点击「立即结算」生成', v_key;
  end if;
  select * into v_bd from public.boundaries
   where id = (v_out->>'boundary_id')::uuid;
  return v_out || jsonb_build_object('type', 'month', 'period_key', v_key,
                                     'boundary_at', v_bd.boundary_at);
end;
$$;;


-- ------------------------------------------------------------
-- admin_group_week_board(text)
-- ------------------------------------------------------------
create or replace function public.admin_group_week_board(p_week_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_key    text := nullif(btrim(coalesce(p_week_key, '')), '');
  v_b      public.boundaries;
  v_start  timestamptz;
  v_end    timestamptz;
  v_top    int := 3;
  v_bottom int := 2;
  v_sum    public.weekly_summaries;
  v_groups jsonb;
  v_items  jsonb := '[]'::jsonb;
  v_cnt    int := 0;
begin
  if v_role not in ('system', 'super_admin', 'admin', 'executive') then
    raise exception '只有执行小组及以上权限可以查看小组抽奖';
  end if;

  -- 默认取「最近一个已关闭的周」（当前周尚未结束，没有汇总也没有抽奖）
  v_key := coalesce(nullif(btrim(coalesce(v_key,'')),''), (
    select to_char((b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'IYYY-IW')
      from public.boundaries b
     where b.type = 'week' and b.boundary_at <= now()
     order by b.boundary_at desc limit 1), public.current_week_key());
  select coalesce((public.cfg()->>'week_reward_top_groups')::int, 3),
         coalesce((public.cfg()->>'week_penalty_bottom_groups')::int, 2)
    into v_top, v_bottom;

  select * into v_b from public.boundaries b
   where b.type = 'week'
     and to_char((b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'IYYY-IW') = v_key
   order by b.boundary_at desc limit 1;
  if v_b.id is not null then
    v_end := v_b.boundary_at;
    v_start := coalesce(
      (select max(b.boundary_at) from public.boundaries b
        where b.type = 'week' and b.boundary_at < v_end),
      v_end - interval '7 days');
  else
    v_end := now();
    v_start := now() - interval '7 days';
  end if;

  select * into v_sum from public.weekly_summaries w
   where (v_b.id is not null and w.boundary_id = v_b.id)
      or (v_b.id is null and w.period_key = v_key)
   order by w.created_at desc limit 1;
  if v_sum.id is not null then
    v_groups := coalesce(v_sum.summary->'groups', '[]'::jsonb);
  else
    select coalesce(jsonb_agg(jsonb_build_object(
             'group_name', g.group_name, 'total', g.total, 'rank', g.rnk, 'pos', g.pos) order by g.pos), '[]'::jsonb)
      into v_groups
      from (
        select q.group_name, sum(q.total) as total,
               rank() over (order by sum(q.total) desc) as rnk,
               row_number() over (order by sum(q.total) desc, q.group_name) as pos
          from (
            select s.group_name, coalesce(r.total, 0) as total
              from public.students s
              left join (
                select rec.student_id, sum(rec.points) as total
                  from public.records rec
                 where rec.status = '正常'
                   and rec.record_date >= to_char((v_start at time zone 'Asia/Shanghai')::date, 'YYYY-MM-DD')
                   and rec.record_date <  to_char((v_end   at time zone 'Asia/Shanghai')::date, 'YYYY-MM-DD')
                 group by rec.student_id
              ) r on r.student_id = s.id
             where s.group_name is not null and s.group_name <> ''
          ) q
         group by q.group_name
      ) g;
  end if;

  select jsonb_array_length(v_groups) into v_cnt;

  select coalesce(jsonb_agg(jsonb_build_object(
           'group_name', x.group_name,
           'total', x.total,
           'rank', x.rank,
           'pos', x.pos,
           'members', (select count(*) from public.students st where st.group_name = x.group_name),
           'reward_suggested', (x.pos <= v_top),
           'penalty_suggested', (v_cnt >= v_top + v_bottom and x.pos > greatest(v_top, v_cnt - v_bottom)),
           'reward_drawn', exists(
             select 1 from public.lottery_draws d
              where d.is_group and d.group_name = x.group_name and d.pool_type = 'reward'
                and d.status <> 'void'
                and (d.source_week_key = v_key
                     or (coalesce(d.source_week_key, '') = ''
                         and d.drawn_at >= v_start and d.drawn_at < v_end))),
           'penalty_drawn', exists(
             select 1 from public.lottery_draws d
              where d.is_group and d.group_name = x.group_name and d.pool_type = 'penalty'
                and d.status <> 'void'
                and (d.source_week_key = v_key
                     or (coalesce(d.source_week_key, '') = ''
                         and d.drawn_at >= v_start and d.drawn_at < v_end))),
           'reward_item', (
             select coalesce(nullif(d.item_snapshot->>'title', ''), d.note, '')
               from public.lottery_draws d
              where d.is_group and d.group_name = x.group_name and d.pool_type = 'reward'
                and d.status <> 'void'
                and (d.source_week_key = v_key
                     or (coalesce(d.source_week_key, '') = ''
                         and d.drawn_at >= v_start and d.drawn_at < v_end))
              order by d.drawn_at desc limit 1),
           'penalty_item', (
             select coalesce(nullif(d.item_snapshot->>'title', ''), d.note, '')
               from public.lottery_draws d
              where d.is_group and d.group_name = x.group_name and d.pool_type = 'penalty'
                and d.status <> 'void'
                and (d.source_week_key = v_key
                     or (coalesce(d.source_week_key, '') = ''
                         and d.drawn_at >= v_start and d.drawn_at < v_end))
              order by d.drawn_at desc limit 1),
           'reward_at', (
             select max(d.drawn_at)
               from public.lottery_draws d
              where d.is_group and d.group_name = x.group_name and d.pool_type = 'reward'
                and d.status <> 'void'
                and (d.source_week_key = v_key
                     or (coalesce(d.source_week_key, '') = ''
                         and d.drawn_at >= v_start and d.drawn_at < v_end))),
           'penalty_at', (
             select max(d.drawn_at)
               from public.lottery_draws d
              where d.is_group and d.group_name = x.group_name and d.pool_type = 'penalty'
                and d.status <> 'void'
                and (d.source_week_key = v_key
                     or (coalesce(d.source_week_key, '') = ''
                         and d.drawn_at >= v_start and d.drawn_at < v_end)))
         ) order by x.pos), '[]'::jsonb)
    into v_items
    from jsonb_to_recordset(v_groups) as x(group_name text, total numeric, "rank" int, pos int);

  return jsonb_build_object(
    'week_key', v_key,
    'range_start', v_start,
    'range_end', v_end,
    'has_summary', (v_sum.id is not null),
    'top_n', v_top,
    'bottom_n', v_bottom,
    'group_count', v_cnt,
    'groups', coalesce(v_items, '[]'::jsonb),
    'week_options', coalesce((
      select jsonb_agg(jsonb_build_object(
               'week_key', to_char((w.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'IYYY-IW'),
               'range_start', w.boundary_at - interval '7 days',
               'range_end', w.boundary_at,
               'has_summary', exists(select 1 from public.weekly_summaries ws where ws.boundary_id = w.id))
             order by w.boundary_at desc)
        from (select b.id, b.boundary_at from public.boundaries b
               where b.type = 'week' and b.boundary_at <= now()
               order by b.boundary_at desc limit 12) w
    ), '[]'::jsonb));
end;
$$;;


-- ------------------------------------------------------------
-- admin_draw_group_manual(text, text, text, text)
-- ------------------------------------------------------------
create or replace function public.admin_draw_group_manual(
  p_group_name text,
  p_pool_type  text default 'reward',
  p_week_key   text default null,
  p_note       text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role    text := public.caller_role();
  v_group   text := nullif(btrim(coalesce(p_group_name, '')), '');
  v_pool    text := lower(coalesce(nullif(btrim(coalesce(p_pool_type, '')), ''), 'reward'));
  v_key     text;
  v_b       public.boundaries;
  v_start   timestamptz;
  v_end     timestamptz;
  v_period  text;
  v_source  text;
  v_members jsonb;
  v_item    public.lottery_items;
  v_prev_at timestamptz;
  v_prev_by text;
  v_prev_it text;
  v_prof    uuid;
  v_draw    uuid;
  v_ids     uuid[] := '{}';
  v_cnt     int := 0;
  v_label   text;
begin
  if v_role not in ('system', 'super_admin', 'admin', 'executive') then
    raise exception '只有执行小组及以上权限可以为小组抽奖';
  end if;
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能抽选';
  end if;
  if v_group is null then
    raise exception '请选择小组';
  end if;
  if v_pool not in ('reward', 'penalty') then
    raise exception '奖池类型不合法';
  end if;
  v_label := case when v_pool = 'reward' then '奖励' else '惩罚' end;

  -- 默认取「最近一个已关闭的周」（与看板一致；当前周未结束不能抽奖）
  v_key := coalesce(nullif(btrim(coalesce(p_week_key, '')), ''), (
    select to_char((b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'IYYY-IW')
      from public.boundaries b
     where b.type = 'week' and b.boundary_at <= now()
     order by b.boundary_at desc limit 1), public.current_week_key());
  select * into v_b from public.boundaries b
   where b.type = 'week'
     and to_char((b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'IYYY-IW') = v_key
   order by b.boundary_at desc limit 1;
  if v_b.id is null then
    raise exception '周「%」不存在，请先在设置里立即分隔或选择其它周', v_key;
  end if;
  if v_b.boundary_at > now() then
    raise exception '周「%」尚未结束，请等该周汇总完成后再为小组抽奖', v_key;
  end if;
  v_end := v_b.boundary_at;
  v_start := coalesce(
    (select max(b.boundary_at) from public.boundaries b
      where b.type = 'week' and b.boundary_at < v_end),
    v_end - interval '7 days');
  v_period := to_char((v_end - interval '1 second') at time zone 'Asia/Shanghai', 'YYYY-MM');
  v_source := case when v_pool = 'reward' then 'weekly_group_manual_reward' else 'weekly_group_manual_penalty' end;

  if not exists (select 1 from public.students s where s.group_name = v_group) then
    raise exception '小组「%」下没有学生', v_group;
  end if;

  perform pg_advisory_xact_lock(hashtext('group_manual_draw:' || v_group || ':' || v_pool || ':' || v_key));

  select d.drawn_at,
         coalesce(pr.name, '—'),
         coalesce(nullif(d.item_snapshot->>'title', ''), d.note, '')
    into v_prev_at, v_prev_by, v_prev_it
    from public.lottery_draws d
    left join public.profiles pr on pr.id = d.drawn_by
   where d.is_group and d.group_name = v_group and d.pool_type = v_pool
     and d.status <> 'void'
     and (d.source_week_key = v_key
          or (coalesce(d.source_week_key, '') = ''
              and d.drawn_at >= v_start and d.drawn_at < v_end))
   order by d.drawn_at limit 1;
  if v_prev_at is not null then
    raise exception '「%」小组本周的%抽奖已于 % 完成（结果：%），每组每池每周只能抽一次；如需重抽请先在「仓库管理」作废上次结果',
      v_group, v_label,
      to_char(v_prev_at at time zone 'Asia/Shanghai', 'MM-DD HH24:MI'),
      coalesce(nullif(v_prev_it, ''), '未记录');
  end if;

  v_item := public._pick_lottery_item(v_pool);
  if v_item.id is null then
    raise exception '%池当前没有启用的卡片，请先到「奖惩抽选 → 奖池管理」启用', v_label;
  end if;

  v_members := to_jsonb(public.group_members(v_group));
  for v_prof in
    select s.id from public.students s where s.group_name = v_group order by s.created_at, s.id
  loop
    v_draw := public._apply_draw(
      v_prof, v_pool, v_item.id, v_period, v_source, v_group, v_members, true,
      coalesce(nullif(btrim(coalesce(p_note, '')), ''), format('%s 周小组抽奖（人工）', v_key)),
      auth.uid(), false);
    v_ids := v_ids || v_draw;
    v_cnt := v_cnt + 1;
  end loop;

  -- 标记这些结果所属的目标周（用于「每组每池每周限一次」判定）
  update public.lottery_draws set source_week_key = v_key where id = any(v_ids);

  for v_prof in
    select p.id from public.profiles p
      join public.students s on s.id = p.student_id
     where s.group_name = v_group and p.status = 'active'
  loop
    perform public.notify(v_prof, '小组抽奖结果',
      format('你所在的「%s」小组本周抽中（%s）：%s', v_group, v_label, v_item.title),
      'lottery', 'lottery_draw', v_ids[1]);
  end loop;

  perform public.write_audit('admin_draw_group_manual', 'lottery_draw',
    case when array_length(v_ids, 1) > 0 then v_ids[1]::text else null end,
    jsonb_build_object('group_name', v_group, 'pool', v_pool, 'week_key', v_key,
                       'period_key', v_period, 'members', v_cnt, 'item', v_item.title));

  return jsonb_build_object(
    'ok', true,
    'group_name', v_group,
    'week_key', v_key,
    'period_key', v_period,
    'pool_type', v_pool,
    'item', to_jsonb(v_item),
    'members', v_cnt,
    'draws', (select coalesce(jsonb_agg(to_jsonb(d) order by d.drawn_at), '[]'::jsonb)
                from public.lottery_draws d where d.id = any(v_ids)));
end;
$$;;


-- 3) 授权（内部函数不授权）
revoke all on function public.admin_group_week_board(text) from public, anon, authenticated;
grant execute on function public.admin_group_week_board(text) to authenticated;
revoke all on function public.admin_draw_group_manual(text, text, text, text) from public, anon, authenticated;
grant execute on function public.admin_draw_group_manual(text, text, text, text) to authenticated;
revoke all on function public.list_summary_periods(text, int) from public, anon, authenticated;
grant execute on function public.list_summary_periods(text, int) to authenticated;
revoke all on function public.get_period_summary(text, text) from public, anon, authenticated;
grant execute on function public.get_period_summary(text, text) to authenticated;
revoke all on function public.draw_group_lottery(text, text, uuid) from public, anon, authenticated;
grant execute on function public.draw_group_lottery(text, text, uuid) to authenticated;

-- 4) 自检
select
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='lottery_draws' and column_name='source_week_key') as has_source_week_key,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('admin_group_week_board','admin_draw_group_manual')) as new_funcs,
  (select count(*) from public.boundaries where settled) as settled_boundaries,
  (select count(*) from public.settlements where status='done') as done_settlements;
