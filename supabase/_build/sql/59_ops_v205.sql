-- ============================================================
-- 5.9 V2.0.5 分隔点管理增强 / 周期汇总按周期查询
--   1) admin_edit_boundary      编辑分隔点（含过去时间，重算周期键）
--   2) admin_delete_boundaries  批量删除分隔点（未结算、无汇总才可删）
--   3) admin_create_immediate_boundary  立即分隔（周/月/规则），并立刻执行周期作业
--   4) list_summary_periods     汇总周期下拉（周/月，含是否已有汇总）
--   5) get_period_summary       按周期读取周汇总 / 月结算明细（过去周期可查看）
-- ============================================================

create or replace function public.admin_edit_boundary(
  p_id          uuid,
  p_boundary_at timestamptz default null,
  p_label       text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_row   public.boundaries;
  v_after public.boundaries;
  v_has   boolean := false;
begin
  perform public.require_super_admin();
  select * into v_row from public.boundaries where id = p_id;
  if v_row.id is null then
    raise exception '分隔点不存在';
  end if;

  v_has := exists (select 1 from public.weekly_summaries w where w.boundary_id = p_id)
        or exists (select 1 from public.settlements s where s.boundary_id = p_id and s.status <> 'rolled_back');

  update public.boundaries b
     set boundary_at = coalesce(p_boundary_at, b.boundary_at),
         period_key  = to_char(coalesce(p_boundary_at, b.boundary_at) at time zone 'Asia/Shanghai',
                               case b.type when 'month' then 'YYYY-MM' else 'IYYY-IW' end),
         label       = coalesce(nullif(trim(coalesce(p_label, '')), ''), b.label)
   where b.id = p_id
   returning * into v_after;

  -- 月分隔点变更后补齐对应的周分隔点（保证周/月两级都能对齐）
  if v_after.type = 'month' then
    perform public.ensure_boundaries();
  end if;

  perform public.write_audit('edit_boundary', 'boundary', p_id::text,
    jsonb_build_object('before', to_jsonb(v_row), 'after', to_jsonb(v_after),
                       'had_summary', v_has));

  return jsonb_build_object(
    'boundary', to_jsonb(v_after),
    'had_summary', v_has,
    'hint', case when v_has
                 then '该分隔点已有汇总记录，修改时间不会自动重算历史汇总，请在「周期汇总」中按需重新汇总'
                 else null end
  );
end;
$$;
revoke all on function public.admin_edit_boundary(uuid, timestamptz, text) from public, anon, authenticated;
grant execute on function public.admin_edit_boundary(uuid, timestamptz, text) to authenticated;

-- ------------------------------------------------------------
-- 批量删除分隔点：已结算的也允许删（级联清掉其周汇总/月结算快照），仅当前周/当前月的分隔点跳过
-- ------------------------------------------------------------
create or replace function public.admin_delete_boundaries(p_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id      uuid;
  v_row     public.boundaries;
  v_del     int := 0;
  v_sum     int := 0;
  v_set     int := 0;
  v_skip    jsonb := '[]'::jsonb;
  v_reason  text;
begin
  perform public.require_super_admin();
  if p_ids is null or array_length(p_ids, 1) is null then
    raise exception '请选择要删除的分隔点';
  end if;

  foreach v_id in array p_ids loop
    select * into v_row from public.boundaries where id = v_id;
    if v_row.id is null then
      v_skip := v_skip || jsonb_build_array(jsonb_build_object('id', v_id, 'reason', '不存在'));
      continue;
    end if;
    v_reason := null;
    -- V2.0.6：已结算分隔点允许删除，其周汇总/月结算记录随外键级联删除（会同时清掉历史快照，删除前前端会二次确认）
    if v_row.period_key = public.current_month_key() and v_row.type = 'month' then
      v_reason := '当前月份的分隔点不能删除';
    elsif v_row.period_key = public.current_week_key() and v_row.type = 'week' then
      v_reason := '当前周的分隔点不能删除';
    end if;
    if v_reason is not null then
      v_skip := v_skip || jsonb_build_array(jsonb_build_object('id', v_id, 'reason', v_reason,
        'type', v_row.type, 'period_key', v_row.period_key));
      continue;
    end if;
    v_sum := v_sum + (select count(*) from public.weekly_summaries w where w.boundary_id = v_row.id);
    v_set := v_set + (select count(*) from public.settlements s where s.boundary_id = v_row.id);
    delete from public.boundaries where id = v_id;
    v_del := v_del + 1;
  end loop;

  perform public.write_audit('delete_boundaries', 'boundary', '',
    jsonb_build_object('deleted', v_del, 'skipped', v_skip,
                       'cascaded_summaries', v_sum, 'cascaded_settlements', v_set));
  return jsonb_build_object('deleted', v_del, 'skipped', v_skip,
                            'cascaded_summaries', v_sum, 'cascaded_settlements', v_set);
end;
$$;
revoke all on function public.admin_delete_boundaries(uuid[]) from public, anon, authenticated;
grant execute on function public.admin_delete_boundaries(uuid[]) to authenticated;

-- ------------------------------------------------------------
-- 立即分隔：新建一个“此刻”的分隔点并立刻执行周期作业
--   week         → 立即生成周汇总（并发放小组集体抽选）
--   month        → 立即月度结算（进入维护模式、自动抽选、次数清零）
--   rule_update  → 仅重置规则周期上限计数，不做任何汇总
-- ------------------------------------------------------------
create or replace function public.admin_create_immediate_boundary(p_type text default 'week')
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_row public.boundaries;
  v_job jsonb;
begin
  perform public.require_super_admin();
  if p_type not in ('week', 'month', 'rule_update') then
    raise exception '分隔点类型只能是 week / month / rule_update';
  end if;

  insert into public.boundaries (type, period_key, boundary_at, label, is_manual, settled, created_by)
  values (
    p_type,
    to_char(now() at time zone 'Asia/Shanghai', case p_type when 'month' then 'YYYY-MM' else 'IYYY-IW' end),
    now(),
    '立即分隔（' || case p_type when 'week' then '周' when 'month' then '月' else '规则周期' end || '）',
    true,
    false,
    auth.uid()
  )
  on conflict (type, boundary_at) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from public.boundaries
     where type = p_type and boundary_at = (select max(boundary_at) from public.boundaries where type = p_type and boundary_at <= now());
  end if;

  perform public.write_audit('create_immediate_boundary', 'boundary', v_row.id::text, to_jsonb(v_row));

  -- 规则周期只重置上限计数：不触发任何汇总，直接把该点标记为已处理
  if p_type = 'rule_update' then
    update public.boundaries set settled = true where id = v_row.id;
    return jsonb_build_object('boundary', to_jsonb(v_row), 'jobs', null,
      'message', '已建立规则周期分隔点：本周期内的积分登记次数/分值上限从此刻起重新计算，不生成任何汇总');
  end if;

  v_job := public.maybe_run_period_jobs();
  return jsonb_build_object('boundary', (select to_jsonb(b) from public.boundaries b where b.id = v_row.id),
                            'jobs', v_job,
                            'message', '已立即分隔并处理到点周期');
end;
$$;
revoke all on function public.admin_create_immediate_boundary(text) from public, anon, authenticated;
grant execute on function public.admin_create_immediate_boundary(text) to authenticated;

-- ------------------------------------------------------------
-- 汇总周期下拉：列出过去周期的分隔点及是否已有汇总
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
                 'period_key', b.period_key,
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
$$;
revoke all on function public.list_summary_periods(text, int) from public, anon, authenticated;
grant execute on function public.list_summary_periods(text, int) to authenticated;

-- ------------------------------------------------------------
-- 按周期读取汇总明细（过去周期可查看；学生只返回自己的切片）
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
     where type = 'week' and period_key = v_key and boundary_at <= now()
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
$$;
revoke all on function public.get_period_summary(text, text) from public, anon, authenticated;
grant execute on function public.get_period_summary(text, text) to authenticated;
