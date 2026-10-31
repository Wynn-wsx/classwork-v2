-- ============================================================
--  班级积分管理系统 · 应急回退脚本（V2.0 -> V1.6 读权限/写权限）
--  生成方式：由 _build/build_sql.py 生成（静态模板），请勿手改本文件
--  生成时间：2026-10-31 23:33:25
--
--  【适用场景】V2.0 上线后前端需要临时回退到 V1.6 的 index.html。
--  【本脚本做三件事】
--    1) 恢复 V1.6 的 auth_role() / auth_group()（从 JWT app_metadata 读取角色）
--    2) 恢复 V1.6 的 RLS 策略（profiles 全表可读；students/records/rules 前端直写）
--    3) 恢复 authenticated 对 students/records/rules 的 insert/update/delete 权限
--  【不做的事】不删除 V2.0 的表、函数与数据（保留，随时可再切回 V2.0）；
--              不修改任何业务数据。回退后 V2.0 专属页面不可用，但原有积分功能正常。
--  执行方式：Supabase 控制台 → SQL Editor → 粘贴全文 → Run。可重复执行。
-- ============================================================

-- ---------- 1. 恢复 V1.6 角色函数 ----------
create or replace function public.auth_role()
returns text language sql stable security definer set search_path = public, extensions as $$
  select coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'role', ''), 'none')
$$;

create or replace function public.auth_group()
returns text language sql stable security definer set search_path = public, extensions as $$
  select coalesce(nullif(auth.jwt() -> 'app_metadata' ->> 'group_name', ''), '')
$$;

-- ---------- 2. profiles：V1.6 全表可读 ----------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated using (true);

-- ---------- 3. students：V1.6 读 + 前端直写 ----------
drop policy if exists students_select on public.students;
create policy students_select on public.students
  for select to authenticated using (
    public.auth_role() in ('admin','executive')
    or (public.auth_role() = 'group_recorder' and group_name = public.auth_group())
  );

drop policy if exists students_insert on public.students;
create policy students_insert on public.students
  for insert to authenticated with check (public.auth_role() in ('admin','executive'));

drop policy if exists students_update on public.students;
create policy students_update on public.students
  for update to authenticated using (public.auth_role() in ('admin','executive'));

drop policy if exists students_delete on public.students;
create policy students_delete on public.students
  for delete to authenticated using (public.auth_role() in ('admin','executive'));

-- ---------- 4. records：V1.6 读 + 前端直写 ----------
drop policy if exists records_select on public.records;
create policy records_select on public.records
  for select to authenticated using (
    public.auth_role() in ('admin','executive')
    or (
      public.auth_role() = 'group_recorder'
      and student_id in (select id from public.students where group_name = public.auth_group())
    )
  );

drop policy if exists records_insert on public.records;
create policy records_insert on public.records
  for insert to authenticated with check (
    public.auth_role() in ('admin','executive')
    or (
      public.auth_role() = 'group_recorder'
      and student_id in (select id from public.students where group_name = public.auth_group())
    )
  );

drop policy if exists records_update on public.records;
create policy records_update on public.records
  for update to authenticated using (
    public.auth_role() in ('admin','executive')
    or (
      public.auth_role() = 'group_recorder'
      and student_id in (select id from public.students where group_name = public.auth_group())
    )
  );

drop policy if exists records_delete on public.records;
create policy records_delete on public.records
  for delete to authenticated using (
    public.auth_role() in ('admin','executive')
    or (
      public.auth_role() = 'group_recorder'
      and student_id in (select id from public.students where group_name = public.auth_group())
    )
  );

-- ---------- 5. rules：V1.6 读 + 前端直写 ----------
drop policy if exists rules_select on public.rules;
create policy rules_select on public.rules
  for select to authenticated using (true);

drop policy if exists rules_insert on public.rules;
create policy rules_insert on public.rules
  for insert to authenticated with check (public.auth_role() in ('admin','executive'));

drop policy if exists rules_update on public.rules;
create policy rules_update on public.rules
  for update to authenticated using (public.auth_role() in ('admin','executive'));

drop policy if exists rules_delete on public.rules;
create policy rules_delete on public.rules
  for delete to authenticated using (public.auth_role() in ('admin','executive'));

-- ---------- 6. 恢复前端直写权限 ----------
grant insert, update, delete on table public.students to authenticated;
grant insert, update, delete on table public.records  to authenticated;
grant insert, update, delete on table public.rules    to authenticated;

-- ---------- 7. 提示 ----------
do $$
begin
  raise notice 'V1.6 回退完成：profiles 全表可读、students/records/rules 恢复前端直写。';
  raise notice 'V2.0 的表、函数、数据均保留未动；如需重新启用 V2.0，请重新执行 schema.sql（幂等）。';
end $$;
