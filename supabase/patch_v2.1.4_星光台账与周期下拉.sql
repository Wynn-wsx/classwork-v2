-- =====================================================================
-- 班级积分管理系统 V2.1.4 补丁：星光台账累计 + 周期下拉含当前周期
-- ---------------------------------------------------------------------
-- 适用：已部署 V2.0.19 及以上的库（幂等，可重复执行）
-- 内容：
--   1) starlight_table：不传月份 → 变动按全部流水累计（传 YYYY-MM 仍按该月，向后兼容）
--   2) list_summary_periods：周列表包含「进行中」的周（只排除尚未开始的未来周）
--   3) get_period_summary：允许读取「进行中」的周汇总
-- =====================================================================

create or replace function public.starlight_table(p_month_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text;
  v_month text;
  v_group text;
  v_out   jsonb;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder'],
    '没有权限查看星光台账'
  );
  v_role  := public.caller_role();
  -- 不传月份 = 统计全部流水（累计变动），表格预览已取消「统计月份」筛选
  v_month := nullif(btrim(coalesce(p_month_key, '')), '');
  if v_month is not null and v_month !~ '^\d{4}-\d{2}$' then
    raise exception '月份格式应为 YYYY-MM';
  end if;
  v_group := case when v_role = 'group_recorder' then public.my_group_name() else null end;

  with base as (
    select s.id, s.name, s.group_name,
           coalesce(a.balance, 0) as balance,
           coalesce(mc.month_change, 0) as month_change,
           coalesce(lc.log_count, 0) as log_count,
           lc.last_at as last_at,
           lc.last_note as last_note
      from public.students s
      left join public.starlight_accounts a on a.student_id = s.id
      left join (
        select l.student_id, sum(l.change_amount)::int as month_change
          from public.starlight_logs l
         where v_month is null or l.period_key = v_month
         group by l.student_id
      ) mc on mc.student_id = s.id
      left join (
        select l.student_id, count(*)::int as log_count,
               max(l.created_at) as last_at,
               (array_agg(l.note order by l.created_at desc))[1] as last_note
          from public.starlight_logs l
         group by l.student_id
      ) lc on lc.student_id = s.id
     where (v_group is null or s.group_name = v_group)
     order by coalesce(a.balance, 0) desc, s.name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id',  id,
           'name',        name,
           'group_name',  group_name,
           'balance',     balance,
           'month_change', month_change,
           'log_count',   log_count,
           'last_at',     last_at,
           'last_note',   last_note
         ) order by balance desc, name), '[]'::jsonb)
    into v_out
    from base;

  return jsonb_build_object(
    'month_key', coalesce(v_month, 'all'),
    'scope',     case when v_group is null then 'all' else 'group' end,
    'items',     v_out
  );
end;
$$;
revoke all on function public.starlight_table(text) from public, anon, authenticated;
grant execute on function public.starlight_table(text) to authenticated;
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
    -- 列出已开始（含进行中）的周；尚未开始的未来周不列
    select coalesce(jsonb_agg(x order by (x->>'start_date') desc), '[]'::jsonb) into v_list
      from (
        select jsonb_build_object(
                 'type', 'week',
                 'period_key', b.period_key,
                 'start_date', b.start_date,
                 'end_date', b.end_date,
                 'boundary_id', b.id,
                 'boundary_at', b.boundary_at,
                 'settled', b.settled,
                 'rule_weeks', b.rule_weeks,
                 'has_summary', exists (select 1 from public.weekly_summaries w where w.boundary_id = b.id),
                 'label', b.label
               ) as x
          from public.boundaries b
         where b.type = 'week'
           and b.start_date is not null
           and b.start_date <= public.bj_today()
         order by b.start_date desc
         limit greatest(coalesce(p_limit, 60), 1)
      ) q;
  else
    -- 月：含「进行中」的那一个（end_date 为空），方便前端显示「开始日期 ~ 进行中」
    select coalesce(jsonb_agg(x order by (x->>'start_date') desc nulls last), '[]'::jsonb) into v_list
      from (
        select jsonb_build_object(
                 'type', 'month',
                 'period_key', b.period_key,
                 'start_date', b.start_date,
                 'end_date', b.end_date,
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
           and b.start_date is not null
           and (b.end_date is not null or b.start_date <= public.bj_today())
         order by (b.end_date is null) desc, b.start_date desc
         limit greatest(coalesce(p_limit, 60), 1)
      ) q;
  end if;

  return jsonb_build_object('type', p_type, 'items', v_list);
end;
$$;
revoke all on function public.list_summary_periods(text, int) from public, anon, authenticated;
grant execute on function public.list_summary_periods(text, int) to authenticated;
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
     where type = 'week' and start_date <= public.bj_today()
      and period_key = v_key
     order by start_date desc limit 1;
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
$$;
revoke all on function public.get_period_summary(text, text) from public, anon, authenticated;
grant execute on function public.get_period_summary(text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 自检（三行都应为 ok）
-- ---------------------------------------------------------------------
select 'starlight_table 支持全部流水累计' as item,
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='starlight_table'
                            and p.prosrc like '%all%') then 'ok' else 'missing' end as r
union all
select 'list_summary_periods 包含进行中的周',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='list_summary_periods'
                            and p.prosrc like '%b.start_date <= public.bj_today()%') then 'ok' else 'missing' end
union all
select 'get_period_summary 可查进行中的周',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='get_period_summary'
                            and p.prosrc like '%start_date <= public.bj_today()%') then 'ok' else 'missing' end;

-- 刷新 PostgREST 缓存，让新函数立即生效
notify pgrst, 'reload schema';
