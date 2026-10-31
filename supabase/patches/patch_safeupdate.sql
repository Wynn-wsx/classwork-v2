-- V2.0 补丁：pg_safeupdate 兼容（Supabase 项目开启 safeupdate 时，裸 DELETE 会报 21000）
-- 用法：在 Supabase 控制台 → SQL Editor 中整段执行一次即可；幂等，可重复执行。
-- 影响函数：admin_restore_backup / admin_purge_records / admin_clear_data
-- 说明：只是把不带 WHERE 的 DELETE 改成 DELETE ... WHERE true，行为完全一致。

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
      'starlight_term_snapshots','appeals','supervisor_assignments','audit_logs'
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
  delete from public.lottery_chances where true;
  delete from public.lottery_draws where true;
  delete from public.appeals where true;
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

  insert into public.appeals
  select * from jsonb_populate_recordset(null::public.appeals, v_tables->'appeals');
  get diagnostics v_n = row_count;
  v_restored := v_restored || jsonb_build_object('appeals', v_n);

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

  delete from public.lottery_draws where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('lottery_draws', v_n);

  delete from public.appeals where true;
  get diagnostics v_n = row_count;
  v_deleted := v_deleted || jsonb_build_object('appeals', v_n);

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

revoke all on function public.admin_restore_backup(jsonb, text) from public, anon, authenticated;

grant execute on function public.admin_restore_backup(jsonb, text) to authenticated;

revoke all on function public.admin_purge_records() from public, anon, authenticated;

grant execute on function public.admin_purge_records() to authenticated;

revoke all on function public.admin_clear_data(text, text) from public, anon, authenticated;

grant execute on function public.admin_clear_data(text, text) to authenticated;
