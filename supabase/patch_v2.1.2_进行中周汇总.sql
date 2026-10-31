-- =====================================================================
-- 班级积分管理系统 V2.1.2 补丁：允许「进行中」的周做汇总
-- ---------------------------------------------------------------------
-- 适用：已部署 V2.0.x / V2.1.0 / V2.1.1 的库（幂等，可重复执行）
-- 内容：
--   1) weekly_snapshot：统计区间改为「周起始 ~ 今天」；快照写入 in_progress
--   2) admin_run_weekly_summary：默认选「今天所在的周」；未开始的周才拒绝
-- 执行：Supabase SQL Editor 粘贴整段执行即可
-- =====================================================================

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
  v_in_progress boolean := false;
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
  -- V2.1.2：允许汇总「进行中」的周，统计范围截至今天（结束日期在未来的周）
  v_in_progress := v_b.end_date > public.bj_today();
  v_sd := v_b.start_date;
  v_ed := least(v_b.end_date, public.bj_today()) + 1;   -- 取不含上界
  v_start := v_sd::timestamp at time zone 'Asia/Shanghai';
  v_end   := v_ed::timestamp at time zone 'Asia/Shanghai';
  v_week_key := v_b.period_key;
  v_month_key := coalesce(public.period_key_of('month', least(v_b.end_date, public.bj_today())), public.current_month_key());

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
    'in_progress', v_in_progress,
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
    -- V2.1.2：优先「本周」（今天落在起止日期之间），否则取最近一个已结束的周
    select * into v_b from public.boundaries
     where type = 'week' and start_date is not null and end_date is not null
       and start_date <= public.bj_today() and end_date >= public.bj_today()
     order by start_date desc limit 1;
    if v_b.id is null then
      select * into v_b from public.boundaries
       where type = 'week' and start_date is not null and end_date is not null
         and end_date < public.bj_today()
       order by start_date desc limit 1;
    end if;
  else
    select * into v_b from public.boundaries where id = p_boundary_id;
  end if;

  if v_b.id is null then
    raise exception '没有找到可汇总的周分隔点';
  end if;
  if v_b.type <> 'week' then
    raise exception '该分隔点不是周分隔点';
  end if;
  if v_b.start_date is not null and v_b.start_date > public.bj_today() then
    raise exception '该周尚未开始，不能汇总';
  end if;

  -- 周分隔点关闭的是「上一周」，周期键必须按关闭的那一周推导（不能用分隔点自身所在周）
  v_key   := v_b.period_key;
  v_month := coalesce(public.period_key_of('month', v_b.end_date), public.current_month_key());

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
    jsonb_build_object('week_key', v_key, 'reward_chances', v_added, 'penalty_draws', v_draws,
                       'in_progress', (v_b.end_date is not null and v_b.end_date >= public.bj_today())));

  return jsonb_build_object(
    'week_key', v_key, 'boundary_id', v_b.id,
    'in_progress', (v_b.end_date is not null and v_b.end_date >= public.bj_today()),
    'reward_chances', v_added, 'penalty_draws', v_draws, 'summary', v_res);
end;
$$;
revoke all on function public.admin_run_weekly_summary(uuid) from public, anon, authenticated;
grant execute on function public.admin_run_weekly_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 自检（三行都应为 ok）
-- ---------------------------------------------------------------------
select 'weekly_snapshot 存在' as item,
       case when count(*)=1 then 'ok' else 'missing' end as r
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='weekly_snapshot'
union all
select 'admin_run_weekly_summary 存在',
       case when count(*)=1 then 'ok' else 'missing' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='admin_run_weekly_summary'
union all
select '允许进行中汇总（源码含 v_in_progress）',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='weekly_snapshot'
                            and p.prosrc like '%v_in_progress%') then 'ok' else 'missing' end;

-- 刷新 PostgREST 缓存，让新函数立即生效
notify pgrst, 'reload schema';
