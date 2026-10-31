-- =====================================================================
-- 班级积分管理系统 V2.1.3 补丁：奖惩抽选支持「进行中」的周
-- ---------------------------------------------------------------------
-- 适用：已部署 V2.0.14 及以上（含 V2.1.x）的库（幂等，可重复执行）
-- 内容：
--   1) admin_group_week_board：默认选「今天所在的周」，统计截至今天，
--      返回 in_progress，周下拉包含进行中的周
--   2) admin_draw_group_manual：默认同样选「今天所在的周」，
--      允许为尚未结束的周抽奖（只有「尚未开始」的周被拒绝）
-- 说明：每组每池每周限一次的判定不变
-- =====================================================================

create or replace function public.admin_group_week_board(p_week_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_key    text := nullif(btrim(coalesce(p_week_key, '')), '');
  v_b      public.boundaries;
  v_sum    public.weekly_summaries;
  v_groups jsonb;
  v_items  jsonb;
  v_top    int := 3;
  v_bottom int := 2;
  v_cnt    int := 0;
  v_start  timestamptz;
  v_end    timestamptz;
begin
  if v_role not in ('system', 'super_admin', 'admin', 'executive') then
    raise exception '只有执行小组及以上可以查看小组抽奖看板';
  end if;
  if v_key is null then
    -- 优先「今天所在的周」（周未结束也允许抽奖），否则取最近一个已结束的周
    select b.* into v_b from public.boundaries b
     where b.type = 'week' and b.deprecated = false and b.end_date is not null
       and b.start_date <= public.bj_today() and b.end_date >= public.bj_today()
     order by b.start_date desc limit 1;
    if v_b.id is null then
      select b.* into v_b from public.boundaries b
       where b.type = 'week' and b.deprecated = false and b.end_date is not null
         and b.end_date < public.bj_today()
       order by b.end_date desc limit 1;
    end if;
    if v_b.id is null then
      raise exception '还没有进行中或已结束的周周期，请先在「设置 → 周期定义」补全';
    end if;
    v_key := v_b.period_key;
  else
    select b.* into v_b from public.boundaries b
     where b.type = 'week' and b.deprecated = false and b.period_key = v_key
     order by b.start_date desc limit 1;
  end if;

  if v_b.id is null then
    v_start := now() - interval '7 days';
    v_end   := now();
    select coalesce((public.cfg()->>'week_reward_top_groups')::int, 3),
           coalesce((public.cfg()->>'week_penalty_bottom_groups')::int, 2)
      into v_top, v_bottom;
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
                   and rec.record_date <  to_char((v_end at time zone 'Asia/Shanghai')::date, 'YYYY-MM-DD')
                 group by rec.student_id) r on r.student_id = s.id
          ) q
         group by q.group_name) g;
  else
    v_start := v_b.start_date::timestamp at time zone 'Asia/Shanghai';
    -- 周未结束时统计到今天（含今天）
    v_end   := (least(v_b.end_date, public.bj_today()) + 1)::timestamp at time zone 'Asia/Shanghai';
    select coalesce((public.cfg()->>'week_reward_top_groups')::int, 3),
           coalesce((public.cfg()->>'week_penalty_bottom_groups')::int, 2)
      into v_top, v_bottom;

    select * into v_sum from public.weekly_summaries w
     where w.boundary_id = v_b.id
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
                     and rec.record_date >= to_char(v_b.start_date, 'YYYY-MM-DD')
                     and rec.record_date <= to_char(least(v_b.end_date, public.bj_today()), 'YYYY-MM-DD')
                   group by rec.student_id) r on r.student_id = s.id
            ) q
           group by q.group_name) g;
    end if;
  end if;

  v_cnt := jsonb_array_length(v_groups);

  select coalesce(jsonb_agg(jsonb_build_object(
           'group_name', x.group_name,
           'total', x.total,
           'rank', x."rank",
           'pos', x.pos,
           'members', (select count(*) from public.students s where s.group_name = x.group_name),
           'reward_suggested', (x.pos <= v_top),
           'penalty_suggested', (v_cnt >= v_top + v_bottom and x.pos > v_cnt - v_bottom and x.pos > v_top),
           'reward_drawn', exists(select 1 from public.lottery_draws d
                                   where d.group_name = x.group_name and d.pool_type = 'reward'
                                     and d.source_week_key = v_key and d.status <> 'void'
                                     and d.is_group = true),
           'penalty_drawn', exists(select 1 from public.lottery_draws d
                                    where d.group_name = x.group_name and d.pool_type = 'penalty'
                                      and d.source_week_key = v_key and d.status <> 'void'
                                      and d.is_group = true),
           'reward_item', (select d.item_snapshot->>'title' from public.lottery_draws d
                            where d.group_name = x.group_name and d.pool_type = 'reward'
                              and d.source_week_key = v_key and d.status <> 'void'
                              and d.is_group = true order by d.drawn_at limit 1),
           'penalty_item', (select d.item_snapshot->>'title' from public.lottery_draws d
                             where d.group_name = x.group_name and d.pool_type = 'penalty'
                               and d.source_week_key = v_key and d.status <> 'void'
                               and d.is_group = true order by d.drawn_at limit 1),
           'reward_at', (select max(d.drawn_at) from public.lottery_draws d
                          where d.group_name = x.group_name and d.pool_type = 'reward'
                            and d.source_week_key = v_key and d.status <> 'void'
                            and d.is_group = true),
           'penalty_at', (select max(d.drawn_at) from public.lottery_draws d
                           where d.group_name = x.group_name and d.pool_type = 'penalty'
                             and d.source_week_key = v_key and d.status <> 'void'
                             and d.is_group = true)
         ) order by x.pos), '[]'::jsonb)
    into v_items
    from jsonb_to_recordset(v_groups) as x(group_name text, total numeric, "rank" int, pos int);

  return jsonb_build_object(
    'week_key', v_key,
    'range_start', v_start,
    'range_end', v_end,
    'has_summary', (v_sum.id is not null),
    'in_progress', coalesce((v_b.end_date is not null and v_b.end_date > public.bj_today()), false),
    'top_n', v_top,
    'bottom_n', v_bottom,
    'group_count', v_cnt,
    'groups', coalesce(v_items, '[]'::jsonb),
    'week_options', coalesce((
      select jsonb_agg(jsonb_build_object(
               'week_key', w.period_key,
               'range_start', w.start_date::timestamp at time zone 'Asia/Shanghai',
               'range_end', (w.end_date + 1)::timestamp at time zone 'Asia/Shanghai',
               'has_summary', exists(select 1 from public.weekly_summaries ws where ws.boundary_id = w.id),
               'in_progress', (w.end_date > public.bj_today()))
             order by w.end_date desc)
        from (select b.id, b.period_key, b.start_date, b.end_date from public.boundaries b
               where b.type = 'week' and b.deprecated = false and b.end_date is not null
               order by b.end_date desc limit 12) w
    ), '[]'::jsonb));
end;
$$;
revoke all on function public.admin_group_week_board(text) from public, anon, authenticated;
grant execute on function public.admin_group_week_board(text) to authenticated;

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

  -- 默认取「今天所在的周」（周未结束也可抽），否则最近一个已结束的周（与看板一致）
  v_key := coalesce(nullif(btrim(coalesce(p_week_key, '')), ''), (
    select coalesce(
      (select b2.period_key from public.boundaries b2
        where b2.type = 'week' and b2.deprecated = false
          and b2.start_date <= public.bj_today() and b2.end_date >= public.bj_today()
        order by b2.start_date desc limit 1),
      (select b2.period_key from public.boundaries b2
        where b2.type = 'week' and b2.deprecated = false and b2.end_date < public.bj_today()
        order by b2.end_date desc limit 1)
    )), public.current_week_key());
  select * into v_b from public.boundaries b
   where b.type = 'week'
     and b.period_key = v_key
   order by b.boundary_at desc limit 1;
  if v_b.id is null then
    raise exception '周「%」不存在，请先在设置里立即分隔或选择其它周', v_key;
  end if;
  if v_b.start_date is not null and v_b.start_date > public.bj_today() then
    raise exception '周「%」尚未开始，不能为小组抽奖', v_key;
  end if;
  v_start := v_b.start_date::timestamp at time zone 'Asia/Shanghai';
  v_end   := (least(v_b.end_date, public.bj_today()) + 1)::timestamp at time zone 'Asia/Shanghai';
  v_period := coalesce(public.period_key_of('month', v_b.end_date), public.current_month_key());
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
$$;
revoke all on function public.admin_draw_group_manual(text, text, text, text) from public, anon, authenticated;
grant execute on function public.admin_draw_group_manual(text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 自检（四行都应为 ok）
-- ---------------------------------------------------------------------
select 'admin_group_week_board 存在' as item,
       case when count(*)=1 then 'ok' else 'missing' end as r
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='admin_group_week_board'
union all
select 'admin_draw_group_manual 存在',
       case when count(*)=1 then 'ok' else 'missing' end
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='admin_draw_group_manual'
union all
select '看板支持进行中的周（源码含 in_progress）',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='admin_group_week_board'
                            and p.prosrc like '%in_progress%') then 'ok' else 'missing' end
union all
select '抽奖允许本周（源码含 尚未开始）',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='admin_draw_group_manual'
                            and p.prosrc like '%尚未开始%') then 'ok' else 'missing' end;

-- 刷新 PostgREST 缓存，让新函数立即生效
notify pgrst, 'reload schema';
