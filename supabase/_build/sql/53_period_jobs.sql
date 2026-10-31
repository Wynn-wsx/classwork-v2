-- ============================================================
-- 5.3 周/月周期作业（快照 / 结算 / 自动抽选 / 轮询 / 个人汇总）
--   全部函数幂等：同一分隔点重复调用不会重复产生数据
--   （函数体整体是一个事务，异常时自动回滚，因此“先写快照作幂等闸门”是安全的）
-- ============================================================

-- ------------------------------------------------------------
-- 周结算：写周汇总快照 + 前 N 组每人 1 次奖励次数 + 后 N 组小组级惩罚抽选
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

  if v_b.start_date is null or v_b.end_date is null then
    raise exception '该周周期缺少起止日期，请先在「设置 → 周期定义」补全';
  end if;
  v_sd := v_b.start_date;
  v_ed := v_b.end_date + 1;                       -- 取不含上界
  v_start := v_sd::timestamp at time zone 'Asia/Shanghai';
  v_end   := v_ed::timestamp at time zone 'Asia/Shanghai';
  v_week_key := v_b.period_key;
  v_month_key := coalesce(public.period_key_of('month', v_b.end_date), public.current_month_key());

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
    'range_end', (v_ed - 1),
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
  values (v_week_key, p_boundary_id, v_start, ((v_ed - 1)::timestamp at time zone 'Asia/Shanghai'), v_summary);

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
$$;
revoke all on function public.weekly_snapshot(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 月结算：快照 + 奖励/惩罚次数 + 第二类 + 功能卡过期 + 未用次数自动抽选
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

  if v_b.start_date is null then
    raise exception '该月周期缺少起始日期，请先在「设置 → 周期定义」补全';
  end if;
  if v_b.end_date is null then
    raise exception '该月周期尚未结束（未填结束日期），不能结算';
  end if;
  v_sd := v_b.start_date;
  v_ed := v_b.end_date + 1;                       -- 取不含上界
  v_start := v_sd::timestamp at time zone 'Asia/Shanghai';
  v_end   := v_ed::timestamp at time zone 'Asia/Shanghai';
  v_month_key := v_b.period_key;

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
      'range_start', v_start, 'range_end', (v_ed - 1),
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
    'range_end', (v_ed - 1),
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

-- ------------------------------------------------------------
-- 轮询作业入口（pg_cron 每 10 分钟；也可管理员手动触发）
-- ------------------------------------------------------------
create or replace function public.maybe_run_period_jobs()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b       public.boundaries;
  v_results jsonb := '[]'::jsonb;
  v_one     jsonb;
  v_ok      int := 0;
  v_fail    int := 0;
begin
  -- 只有系统定时任务（pg_cron / SQL Editor）或管理员可手动触发，避免学生误触
  if public.caller_role() not in ('system', 'super_admin', 'admin') then
    raise exception '只有管理员或系统定时任务可以执行周期作业';
  end if;

  perform pg_advisory_xact_lock(hashtext('banji_period_jobs'));

  for v_b in
    select * from public.boundaries
     where settled = false and boundary_at <= now()
     order by boundary_at,
              case type when 'week' then 0 when 'rule_update' then 1 else 2 end
     limit 20
  loop
    begin
      if v_b.type = 'week' then
        v_one := public.weekly_snapshot(v_b.id);
      elsif v_b.type = 'month' then
        v_one := public.monthly_settle(v_b.id);
      else
        update public.boundaries set settled = true where id = v_b.id;
        v_one := jsonb_build_object('type', 'rule_update', 'boundary_id', v_b.id,
                                    'note', '规则周期重置点，仅作计数边界');
      end if;
      v_ok := v_ok + 1;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'boundary_id', v_b.id, 'type', v_b.type, 'period_key', v_b.period_key, 'ok', true));
    exception when others then
      v_fail := v_fail + 1;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'boundary_id', v_b.id, 'type', v_b.type, 'period_key', v_b.period_key,
        'ok', false, 'error', sqlerrm));
      if v_b.type = 'month' then
        update public.settlements set status = 'failed', note = sqlerrm
         where boundary_id = v_b.id and status = 'running';
      end if;
      perform public.write_audit('period_job_failed', 'boundary', v_b.id::text,
        jsonb_build_object('type', v_b.type, 'error', sqlerrm));
    end;
  end loop;

  return jsonb_build_object('ok_count', v_ok, 'fail_count', v_fail, 'results', v_results);
end;
$$;
revoke all on function public.maybe_run_period_jobs() from public, anon, authenticated;
grant execute on function public.maybe_run_period_jobs() to authenticated;

-- ------------------------------------------------------------
-- E4 结算运维：失败/未完成结算的重跑（已完成不自动重算，避免动历史）
-- ------------------------------------------------------------
create or replace function public.admin_resettle(p_boundary_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b  public.boundaries;
  v_st public.settlements;
  v_month_key text;
begin
  perform public.require_super_admin();
  select * into v_b from public.boundaries where id = p_boundary_id;
  if v_b.id is null then
    raise exception '分隔点不存在';
  end if;
  if v_b.type <> 'month' then
    raise exception '仅支持重跑月结算；周汇总重算请等待后续版本或联系维护';
  end if;
  select * into v_st from public.settlements
   where boundary_id = p_boundary_id and status <> 'rolled_back';
  if v_st.id is not null and v_st.status = 'done' then
    raise exception '该月已结算完成，不能自动重算（历史快照与抽选结果不可追改）';
  end if;

  v_month_key := v_b.period_key;

  -- 清理上次失败的半成品（只清理本结算点产生的自动数据与次数）
  delete from public.lottery_draws
   where period_key = v_month_key and source in ('auto','monthly_group_penalty','weekly_group','weekly_group_reward','weekly_group_penalty');
  delete from public.lottery_chances where period_key = v_month_key;
  if v_st.id is not null then
    update public.settlements set status = 'rolled_back', note = '管理员重跑'
     where id = v_st.id;
  end if;

  perform public.write_audit('resettle', 'boundary', p_boundary_id::text,
    jsonb_build_object('month_key', v_month_key, 'previous_status', v_st.status));
  return public.monthly_settle(p_boundary_id);
end;
$$;
revoke all on function public.admin_resettle(uuid) from public, anon, authenticated;
grant execute on function public.admin_resettle(uuid) to authenticated;

-- ------------------------------------------------------------
-- 周汇总列表（老师/记录员/学生按范围）
-- ------------------------------------------------------------
create or replace function public.list_weekly_summaries(p_limit int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_res  jsonb;
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  if v_role = 'student' then
    select coalesce(jsonb_agg(x order by x->>'range_end' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'period_key', w.period_key,
               'range_start', w.range_start,
               'range_end', w.range_end,
               'me', (select e from jsonb_array_elements(coalesce(w.summary->'individuals','[]'::jsonb)) e
                       where (e->>'student_id') = public.my_student_id()::text limit 1),
               'starlight_me', (select e from jsonb_array_elements(coalesce(w.summary->'starlight_individuals','[]'::jsonb)) e
                       where (e->>'student_id') = public.my_student_id()::text limit 1)
             ) as x
        from public.weekly_summaries w
       order by w.range_end desc
       limit greatest(coalesce(p_limit,12),1)
    ) q;
  else
    select coalesce(jsonb_agg(x order by x->>'range_end' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'period_key', w.period_key,
               'range_start', w.range_start,
               'range_end', w.range_end,
               'summary', w.summary
             ) as x
        from public.weekly_summaries w
       order by w.range_end desc
       limit greatest(coalesce(p_limit,12),1)
    ) q;
  end if;
  return jsonb_build_object('items', v_res);
end;
$$;
revoke all on function public.list_weekly_summaries(int) from public, anon, authenticated;
grant execute on function public.list_weekly_summaries(int) to authenticated;

-- ------------------------------------------------------------
-- 我的周/月汇总（学生只看自己；老师/记录员看全班/本组）
-- ------------------------------------------------------------
create or replace function public.my_summaries(
  p_type  text default 'month',
  p_limit int  default 6
) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_res  jsonb;
  v_me   uuid := public.my_student_id();
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  if p_type not in ('week','month') then
    raise exception '汇总类型不合法';
  end if;

  if p_type = 'week' then
    if v_role = 'student' then
      select coalesce(jsonb_agg(x order by x->>'range_end' desc), '[]'::jsonb) into v_res from (
        select jsonb_build_object(
                 'period_key', w.period_key, 'range_start', w.range_start, 'range_end', w.range_end,
                 'me', (select e from jsonb_array_elements(coalesce(w.summary->'individuals','[]'::jsonb)) e
                         where (e->>'student_id') = v_me::text limit 1),
                 'groups', w.summary->'groups',
                 'reward_groups', w.summary->'reward_groups',
                 'starlight_me', (select e from jsonb_array_elements(coalesce(w.summary->'starlight_individuals','[]'::jsonb)) e
                         where (e->>'student_id') = v_me::text limit 1)
               ) as x
          from public.weekly_summaries w
         order by w.range_end desc limit greatest(coalesce(p_limit,6),1)
      ) q;
    else
      select coalesce(jsonb_agg(x order by x->>'range_end' desc), '[]'::jsonb) into v_res from (
        select jsonb_build_object(
                 'period_key', w.period_key, 'range_start', w.range_start, 'range_end', w.range_end,
                 'summary', w.summary) as x
          from public.weekly_summaries w
         order by w.range_end desc limit greatest(coalesce(p_limit,6),1)
      ) q;
    end if;
    return jsonb_build_object('type', 'week', 'items', v_res);
  end if;

  if v_role = 'student' then
    select coalesce(jsonb_agg(x order by x->>'range_end' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'period_key', s.period_key, 'range_start', s.summary->'range_start',
               'range_end', s.summary->'range_end',
               'me', (select e from jsonb_array_elements(coalesce(s.summary->'individuals','[]'::jsonb)) e
                       where (e->>'student_id') = v_me::text limit 1),
               'second_class', (select e from jsonb_array_elements(coalesce(s.summary->'second_class','[]'::jsonb)) e
                       where (e->>'student_id') = v_me::text limit 1),
               'reward', (select e from jsonb_array_elements(coalesce(s.summary->'reward'->'rows','[]'::jsonb)) e
                       where (e->>'student_id') = v_me::text limit 1),
               'penalty', (select e from jsonb_array_elements(coalesce(s.summary->'penalty'->'rows','[]'::jsonb)) e
                       where (e->>'student_id') = v_me::text limit 1),
               'reward_forfeit', (select e from jsonb_array_elements(coalesce(s.summary->'reward'->'forfeit','[]'::jsonb)) e
                       where (e->>'student_id') = v_me::text limit 1)
             ) as x
        from public.settlements s
       where s.status = 'done'
       order by s.finished_at desc limit greatest(coalesce(p_limit,6),1)
    ) q;
  else
    select coalesce(jsonb_agg(x order by x->>'period_key' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'period_key', s.period_key,
               'range_start', s.summary->'range_start',
               'range_end', s.summary->'range_end',
               'summary', s.summary) as x
        from public.settlements s
       where s.status = 'done'
       order by s.finished_at desc limit greatest(coalesce(p_limit,6),1)
    ) q;
  end if;
  return jsonb_build_object('type', 'month', 'items', v_res);
end;
$$;
revoke all on function public.my_summaries(text, int) from public, anon, authenticated;
grant execute on function public.my_summaries(text, int) to authenticated;
