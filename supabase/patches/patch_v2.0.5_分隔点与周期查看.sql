-- ============================================================
-- V2.0.5 增量补丁（幂等，可在 Supabase SQL Editor 直接执行）
-- 适用：已经部署过 V2.0.0–V2.0.4 的项目
--
-- 本补丁做四件事：
--   1) 卡片登记使用支持指定「实际使用时间」：执行小组及以上可对已过期但实际在有效期内
--      使用过的卡片补登记（mark_draw_used 增加 p_used_at 参数）
--   2) 分隔点管理增强：编辑任意分隔点时间（含过去时间）、批量删除、立即分隔
--      （admin_edit_boundary / admin_delete_boundaries / admin_create_immediate_boundary）
--   3) 新增「规则分隔点」类型：只重置积分登记的次数/分值上限计数，不做任何汇总
--   4) 周/月汇总支持按周期查看与重新汇总：list_summary_periods / get_period_summary
--      另外：新增月分隔点时会自动补齐对应的周分隔点
--
-- 执行完请再执行：notify pgrst, 'reload schema';
-- ============================================================


-- ---------- 0. 清理旧签名（4 参数版 mark_draw_used） ----------
drop function if exists public.mark_draw_used(uuid, uuid, text, uuid);

-- ---------- 1. 卡片登记使用（支持补登记实际使用时间） ----------
create or replace function public.mark_draw_used(
  p_draw_id           uuid,
  p_related_record_id uuid default null,
  p_note              text default null,
  p_exchange_item_id  uuid default null,
  p_used_at           timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_draw public.lottery_draws;
  v_ex   public.lottery_items;
  v_new  uuid;
  v_role text := public.caller_role();
  v_used timestamptz := coalesce(p_used_at, now());
begin
  perform public.require_teacher();
  select * into v_draw from public.lottery_draws where id = p_draw_id;
  if v_draw.id is null then
    raise exception '抽选记录不存在';
  end if;
  if v_draw.item_kind <> 'func_card' then
    raise exception '只有功能卡需要登记使用';
  end if;
  if v_draw.status not in ('unused', 'expired') then
    raise exception '该卡片当前状态为「%」，不能登记使用', v_draw.status;
  end if;

  -- ★ 使用时间：执行小组及以上可以指定（补登记已过期但实际在有效期内使用的卡）
  if p_used_at is not null then
    if v_role not in ('system', 'super_admin', 'admin', 'executive') then
      raise exception '只有执行小组及以上权限可以指定使用时间';
    end if;
    if v_draw.drawn_at is not null and v_used < v_draw.drawn_at then
      raise exception '使用时间不能早于抽中时间（%），请重新填写', to_char(v_draw.drawn_at at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI');
    end if;
    if v_draw.expire_at is not null and v_used > v_draw.expire_at then
      raise exception '使用时间需在该卡有效期内（有效期至 %），请重新填写',
        to_char(v_draw.expire_at at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI');
    end if;
    if v_draw.expire_at is not null and v_draw.expire_at < now() and v_used <= v_draw.expire_at then
      -- 过期补登记：使用时间在有效期内，允许把 expired 恢复为 used
      update public.lottery_draws set status = 'unused' where id = p_draw_id and status = 'expired';
    end if;
  else
    if v_draw.expire_at is not null and v_draw.expire_at < now() then
      raise exception '该卡片已过期；若实际在有效期内已使用，请由执行小组及以上权限填写「使用时间」补登记';
    end if;
  end if;

  update public.lottery_draws
     set status = 'used', used_by = auth.uid(), used_at = v_used,
         related_record_id = coalesce(p_related_record_id, related_record_id),
         note = coalesce(p_note, note)
   where id = p_draw_id;

  -- 万能卡兑换：登记原卡已用 + 生成换代卡（有效期到当前月分隔点后）
  if p_exchange_item_id is not null then
    select * into v_ex from public.lottery_items where id = p_exchange_item_id;
    if v_ex.id is null then
      raise exception '兑换卡种不存在';
    end if;
    if v_ex.item_kind <> 'func_card' then
      raise exception '只能兑换为功能卡';
    end if;
    v_new := public._apply_draw(v_draw.student_id, 'reward', v_ex.id, v_draw.period_key,
      'manual', v_draw.group_name, '[]'::jsonb, false,
      '万能卡兑换自：' || coalesce(v_draw.item_snapshot->>'title',''), auth.uid());
    update public.lottery_draws set note = '已兑换为「' || v_ex.title || '」' where id = p_draw_id;
  end if;

  perform public.notify((select p.id from public.profiles p where p.student_id = v_draw.student_id limit 1),
    '卡片使用登记', format('你的「%s」已被登记为已使用。', coalesce(v_draw.item_snapshot->>'title','卡片')),
    'lottery', 'lottery_draw', p_draw_id);
  perform public.write_audit('mark_draw_used', 'lottery_draw', p_draw_id::text,
    jsonb_build_object('exchange_item_id', p_exchange_item_id, 'new_draw_id', v_new, 'note', p_note,
                       'used_at', v_used, 'backdated', (p_used_at is not null)));

  return jsonb_build_object(
    'ok', true,
    'draw_id', p_draw_id,
    'new_draw_id', v_new,
    'draw', (select to_jsonb(d) from public.lottery_draws d where d.id = p_draw_id)
  );
end;
$$;
revoke all on function public.mark_draw_used(uuid, uuid, text, uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.mark_draw_used(uuid, uuid, text, uuid, timestamptz) to authenticated;

-- ---------- 2. 新增分隔点（月分隔自动补齐周分隔） ----------
create or replace function public.admin_add_boundary(
  p_type        text,
  p_boundary_at timestamptz,
  p_label       text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_row public.boundaries;
begin
  perform public.require_super_admin();
  if p_type not in ('week','month','rule_update') then
    raise exception '分隔点类型不合法';
  end if;
  if p_boundary_at is null then
    raise exception '请填写分隔点时间';
  end if;
  insert into public.boundaries (type, period_key, boundary_at, label, is_manual, created_by)
  values (
    p_type,
    to_char(p_boundary_at at time zone 'Asia/Shanghai', case p_type when 'month' then 'YYYY-MM' else 'IYYY-IW' end),
    p_boundary_at,
    coalesce(p_label, '手动分隔点'),
    true,
    auth.uid()
  )
  on conflict (type, boundary_at) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from public.boundaries where type = p_type and boundary_at = p_boundary_at;
  else
    perform public.write_audit('add_boundary', 'boundary', v_row.id::text, to_jsonb(v_row));
  end if;

  -- 月分隔点新增后立即补齐对应的周分隔点：保证“本周跨过月分隔”时周/月两级都有分隔点
  perform public.ensure_boundaries();

  return to_jsonb(v_row) || jsonb_build_object(
    'auto_week_boundaries', case when p_type = 'month' then true else false end,
    'hint', case when p_type = 'month'
                 then '已在月分隔点前后自动补齐周分隔点，避免跨月周缺少周汇总节点'
                 else null end);
end;
$$;
revoke all on function public.admin_add_boundary(text, timestamptz, text) from public, anon, authenticated;
grant execute on function public.admin_add_boundary(text, timestamptz, text) to authenticated;

-- ---------- 3. 分隔点编辑 / 批量删除 / 立即分隔 ----------
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

create or replace function public.admin_delete_boundaries(p_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id      uuid;
  v_row     public.boundaries;
  v_del     int := 0;
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
    if v_row.settled then
      v_reason := '已结算的分隔点不能删除（会影响历史冻结与汇总判定）';
    elsif exists (select 1 from public.weekly_summaries w where w.boundary_id = v_row.id) then
      v_reason := '该周已有汇总记录，请先删除汇总';
    elsif exists (select 1 from public.settlements s where s.boundary_id = v_row.id and s.status <> 'rolled_back') then
      v_reason := '该月已有结算记录，请先回滚结算';
    elsif v_row.period_key = public.current_month_key() and v_row.type = 'month' then
      v_reason := '当前月份的分隔点不能删除';
    elsif v_row.period_key = public.current_week_key() and v_row.type = 'week' then
      v_reason := '当前周的分隔点不能删除';
    end if;
    if v_reason is not null then
      v_skip := v_skip || jsonb_build_array(jsonb_build_object('id', v_id, 'reason', v_reason,
        'type', v_row.type, 'period_key', v_row.period_key));
      continue;
    end if;
    delete from public.boundaries where id = v_id;
    v_del := v_del + 1;
  end loop;

  perform public.write_audit('delete_boundaries', 'boundary', '',
    jsonb_build_object('deleted', v_del, 'skipped', v_skip));
  return jsonb_build_object('deleted', v_del, 'skipped', v_skip);
end;
$$;
revoke all on function public.admin_delete_boundaries(uuid[]) from public, anon, authenticated;
grant execute on function public.admin_delete_boundaries(uuid[]) to authenticated;

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

-- ---------- 4. 汇总周期列表 / 按周期查看 ----------
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


-- ---------- 5. 自检 ----------
select 'V2.0.5 补丁已应用' as 结果,
       (select count(*) from information_schema.routines
         where routine_schema = 'public'
           and routine_name in ('admin_edit_boundary', 'admin_delete_boundaries',
                                'admin_create_immediate_boundary', 'list_summary_periods',
                                'get_period_summary')) as 新函数_应为5,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'mark_draw_used') as 同名函数数_应为1,
       (select pg_get_function_identity_arguments(p.oid) from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'mark_draw_used' limit 1) as 登记使用函数参数;
