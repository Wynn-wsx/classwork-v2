-- ============================================================
-- 4. 行级安全策略（RLS）——只给“读”策略，一切写操作走 RPC
--    权限真相以 public.caller_role() 为准（读 profiles 实时判角色/状态）
-- ============================================================

-- ------------------------------------------------------------
-- 4.1 现有表：重做策略（V1.6 的写策略全部移除）
-- ------------------------------------------------------------
alter table public.profiles enable row level security;
drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
drop policy if exists profiles_delete on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated using (
    id = auth.uid() or public.is_admin()
  );

-- ------------------------------------------------------------
alter table public.students enable row level security;
drop policy if exists students_select on public.students;
drop policy if exists students_insert on public.students;
drop policy if exists students_update on public.students;
drop policy if exists students_delete on public.students;
create policy students_select on public.students
  for select to authenticated using (
    public.is_teacher()
    or (public.caller_role() = 'group_recorder' and group_name = public.my_group_name())
    -- 当周监督委员需要看全班学生（抽查与受理申诉）
    or public.is_supervisor_now()
    or id = public.my_student_id()
  );

-- ------------------------------------------------------------
alter table public.records enable row level security;
drop policy if exists records_select on public.records;
drop policy if exists records_insert on public.records;
drop policy if exists records_update on public.records;
drop policy if exists records_delete on public.records;
create policy records_select on public.records
  for select to authenticated using (
    public.is_teacher()
    or (public.caller_role() = 'group_recorder' and public.student_in_my_group(student_id))
    or public.is_supervisor_now()
    -- 学生可查看全班积分变更记录（只读，写入仍需 RPC）：既能看到自己的，也能看到同学的
    or (public.caller_role() = 'student' and coalesce(status, '') <> '已删除')
  );

-- ------------------------------------------------------------
alter table public.rules enable row level security;
drop policy if exists rules_select on public.rules;
drop policy if exists rules_insert on public.rules;
drop policy if exists rules_update on public.rules;
drop policy if exists rules_delete on public.rules;
create policy rules_select on public.rules
  for select to authenticated using (public.is_active_user());

-- ------------------------------------------------------------
-- 4.2 新表：读策略
-- ------------------------------------------------------------
-- 系统配置：全员不可直读（含邀请码/初始密码），只能走 RPC
alter table public.app_config enable row level security;

-- 分隔点实例：登录学生可读（周/月入口展示）
alter table public.boundaries enable row level security;
drop policy if exists boundaries_select on public.boundaries;
create policy boundaries_select on public.boundaries
  for select to authenticated using (public.is_active_user());

-- 周汇总 / 月结算：含全班成绩，学生不直读（个人汇总走 RPC）
alter table public.weekly_summaries enable row level security;
drop policy if exists weekly_summaries_select on public.weekly_summaries;
create policy weekly_summaries_select on public.weekly_summaries
  for select to authenticated using (
    public.is_teacher() or public.caller_role() = 'group_recorder' or public.is_admin()
  );

alter table public.settlements enable row level security;
drop policy if exists settlements_select on public.settlements;
create policy settlements_select on public.settlements
  for select to authenticated using (
    public.is_teacher() or public.caller_role() = 'group_recorder' or public.is_admin()
  );

-- 奖/惩池：登录即可见（规则页公示 8 卡与 20 条）
alter table public.lottery_items enable row level security;
drop policy if exists lottery_items_select on public.lottery_items;
create policy lottery_items_select on public.lottery_items
  for select to authenticated using (public.is_active_user());

-- 抽选次数：本人 / 本组记录员 / 老师
alter table public.lottery_chances enable row level security;
drop policy if exists lottery_chances_select on public.lottery_chances;
create policy lottery_chances_select on public.lottery_chances
  for select to authenticated using (
    public.is_teacher()
    or (public.caller_role() = 'group_recorder' and public.student_in_my_group(student_id))
    or student_id = public.my_student_id()
  );

-- 抽选结果仓库：本人 / 小组级组内成员 / 本组记录员 / 老师
alter table public.lottery_draws enable row level security;
drop policy if exists lottery_draws_select on public.lottery_draws;
create policy lottery_draws_select on public.lottery_draws
  for select to authenticated using (
    public.is_teacher()
    or (public.caller_role() = 'group_recorder' and public.student_in_my_group(student_id))
    or student_id = public.my_student_id()
    or (is_group and public.my_student_id() is not null and member_ids ? (public.my_student_id())::text)
  );

-- 星光账户/流水：按公示配置（public 默认全班可查；self_only 仅本人+老师），记录员本组
alter table public.starlight_accounts enable row level security;
drop policy if exists starlight_accounts_select on public.starlight_accounts;
create policy starlight_accounts_select on public.starlight_accounts
  for select to authenticated using (
    public.is_teacher()
    or (public.caller_role() = 'group_recorder' and public.student_in_my_group(student_id))
    or public.is_supervisor_now()
    or student_id = public.my_student_id()
    or ((public.cfg() ->> 'starlight_visibility') = 'public' and public.is_active_user())
  );

alter table public.starlight_logs enable row level security;
drop policy if exists starlight_logs_select on public.starlight_logs;
create policy starlight_logs_select on public.starlight_logs
  for select to authenticated using (
    public.is_teacher()
    or (public.caller_role() = 'group_recorder' and public.student_in_my_group(student_id))
    or public.is_supervisor_now()
    or student_id = public.my_student_id()
    or ((public.cfg() ->> 'starlight_visibility') = 'public' and public.is_active_user())
  );

alter table public.starlight_term_snapshots enable row level security;
drop policy if exists starlight_term_snapshots_select on public.starlight_term_snapshots;
create policy starlight_term_snapshots_select on public.starlight_term_snapshots
  for select to authenticated using (public.is_active_user());

-- 通知：只能读自己的
alter table public.notifications enable row level security;
drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications
  for select to authenticated using (recipient_id = auth.uid());

-- 小组集体抽选次数：老师可见全部；学生/记录员可见本组
alter table public.lottery_group_chances enable row level security;
drop policy if exists lottery_group_chances_select on public.lottery_group_chances;
create policy lottery_group_chances_select on public.lottery_group_chances
  for select to authenticated using (
    public.is_teacher() or (public.is_active_user() and group_name = public.my_group_name())
  );

-- 监督委员名单：登录可见（公示）
alter table public.supervisor_assignments enable row level security;
drop policy if exists supervisor_assignments_select on public.supervisor_assignments;
create policy supervisor_assignments_select on public.supervisor_assignments
  for select to authenticated using (public.is_active_user());

-- 审计日志：仅管理员/班主任（E1/E2）
alter table public.audit_logs enable row level security;
drop policy if exists audit_logs_select on public.audit_logs;
create policy audit_logs_select on public.audit_logs
  for select to authenticated using (public.is_admin());
