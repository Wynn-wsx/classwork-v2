-- ============================================================
-- 5.6 备份导出 / 恢复 / 清空 / 物理删除 / 审计与结算查询 RPC
--     约定：全部 security definer + search_path = public, extensions；
--           权限判断只用 public.caller_role() / public.require_role()；
--           危险操作在函数内以单个事务执行（失败整体回滚）。
-- ============================================================

-- ------------------------------------------------------------
-- 5.6.1 C1 全量备份导出（仅 super_admin）
--   profiles 只导出非敏感字段（绝不导出任何密码/密钥字段）。
--   结构：{version, exported_at, tables:{表名:[行...]}}
-- ------------------------------------------------------------
create or replace function public.admin_export_all()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_result jsonb;
begin
  perform public.require_role(array['super_admin'], '没有权限执行此操作');

  v_result := jsonb_build_object(
    'version', '2.0.0',
    'exported_at', now(),
    'tables', jsonb_build_object(
      'profiles', coalesce((
        select jsonb_agg(to_jsonb(p))
          from (
            select id, username, name, role, group_name, status, student_id,
                   must_change_password, created_at
              from public.profiles
             order by created_at, id
          ) p
      ), '[]'::jsonb),

      'students', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.students order by created_at, id) x
      ), '[]'::jsonb),

      'records', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.records order by created_at, id) x
      ), '[]'::jsonb),

      'rules', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.rules order by sort_order, id) x
      ), '[]'::jsonb),

      'app_config', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.app_config order by id) x
      ), '[]'::jsonb),

      'boundaries', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.boundaries order by boundary_at, id) x
      ), '[]'::jsonb),

      'weekly_summaries', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.weekly_summaries order by created_at, id) x
      ), '[]'::jsonb),

      'settlements', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.settlements order by created_at, id) x
      ), '[]'::jsonb),

      'lottery_items', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.lottery_items order by sort_order, id) x
      ), '[]'::jsonb),

      'lottery_draws', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.lottery_draws order by drawn_at, id) x
      ), '[]'::jsonb),

      'lottery_chances', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.lottery_chances order by created_at, id) x
      ), '[]'::jsonb),

      'lottery_group_chances', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.lottery_group_chances order by created_at, id) x
      ), '[]'::jsonb),

      'starlight_accounts', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.starlight_accounts order by updated_at, student_id) x
      ), '[]'::jsonb),

      'starlight_logs', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.starlight_logs order by created_at, id) x
      ), '[]'::jsonb),

      'starlight_term_snapshots', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.starlight_term_snapshots order by created_at, id) x
      ), '[]'::jsonb),

      'supervisor_assignments', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.supervisor_assignments order by created_at, id) x
      ), '[]'::jsonb),

      'audit_logs', coalesce((
        select jsonb_agg(to_jsonb(x))
          from (select * from public.audit_logs order by id) x
      ), '[]'::jsonb)
    )
  );

  perform public.write_audit(
    '导出全量备份',
    'backup',
    '',
    jsonb_build_object(
      'version', '2.0.0',
      'profiles',  jsonb_array_length(v_result->'tables'->'profiles'),
      'students',  jsonb_array_length(v_result->'tables'->'students'),
      'records',   jsonb_array_length(v_result->'tables'->'records'),
      'audit_logs', jsonb_array_length(v_result->'tables'->'audit_logs')
    )
  );
  return v_result;
end;
$$;
revoke all on function public.admin_export_all() from public, anon, authenticated;
grant execute on function public.admin_export_all() to authenticated;

-- ------------------------------------------------------------
-- 5.6.2 C2 备份恢复（仅 super_admin）
--   1) 校验 p_confirm = 'RESTORE'；
--   2) 按外键反序清空业务表（audit_logs 保留追加、不清空、不回灌）；
--   3) 按外键正序回灌数据；
--   4) profiles 无法整体替换（绑定 auth.users）：只更新已存在账号的
--      role/group_name/status/student_id，不存在的跳过并统计；
--   5) app_config 单行保留 id = 1。
--   整个函数即一个事务，任一步失败全部回滚。
-- ------------------------------------------------------------
create or replace function public.admin_restore_backup(p_data jsonb, p_confirm text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_tables         jsonb;
  v_restored       jsonb := '{}'::jsonb;
  v_n              int := 0;
  v_missing        text;
  v_prof_total     int := 0;
  v_prof_updated   int := 0;
  v_prof_skipped   int := 0;
begin
  perform public.require_role(array['super_admin'], '没有权限执行此操作');
  if p_confirm is distinct from 'RESTORE' then
    raise exception '请输入 RESTORE 以确认覆盖恢复';
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    raise exception '备份数据格式不正确';
  end if;
  v_tables := p_data->'tables';
  if v_tables is null or jsonb_typeof(v_tables) <> 'object' then
    raise exception '备份数据缺少 tables 字段';
  end if;

  -- 必须是一份完整的 V2.0 备份，避免个别表缺失导致清空后无法回灌
  select string_agg(t.name, '、')
    into v_missing
    from unnest(array[
      'profiles','students','records','rules','app_config','boundaries',
      'weekly_summaries','settlements','lottery_items','lottery_draws',
      'lottery_chances','starlight_accounts','starlight_logs',
      'starlight_term_snapshots','lottery_group_chances','supervisor_assignments','audit_logs'
    ]) as t(name)
   where not (v_tables ? t.name);
  if v_missing is not null then
    raise exception '备份数据不完整，缺少数据表：%', v_missing;
  end if;
  if exists (
    select 1 from jsonb_each(v_tables) e
     where jsonb_typeof(e.value) <> 'array'
  ) then
    raise exception '备份数据格式不正确：tables 下各表必须是数组';
  end if;

  -- ---------- 删除（外键反序；audit_logs 保留追加） ----------
  delete from public.lottery_group_chances where true;
  delete from public.lottery_chances where true;
  delete from public.lottery_draws where true;
  delete from public.starlight_logs where true;
  delete from public.starlight_accounts where true;
  delete from public.starlight_term_snapshots where true;
  delete from public.supervisor_assignments where true;
  delete from public.weekly_summaries where true;
  delete from public.settlements where true;
  delete from public.boundaries where true;
  delete from public.lottery_items where true;
  delete from public.records where true;
  delete from public.students where true;
  delete from public.rules where true;

  -- ---------- 回灌（外键正序） ----------
  insert into public.rules
  select * from jsonb_populate_recordset(null::public.rules, v_tables->'rules');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('rules', v_n);

  insert into public.students
  select * from jsonb_populate_recordset(null::public.students, v_tables->'students');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('students', v_n);

  insert into public.records
  select * from jsonb_populate_recordset(null::public.records, v_tables->'records');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('records', v_n);

  insert into public.lottery_items
  select * from jsonb_populate_recordset(null::public.lottery_items, v_tables->'lottery_items');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('lottery_items', v_n);

  insert into public.boundaries
  select * from jsonb_populate_recordset(null::public.boundaries, v_tables->'boundaries');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('boundaries', v_n);

  insert into public.settlements
  select * from jsonb_populate_recordset(null::public.settlements, v_tables->'settlements');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('settlements', v_n);

  insert into public.weekly_summaries
  select * from jsonb_populate_recordset(null::public.weekly_summaries, v_tables->'weekly_summaries');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('weekly_summaries', v_n);

  insert into public.supervisor_assignments
  select * from jsonb_populate_recordset(null::public.supervisor_assignments, v_tables->'supervisor_assignments');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('supervisor_assignments', v_n);

  insert into public.starlight_accounts
  select * from jsonb_populate_recordset(null::public.starlight_accounts, v_tables->'starlight_accounts');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('starlight_accounts', v_n);

  insert into public.starlight_term_snapshots
  select * from jsonb_populate_recordset(null::public.starlight_term_snapshots, v_tables->'starlight_term_snapshots');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('starlight_term_snapshots', v_n);

  insert into public.lottery_group_chances
  select * from jsonb_populate_recordset(null::public.lottery_group_chances, v_tables->'lottery_group_chances');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('lottery_group_chances', v_n);

  insert into public.lottery_draws
  select * from jsonb_populate_recordset(null::public.lottery_draws, v_tables->'lottery_draws');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('lottery_draws', v_n);

  insert into public.starlight_logs
  select * from jsonb_populate_recordset(null::public.starlight_logs, v_tables->'starlight_logs');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('starlight_logs', v_n);

  insert into public.lottery_chances
  select * from jsonb_populate_recordset(null::public.lottery_chances, v_tables->'lottery_chances');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('lottery_chances', v_n);

  -- ---------- app_config 单行（保留 id = 1） ----------
  if jsonb_array_length(v_tables->'app_config') > 0 then
    delete from public.app_config where id = 1;
    insert into public.app_config
    select * from jsonb_populate_recordset(null::public.app_config, v_tables->'app_config');
    get diagnostics v_n = row_count;
    v_restored := v_restored || jsonb_build_object('app_config', v_n);
  else
    v_restored := v_restored || jsonb_build_object('app_config', 0);
  end if;

  -- ---------- profiles：只更新已存在账号，不新建、不删号 ----------
  v_prof_total := jsonb_array_length(v_tables->'profiles');
  update public.profiles p
     set role       = coalesce(s.role, p.role),
         group_name = s.group_name,
         status     = coalesce(s.status, p.status),
         student_id = s.student_id,
         updated_at = now()
    from jsonb_populate_recordset(null::public.profiles, v_tables->'profiles') s
   where p.id = s.id;
  get diagnostics v_prof_updated = row_count;
  v_prof_skipped := greatest(v_prof_total - v_prof_updated, 0);

  perform public.write_audit(
    '恢复备份',
    'backup',
    '',
    jsonb_build_object(
      'source_version', coalesce(p_data->>'version', ''),
      'restored', v_restored,
      'profiles_updated', v_prof_updated,
      'profiles_skipped', v_prof_skipped,
      'note', 'audit_logs 保留追加，不参与覆盖恢复'
    )
  );
  return jsonb_build_object(
    'version', coalesce(p_data->>'version', ''),
    'restored', v_restored,
    'profiles_updated', v_prof_updated,
    'profiles_skipped', v_prof_skipped,
    'note', 'audit_logs 保留追加；profiles 仅更新已存在账号（绑定 auth.users），不新建/删除账号；通知信箱未参与备份恢复'
  );
end;
$$;
revoke all on function public.admin_restore_backup(jsonb, text) from public, anon, authenticated;
grant execute on function public.admin_restore_backup(jsonb, text) to authenticated;

-- ------------------------------------------------------------
-- 5.6.3 C3 一键清空业务数据（仅 super_admin）
--   p_scope = 'records'：只清 records（含软删除记录）；
--   p_scope = 'all'    ：按外键反序清空全部业务表 + notifications，
--                        但【保留】profiles / auth.users / rules / app_config /
--                        lottery_items（登录账号、规则、系统配置、奖/惩池不动）。
--                        注意：students 清空后，profiles.student_id 会因外键
--                        on delete set null 自动解绑。
-- ------------------------------------------------------------
create or replace function public.admin_clear_data(p_scope text, p_confirm text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_scope   text;
  v_deleted jsonb := '{}'::jsonb;
  v_n       int := 0;
begin
  perform public.require_role(array['super_admin'], '没有权限执行此操作');
  if p_confirm is distinct from 'CLEAR' then
    raise exception '请输入 CLEAR 以确认清空数据';
  end if;
  v_scope := lower(btrim(coalesce(p_scope, '')));
  if v_scope not in ('records','all') then
    raise exception '清空范围只能是 records 或 all';
  end if;

  if v_scope = 'records' then
    delete from public.records where true;
    get diagnostics v_n = row_count;
    v_deleted := v_deleted || jsonb_build_object('records', v_n);
    perform public.write_audit(
      '清空积分记录',
      'data',
      'records',
      jsonb_build_object('deleted', v_deleted)
    );
    return jsonb_build_object(
      'scope', 'records',
      'deleted', v_deleted,
      'note', '仅清空 records（含软删除记录），其余数据保留'
    );
  end if;

  -- ---------- all：外键反序清空；rules / lottery_items / app_config 保留 ----------
  delete from public.lottery_chances where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('lottery_chances', v_n);

  delete from public.lottery_group_chances where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('lottery_group_chances', v_n);

  delete from public.lottery_draws where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('lottery_draws', v_n);

  delete from public.lottery_group_chances where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('lottery_group_chances', v_n);

  delete from public.starlight_logs where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('starlight_logs', v_n);

  delete from public.starlight_accounts where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('starlight_accounts', v_n);

  delete from public.starlight_term_snapshots where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('starlight_term_snapshots', v_n);

  delete from public.supervisor_assignments where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('supervisor_assignments', v_n);

  delete from public.weekly_summaries where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('weekly_summaries', v_n);

  delete from public.settlements where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('settlements', v_n);

  delete from public.boundaries where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('boundaries', v_n);

  delete from public.records where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('records', v_n);

  delete from public.students where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('students', v_n);

  delete from public.notifications where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('notifications', v_n);

  perform public.write_audit(
    '清空全部业务数据',
    'data',
    'all',
    jsonb_build_object('deleted', v_deleted)
  );
  return jsonb_build_object(
    'scope', 'all',
    'deleted', v_deleted,
    'note', '已清空业务数据；保留 profiles/auth.users/rules/app_config/lottery_items；students 清空后账号与学生档案的绑定关系解除；分隔点已清空，需重新生成'
  );
end;
$$;
revoke all on function public.admin_clear_data(text, text) from public, anon, authenticated;
grant execute on function public.admin_clear_data(text, text) to authenticated;

-- ------------------------------------------------------------
-- 5.6.4 C5 物理删除软删除记录（仅 super_admin）
-- ------------------------------------------------------------
create or replace function public.admin_purge_record(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_status text;
begin
  perform public.require_role(array['super_admin'], '没有权限执行此操作');
  if p_id is null then
    raise exception '记录编号不能为空';
  end if;
  select status into v_status from public.records where id = p_id;
  if v_status is null then
    raise exception '记录不存在';
  end if;
  if v_status <> '已删除' then
    raise exception '只能物理删除已软删除的记录（当前状态：%）', v_status;
  end if;
  delete from public.records where id = p_id;
  perform public.write_audit(
    '物理删除记录',
    'record',
    p_id::text,
    jsonb_build_object('status', v_status)
  );
end;
$$;
revoke all on function public.admin_purge_record(uuid) from public, anon, authenticated;
grant execute on function public.admin_purge_record(uuid) to authenticated;

-- 批量物理删除全部软删除记录，返回删除条数
create or replace function public.admin_purge_records()
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_n int := 0;
begin
  perform public.require_role(array['super_admin'], '没有权限执行此操作');
  delete from public.records where status = '已删除';
  get diagnostics v_n = row_count;
  perform public.write_audit(
    '批量物理删除记录',
    'record',
    '',
    jsonb_build_object('count', v_n)
  );
  return v_n;
end;
$$;
revoke all on function public.admin_purge_records() from public, anon, authenticated;
grant execute on function public.admin_purge_records() to authenticated;

-- ------------------------------------------------------------
-- 5.6.5 E1/E2 操作审计日志查询
-- ------------------------------------------------------------
create or replace function public.list_audit_logs(
  p_action text default null,
  p_actor  uuid default null,
  p_limit  int  default 200
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_action text;
  v_limit  int;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  v_action := nullif(btrim(coalesce(p_action, '')), '');
  v_limit  := greatest(1, least(coalesce(p_limit, 200), 1000));
  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'id',          a.id,
               'actor_name',  a.actor_name,
               'action',      a.action,
               'target_type', a.target_type,
               'target_id',   a.target_id,
               'detail',      a.detail,
               'created_at',  a.created_at
             )
             order by a.created_at desc, a.id desc
           )
      from (
        select *
          from public.audit_logs
         where (v_action is null or action = v_action)
           and (p_actor is null or actor_id = p_actor)
         order by created_at desc, id desc
         limit v_limit
      ) a
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.list_audit_logs(text, uuid, int) from public, anon, authenticated;
grant execute on function public.list_audit_logs(text, uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 5.6.6 E3 月度结算记录查询（super_admin/admin/executive）
-- ------------------------------------------------------------
create or replace function public.list_settlements(p_limit int default 20)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_limit int;
begin
  perform public.require_role(array['super_admin','admin','executive'], '没有权限执行此操作');
  v_limit := greatest(1, least(coalesce(p_limit, 20), 200));
  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'id',              s.id,
               'period_key',      s.period_key,
               'status',          s.status,
               'started_at',      s.started_at,
               'finished_at',     s.finished_at,
               'auto_draw_count', s.auto_draw_count,
               'second_class',    s.second_class,
               'summary',         s.summary,
               'note',            s.note,
               'created_at',      s.created_at
             )
             order by s.created_at desc
           )
      from (
        select *
          from public.settlements
         order by created_at desc
         limit v_limit
      ) s
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.list_settlements(int) from public, anon, authenticated;
grant execute on function public.list_settlements(int) to authenticated;
