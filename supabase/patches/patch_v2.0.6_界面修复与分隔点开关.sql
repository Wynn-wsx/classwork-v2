-- ============================================================
-- V2.0.6 增量补丁（幂等，可在 Supabase SQL Editor 直接执行）
-- 适用：已经部署过 V2.0.0–V2.0.5 的项目
--
-- 本补丁做四件事：
--   1) 积分明细的「记录人 / 修改信息」不再显示 UUID：records 增加 recorder_name、
--      modified_by_name 两列，写入时记录姓名，并按现有 profiles 回填历史数据
--   2) 时间规则增加开关「按规则自动生成分隔点」（app_config.auto_boundaries）；
--      关闭后不再预生成未来分隔点，已有分隔点不受影响
--   3) 应急维护可单独指定结束时间（admin_toggle_maintenance 增加 p_until 参数）
--   4) 已结算的分隔点允许删除（会级联清理其周汇总/月度结算快照），当前周/当前月仍禁止删除
--
-- 执行完请再执行：notify pgrst, 'reload schema';
-- ============================================================


-- ---------- 0. 清理旧签名 ----------
drop function if exists public.admin_toggle_maintenance(boolean, int);


-- ---------- 1. 记录人/修改人姓名列 ----------
alter table public.records add column if not exists recorder_name text;
alter table public.records add column if not exists modified_by_name text;

-- 回填历史数据（按 profiles 现有姓名）
update public.records r
   set recorder_name = p.name
  from public.profiles p
 where r.recorder_name is null and r.recorder_id = p.id;

update public.records r
   set modified_by_name = p.name
  from public.profiles p
 where r.modified_by_name is null and r.modified_by = p.id;


-- ---------- 2. 配置列：是否按规则自动生成分隔点 ----------
alter table public.app_config add column if not exists auto_boundaries boolean not null default true;


-- ---------- 3. 积分登记相关函数（写入时记录姓名） ----------
create or replace function public.add_record(
  p_student_id  uuid,
  p_score_type  text,
  p_category    text,
  p_reason      text,
  p_points      numeric,
  p_record_date date,
  p_rule_id     uuid default null,
  p_evidence    text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_rec  public.records;
begin
  perform public.require_role(array['super_admin','admin','executive','group_recorder'], '没有权限登记积分');
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能登记';
  end if;
  if p_student_id is null then
    raise exception '请选择学生';
  end if;
  if not exists (select 1 from public.students where id = p_student_id) then
    raise exception '学生不存在';
  end if;
  if v_role = 'group_recorder' and not public.student_in_my_group(p_student_id) then
    raise exception '记录员只能登记本组学生';
  end if;
  if p_score_type not in ('加分','扣分') then
    raise exception '积分类型必须是「加分」或「扣分」';
  end if;
  if coalesce(p_points, 0) = 0 then
    raise exception '分值不能为 0';
  end if;
  if p_score_type = '加分' and p_points < 0 then
    raise exception '加分记录的分值必须为正数';
  end if;
  if p_score_type = '扣分' and p_points > 0 then
    raise exception '扣分记录的分值必须为负数';
  end if;
  if p_record_date is null then
    raise exception '请选择登记日期';
  end if;
  if public.is_future_date(p_record_date) then
    raise exception '不能登记未来日期';
  end if;
  if public.is_month_frozen(p_record_date) then
    raise exception '该登记月已冻结，不能新增记录（如需纠错请让管理员处理）';
  end if;

  perform public.check_rule_limit(p_rule_id, p_points, null);

  insert into public.records (
    student_id, score_type, category, reason, points, recorder_id, recorder_name,
    record_date, status, evidence, rule_id, frozen_until, period_key
  ) values (
    p_student_id, p_score_type, coalesce(p_category,''), coalesce(p_reason,''), p_points, auth.uid(),
    (select p.name from public.profiles p where p.id = auth.uid()),
    p_record_date::text, '正常', p_evidence, p_rule_id,
    now() + interval '2 seconds', to_char(p_record_date, 'YYYY-MM')
  ) returning * into v_rec;

  perform public.write_audit('add_record', 'record', v_rec.id::text,
    jsonb_build_object('student_id', p_student_id, 'points', p_points,
                       'reason', p_reason, 'record_date', p_record_date));
  return to_jsonb(v_rec);
end;
$$;
revoke all on function public.add_record(uuid, text, text, text, numeric, date, uuid, text) from public, anon, authenticated;
grant execute on function public.add_record(uuid, text, text, text, numeric, date, uuid, text) to authenticated;

create or replace function public.update_record(
  p_id          uuid,
  p_reason      text,
  p_points      numeric,
  p_evidence    text default null,
  p_record_date date default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_old  public.records;
  v_new  public.records;
  v_date date;
begin
  perform public.require_role(array['super_admin','admin','executive','group_recorder'], '没有权限修改积分记录');
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能修改';
  end if;
  select * into v_old from public.records where id = p_id;
  if v_old.id is null then
    raise exception '记录不存在';
  end if;
  if v_old.status <> '正常' then
    raise exception '该记录已删除，不能修改';
  end if;
  if v_role = 'group_recorder' and not public.student_in_my_group(v_old.student_id) then
    raise exception '记录员只能修改本组记录';
  end if;
  if v_old.frozen_until is not null and now() < v_old.frozen_until then
    raise exception '该记录刚写入，处于 2 秒锁定中，请稍后再改';
  end if;
  if public.is_month_frozen((nullif(v_old.record_date,''))::date) then
    raise exception '该登记月已冻结，不能修改（管理员纠错除外）';
  end if;

  v_date := coalesce(p_record_date, (nullif(v_old.record_date,''))::date);
  if v_date is null then
    v_date := public.bj_today();
  end if;
  if public.is_future_date(v_date) then
    raise exception '不能登记未来日期';
  end if;
  if v_date <> (nullif(v_old.record_date,''))::date and public.is_month_frozen(v_date) then
    raise exception '目标登记月已冻结，不能改到该月';
  end if;

  perform public.check_rule_limit(v_old.rule_id, p_points, v_old.id);

  update public.records
     set reason      = coalesce(p_reason, reason),
         points      = p_points,
         evidence    = coalesce(p_evidence, evidence),
         record_date = v_date::text,
         period_key  = to_char(v_date, 'YYYY-MM'),
         modified_by = auth.uid(),
         modified_by_name = (select p.name from public.profiles p where p.id = auth.uid()),
         modified_at = now(),
         frozen_until = now() + interval '2 seconds'
   where id = p_id
   returning * into v_new;

  perform public.write_audit('update_record', 'record', p_id::text,
    jsonb_build_object('old', jsonb_build_object('points', v_old.points, 'reason', v_old.reason, 'record_date', v_old.record_date),
                       'new', jsonb_build_object('points', p_points, 'reason', p_reason, 'record_date', v_date)));
  return to_jsonb(v_new);
end;
$$;
revoke all on function public.update_record(uuid, text, numeric, text, date) from public, anon, authenticated;
grant execute on function public.update_record(uuid, text, numeric, text, date) to authenticated;

create or replace function public.delete_record(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_old  public.records;
  v_new  public.records;
begin
  perform public.require_role(array['super_admin','admin','executive','group_recorder'], '没有权限删除积分记录');
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能删除';
  end if;
  select * into v_old from public.records where id = p_id;
  if v_old.id is null then
    raise exception '记录不存在';
  end if;
  if v_old.status <> '正常' then
    raise exception '该记录已删除';
  end if;
  if v_role = 'group_recorder' and not public.student_in_my_group(v_old.student_id) then
    raise exception '记录员只能删除本组记录';
  end if;
  if v_old.frozen_until is not null and now() < v_old.frozen_until then
    raise exception '该记录刚写入，处于 2 秒锁定中，请稍后再删';
  end if;
  if public.is_month_frozen((nullif(v_old.record_date,''))::date) then
    raise exception '该登记月已冻结，不能删除（管理员纠错除外）';
  end if;

  update public.records
     set status = '已删除',
         modified_by = auth.uid(),
         modified_by_name = (select p.name from public.profiles p where p.id = auth.uid()),
         modified_at = now()
   where id = p_id
   returning * into v_new;

  perform public.write_audit('delete_record', 'record', p_id::text,
    jsonb_build_object('student_id', v_old.student_id, 'points', v_old.points,
                       'reason', v_old.reason, 'record_date', v_old.record_date));
  return to_jsonb(v_new);
end;
$$;
revoke all on function public.delete_record(uuid) from public, anon, authenticated;
grant execute on function public.delete_record(uuid) to authenticated;

create or replace function public.admin_fix_frozen_record(p_id uuid, p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_old public.records;
  v_new public.records;
  v_date date;
begin
  perform public.require_super_admin();
  select * into v_old from public.records where id = p_id;
  if v_old.id is null then
    raise exception '记录不存在';
  end if;
  if not public.is_month_frozen((nullif(v_old.record_date,''))::date) then
    raise exception '该记录不在冻结月，请用普通修改/删除';
  end if;

  v_date := coalesce((p_patch->>'record_date')::date, (nullif(v_old.record_date,''))::date);

  update public.records
     set points      = coalesce((p_patch->>'points')::numeric, points),
         reason      = coalesce(p_patch->>'reason', reason),
         category    = coalesce(p_patch->>'category', category),
         evidence    = coalesce(p_patch->>'evidence', evidence),
         record_date = v_date::text,
         period_key  = to_char(v_date, 'YYYY-MM'),
         status      = coalesce(p_patch->>'status', status),
         modified_by = auth.uid(),
         modified_by_name = (select p.name from public.profiles p where p.id = auth.uid()),
         modified_at = now(),
         frozen_until = null
   where id = p_id
   returning * into v_new;

  perform public.write_audit('admin_fix_frozen_record', 'record', p_id::text,
    jsonb_build_object('old', to_jsonb(v_old), 'patch', p_patch));
  return to_jsonb(v_new);
end;
$$;
revoke all on function public.admin_fix_frozen_record(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.admin_fix_frozen_record(uuid, jsonb) to authenticated;

-- ---------- 4. 周期 / 分隔点 / 维护相关函数 ----------
create or replace function public.ensure_boundaries(
  p_months_back    int default 6,
  p_months_forward int default 12
) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_local   timestamp := (now() at time zone 'Asia/Shanghai');
  v_week    jsonb;
  v_month   jsonb;
  v_dow     int;
  v_hour    int;
  v_minute  int;
  v_dom     int;
  v_cursor  timestamp;
  v_cand    timestamp;
  v_end     timestamp;
  v_start   timestamp;
  v_count   int := 0;
begin
  -- V2.0.6：可关闭「按规则自动生成未来分隔点」，关闭后只能手动增删分隔点
  if not coalesce((select auto_boundaries from public.app_config where id = 1), true) then
    return 0;
  end if;
  select coalesce(week_rule, '{"dow":1,"hour":0,"minute":0}'::jsonb),
         coalesce(month_rule, '{"dom":1,"hour":0,"minute":0}'::jsonb)
    into v_week, v_month
    from public.app_config where id = 1;
  if v_week is null then
    v_week := '{"dow":1,"hour":0,"minute":0}'::jsonb;
  end if;
  if v_month is null then
    v_month := '{"dom":1,"hour":0,"minute":0}'::jsonb;
  end if;

  v_start := date_trunc('month', v_local) - make_interval(months => greatest(p_months_back, 0));
  v_end   := v_local + make_interval(months => greatest(p_months_forward, 1));

  -- 月分隔点
  v_dom    := coalesce((v_month->>'dom')::int, 1);
  v_hour   := coalesce((v_month->>'hour')::int, 0);
  v_minute := coalesce((v_month->>'minute')::int, 0);
  v_cursor := v_start;
  while v_cursor <= v_end loop
    v_cand := v_cursor + make_interval(days => v_dom - 1, hours => v_hour, mins => v_minute);
    -- 历史分隔点（1 天以前）直接标记为已结算，避免首次配置时 cron 把过去半年的周期全部补结算一遍
    insert into public.boundaries (type, period_key, boundary_at, label, is_manual, settled)
    values ('month', to_char(v_cand, 'YYYY-MM'), v_cand at time zone 'Asia/Shanghai',
            to_char(v_cand, 'YYYY"年"MM"月"'), false,
            (v_cand at time zone 'Asia/Shanghai') <= now() - interval '1 day')
    on conflict (type, boundary_at) do nothing;
    get diagnostics v_count = row_count;
    v_cursor := v_cursor + interval '1 month';
  end loop;

  -- 周分隔点（按配置星期几逐日扫描）
  v_dow    := coalesce((v_week->>'dow')::int, 1);
  v_hour   := coalesce((v_week->>'hour')::int, 0);
  v_minute := coalesce((v_week->>'minute')::int, 0);
  v_cursor := date_trunc('day', v_start) - interval '8 days';
  while v_cursor <= v_end loop
    if extract(isodow from v_cursor)::int = v_dow then
      v_cand := v_cursor + make_interval(hours => v_hour, mins => v_minute);
      insert into public.boundaries (type, period_key, boundary_at, label, is_manual, settled)
      values ('week', to_char(v_cand, 'IYYY-IW'), v_cand at time zone 'Asia/Shanghai',
              to_char(v_cand, 'YYYY-MM-DD') || ' 周分隔点', false,
              (v_cand at time zone 'Asia/Shanghai') <= now() - interval '1 day')
      on conflict (type, boundary_at) do nothing;
      get diagnostics v_count = row_count;
    end if;
    v_cursor := v_cursor + interval '1 day';
  end loop;

  return v_count;
end;
$$;
revoke all on function public.ensure_boundaries(int, int) from public, anon, authenticated;

create or replace function public.admin_save_separator_rules(
  p_week      jsonb default null,
  p_month     jsonb default null,
  p_maintenance_minutes int default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_week jsonb := coalesce(p_week, (select week_rule from public.app_config where id = 1), '{"dow":1,"hour":0,"minute":0}'::jsonb);
  v_month jsonb := coalesce(p_month, (select month_rule from public.app_config where id = 1), '{"dom":1,"hour":0,"minute":0}'::jsonb);
  v_auto boolean;
begin
  perform public.require_super_admin();
  v_auto := coalesce((select auto_boundaries from public.app_config where id = 1), true);
  if coalesce((v_week->>'dow')::int, 0) not between 1 and 7 then
    raise exception '周分隔点星期必须为 1-7（1=周一）';
  end if;
  if coalesce((v_week->>'hour')::int, -1) not between 0 and 23
     or coalesce((v_week->>'minute')::int, -1) not between 0 and 59 then
    raise exception '周分隔点时间不合法';
  end if;
  if coalesce((v_month->>'dom')::int, 0) not between 1 and 28 then
    raise exception '月分隔点日期必须为 1-28（避免月末不存在）';
  end if;
  if coalesce((v_month->>'hour')::int, -1) not between 0 and 23
     or coalesce((v_month->>'minute')::int, -1) not between 0 and 59 then
    raise exception '月分隔点时间不合法';
  end if;
  if p_maintenance_minutes is not null and p_maintenance_minutes not between 0 and 240 then
    raise exception '维护时长应在 0-240 分钟';
  end if;

  -- 旧的未来自动分隔点作废（已结算/手工点保留）；自动生成关闭时保留现有点，只更新规则
  if v_auto then
    delete from public.boundaries
     where type in ('week','month')
       and boundary_at > now()
       and not is_manual
       and not settled;
  end if;

  update public.app_config
     set week_rule = v_week,
         month_rule = v_month,
         maintenance_minutes = coalesce(p_maintenance_minutes, maintenance_minutes),
         updated_at = now(),
         updated_by = auth.uid()
   where id = 1;

  if v_auto then
    perform public.ensure_boundaries(6, 12);
  end if;
  perform public.write_audit('save_separator_rules', 'app_config', '1',
    jsonb_build_object('week_rule', v_week, 'month_rule', v_month,
                       'maintenance_minutes', p_maintenance_minutes, 'auto_boundaries', v_auto));
  return public.cfg();
end;
$$;
revoke all on function public.admin_save_separator_rules(jsonb, jsonb, int) from public, anon, authenticated;
grant execute on function public.admin_save_separator_rules(jsonb, jsonb, int) to authenticated;

create or replace function public.admin_set_auto_boundaries(p_on boolean)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_on boolean := coalesce(p_on, true);
begin
  perform public.require_super_admin();
  update public.app_config
     set auto_boundaries = v_on, updated_at = now(), updated_by = auth.uid()
   where id = 1;
  if v_on then
    perform public.ensure_boundaries(6, 12);
  end if;
  perform public.write_audit('set_auto_boundaries', 'app_config', '1',
    jsonb_build_object('auto_boundaries', v_on));
  return public.cfg();
end;
$$;
revoke all on function public.admin_set_auto_boundaries(boolean) from public, anon, authenticated;
grant execute on function public.admin_set_auto_boundaries(boolean) to authenticated;

create or replace function public.admin_toggle_maintenance(
  p_on      boolean,
  p_minutes int default null,
  p_until   timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_until timestamptz;
begin
  perform public.require_super_admin();
  if coalesce(p_on, false) then
    if p_until is not null then
      if p_until <= now() then
        raise exception '维护结束时间必须晚于当前时间';
      end if;
      if p_until > now() + interval '7 days' then
        raise exception '维护结束时间不能超过 7 天';
      end if;
      v_until := p_until;
    else
      v_until := now() + make_interval(mins => coalesce(p_minutes,
        (select maintenance_minutes from public.app_config where id = 1), 30));
    end if;
  else
    v_until := null;
  end if;
  update public.app_config set maintenance_until = v_until, updated_at = now(), updated_by = auth.uid()
   where id = 1;
  perform public.notify_audience('all',
    case when v_until is null then '系统已恢复' else '系统维护中' end,
    case when v_until is null then '维护已结束，所有功能恢复可用。'
         else format('系统正在结算维护，预计到 %s 恢复，期间只读。',
                     to_char(v_until at time zone 'Asia/Shanghai', 'MM-DD HH24:MI')) end,
    'system');
  perform public.write_audit('toggle_maintenance', 'app_config', '1',
    jsonb_build_object('on', coalesce(p_on,false), 'until', v_until));
  return jsonb_build_object('maintenance', v_until is not null and v_until > now(), 'until', v_until);
end;
$$;
revoke all on function public.admin_toggle_maintenance(boolean, int, timestamptz) from public, anon, authenticated;
grant execute on function public.admin_toggle_maintenance(boolean, int, timestamptz) to authenticated;

-- ---------- 5. 分隔点批量删除（允许已结算，级联清理快照） ----------
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


-- ---------- 6. 自检 ----------
select 'V2.0.6 补丁已应用' as 结果,
       (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'records'
           and column_name in ('recorder_name', 'modified_by_name')) as 记录人姓名列_应为2,
       (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'app_config'
           and column_name = 'auto_boundaries') as 自动分隔配置列_应为1,
       (select count(*) from information_schema.routines
         where routine_schema = 'public' and routine_name = 'admin_set_auto_boundaries') as 开关函数_应为1,
       (select pg_get_function_identity_arguments(p.oid) from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'admin_toggle_maintenance' limit 1) as 维护函数参数,
       (select count(*) from public.records where recorder_name is null) as 记录人姓名仍为空的行数;
