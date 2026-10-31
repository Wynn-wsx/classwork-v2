-- ============================================================
--  班级积分管理系统 V2.0 · 数据库脚本（全量 / 幂等）
--  目标项目：Supabase（Postgres 15+）
--  生成方式：由 _build/build_sql.py 从 _build/sql/ 模块拼接，请勿手改本文件
--  执行方式：Supabase 控制台 → SQL Editor → 粘贴全文 → Run
--  可重复执行：所有建表/加字段/函数/策略/种子均已幂等处理
--  执行前务必：控制台 Database → Backups 或自建 JSON 备份
-- ============================================================

-- 兼容设置：脚本内少数函数会引用“稍后才定义”的函数（如 is_maintenance -> cfg、
-- is_supervisor_now -> current_week_key）。关闭“创建函数时校验函数体”，
-- 函数首次被调用时仍会完整校验，不影响运行期正确性。
set check_function_bodies = off;
--  生成时间：2026-11-01 03:06:27

--  【脚本目录】（在 SQL Editor 里搜索下面的标题文字可快速定位）
--   1. 扩展（pgcrypto）
--   2. 数据表：2.1 基础表 / 2.2 现有表字段变更 / 2.3 新增 14 张表
--   3. 辅助函数：身份/权限、时间与分隔点、系统配置、查询辅助、审计与通知
--   4. 行级安全策略（RLS：只给读，写全部走 RPC）
--   5. 积分记录 RPC：登记 / 修改 / 删除 / 冻结月纠错 / 规则上限 / 规则 CRUD / 学生档案 / 排行榜
--   6. 应用状态与时间规则 RPC：首屏状态、周期状态、分隔点管理、系统配置、维护模式
--   7. 奖惩抽选 RPC：抽选、次数、仓库、作废、奖池管理、卡片过期
--   8. 周/月周期作业：周快照、月结算、轮询作业、重算、汇总查询
--   9. 账号 RPC：建号/改密/停用/改角色/批量建号/邀请码注册/审核/登录日志
--  10. 通知 / 申诉 / 监督委员 / 星光台账 RPC
--  11. 备份导出 / 恢复 / 清空 / 物理删除 / 审计与结算查询 RPC
--  12. 初始数据：系统配置、分隔点、37 条积分规则、8 张奖励卡、20 条惩罚、默认账号
--  13. 最终权限收口（revoke/grant）
--  14. 迁移后自检（结构断言 + 数量统计）

-- ============================================================
-- 1. 扩展
-- ============================================================
create extension if not exists pgcrypto with schema extensions;

-- ============================================================
-- 2. 数据表（V1.6 基础表 + V2.0 字段变更 + 14 张新表）
--    全部幂等：create table if not exists / add column if not exists
-- ============================================================

-- ------------------------------------------------------------
-- 2.1 基础表（V1.6 已存在；空库初始化时补齐）
-- ------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  username   text unique not null,
  name       text not null,
  role       text not null check (role in ('admin','executive','group_recorder')),
  group_name text,
  created_at timestamptz not null default now()
);

create table if not exists public.students (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  group_name text not null,
  student_no text,
  created_at timestamptz not null default now()
);

create table if not exists public.records (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null,
  score_type  text not null default '加分',
  category    text not null default '',
  reason      text not null default '',
  points      numeric(10,2) not null default 0,
  recorder_id uuid,
  record_date text not null default '',
  status      text not null default '正常',
  evidence    text,
  modified_by uuid,
  modified_at timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists records_student_idx on public.records(student_id);
-- V2.0.6：记录人/修改人姓名冗余保存（前端无需再跨表匹配，历史数据在升级时回填）
alter table public.records add column if not exists recorder_name text;
alter table public.records add column if not exists modified_by_name text;

create table if not exists public.rules (
  id         uuid primary key default gen_random_uuid(),
  score_type text not null default '加分',
  category   text not null,
  reason     text not null,
  points     numeric(10,2) not null default 0,
  remark     text not null default '',
  sort_order int not null default 0
);

-- ------------------------------------------------------------
-- 2.2 现有表 V2.0 字段变更
-- ------------------------------------------------------------
-- profiles：绑定学生、账号状态、首登强制改密、角色扩到五级
alter table public.profiles add column if not exists student_id uuid references public.students(id) on delete set null;
alter table public.profiles add column if not exists status text not null default 'active';
alter table public.profiles add column if not exists must_change_password boolean not null default false;
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('super_admin','admin','executive','group_recorder','student'));
alter table public.profiles drop constraint if exists profiles_status_check;
alter table public.profiles add constraint profiles_status_check
  check (status in ('active','pending','disabled'));

create unique index if not exists profiles_student_id_uidx
  on public.profiles(student_id) where student_id is not null;
create index if not exists profiles_role_idx on public.profiles(role);

-- students：绑定登录账号
alter table public.students add column if not exists user_id uuid references auth.users(id) on delete set null;
create unique index if not exists students_user_id_uidx
  on public.students(user_id) where user_id is not null;
create index if not exists students_group_idx on public.students(group_name);

-- rules：周期上限
alter table public.rules add column if not exists limit_type text not null default 'none';
alter table public.rules add column if not exists limit_value numeric(10,2);
alter table public.rules drop constraint if exists rules_limit_type_check;
alter table public.rules add constraint rules_limit_type_check
  check (limit_type in ('none','count','points'));

-- records：来源规则、2 秒冻结、登记月 key
alter table public.records add column if not exists rule_id uuid references public.rules(id) on delete set null;
alter table public.records add column if not exists frozen_until timestamptz;
alter table public.records add column if not exists period_key text not null default '';
create index if not exists records_rule_idx on public.records(rule_id);
create index if not exists records_period_idx on public.records(period_key);
create index if not exists records_created_idx on public.records(created_at desc);
-- 业务日期用 text('YYYY-MM-DD')，字典序即时间序，避免非法历史值 cast 报错
create index if not exists records_date_idx on public.records(record_date) where record_date <> '';

-- 旧数据回填（幂等）
update public.records
   set record_date = to_char(created_at at time zone 'Asia/Shanghai', 'YYYY-MM-DD')
 where coalesce(record_date, '') = '';
update public.records
   set period_key = left(record_date, 7)
 where coalesce(period_key, '') = '' and record_date ~ '^\d{4}-\d{2}-\d{2}';
update public.profiles
   set status = 'active'
 where status is null;

-- ------------------------------------------------------------
-- 2.3 新表（14 张）
-- ------------------------------------------------------------

-- 系统配置（单行，id 恒为 1；读写一律走 RPC，前端无直接权限）
create table if not exists public.app_config (
  id                      int primary key default 1 check (id = 1),
  week_rule               jsonb not null default '{"dow":1,"hour":0,"minute":0}'::jsonb,
  month_rule              jsonb not null default '{"dom":1,"hour":0,"minute":0}'::jsonb,
  auto_boundaries         boolean not null default true,
  summary_visibility      jsonb not null default '{"self_month":true,"own_group_week":true,"all_month":false,"all_group_week":false}'::jsonb,
  maintenance_minutes     int not null default 30,
  maintenance_until       timestamptz,
  student_visibility      text not null default 'self_rank',
  starlight_visibility    text not null default 'public',
  invite_code             text,
  invite_enabled          boolean not null default true,
  register_policy         text not null default 'review',
  allow_frozen_appeal     boolean not null default false,
  default_student_password text not null default '123456',
  reward_threshold        numeric(10,2) not null default 10,
  penalty_threshold       numeric(10,2) not null default 5,
  second_class_count      int not null default 10,
  term_name               text not null default '',
  updated_at              timestamptz not null default now(),
  updated_by              uuid
);
alter table public.app_config drop constraint if exists app_config_student_visibility_check;
alter table public.app_config add constraint app_config_student_visibility_check
  check (student_visibility in ('self_rank','all_open','self_only'));
alter table public.app_config drop constraint if exists app_config_starlight_visibility_check;
alter table public.app_config add constraint app_config_starlight_visibility_check
  check (starlight_visibility in ('public','self_only'));
alter table public.app_config drop constraint if exists app_config_register_policy_check;
alter table public.app_config add constraint app_config_register_policy_check
  check (register_policy in ('review','auto'));

-- app_config 补充可配置口径（B3：抽选/监督委员人数等）
alter table public.app_config add column if not exists auto_boundaries boolean not null default true;
alter table public.app_config add column if not exists summary_visibility jsonb not null default '{"self_month":true,"own_group_week":true,"all_month":false,"all_group_week":false}'::jsonb;
alter table public.app_config add column if not exists week_reward_top_groups int not null default 3;
alter table public.app_config add column if not exists week_penalty_bottom_groups int not null default 2;
alter table public.app_config add column if not exists month_reward_top_n int not null default 15;
alter table public.app_config add column if not exists max_supervisors int not null default 2;
alter table public.app_config add column if not exists reward_card_count int not null default 1;

-- 分隔点实例（周/月/规则更新点；预生成未来 12 个月 + 保留历史）
create table if not exists public.boundaries (
  id          uuid primary key default gen_random_uuid(),
  type        text not null check (type in ('month','week','rule_update')),
  period_key  text not null default '',
  boundary_at timestamptz not null,
  label       text not null default '',
  is_manual   boolean not null default false,
  settled     boolean not null default false,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  unique (type, boundary_at)
);
-- V2.0.19：周/月周期改为「起止日期」语义（period_key = 起始日期，稳定不变）
alter table public.boundaries add column if not exists start_date date;
alter table public.boundaries add column if not exists end_date date;
alter table public.boundaries add column if not exists rule_weeks int not null default 1;
alter table public.boundaries add column if not exists deprecated boolean not null default false;
alter table public.boundaries alter column boundary_at drop not null;
create unique index if not exists boundaries_type_start_uniq on public.boundaries(type, start_date) where start_date is not null;
alter table public.boundaries drop constraint if exists boundaries_rule_weeks_check;
alter table public.boundaries add constraint boundaries_rule_weeks_check check (rule_weeks between 1 and 4);

create index if not exists boundaries_type_at_idx on public.boundaries(type, boundary_at desc);
create index if not exists boundaries_at_idx on public.boundaries(boundary_at);

-- 周汇总快照
create table if not exists public.weekly_summaries (
  id          uuid primary key default gen_random_uuid(),
  period_key  text not null,
  boundary_id uuid not null unique references public.boundaries(id) on delete cascade,
  range_start timestamptz not null,
  range_end   timestamptz not null,
  summary     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- 月度结算记录（含月汇总快照）
create table if not exists public.settlements (
  id              uuid primary key default gen_random_uuid(),
  period_key      text not null,
  boundary_id     uuid not null references public.boundaries(id) on delete cascade,
  started_at      timestamptz not null default now(),
  finished_at     timestamptz,
  status          text not null default 'running',
  auto_draw_count int not null default 0,
  second_class    jsonb not null default '[]'::jsonb,
  summary         jsonb not null default '{}'::jsonb,
  note            text,
  created_at      timestamptz not null default now()
);
alter table public.settlements drop constraint if exists settlements_status_check;
alter table public.settlements add constraint settlements_status_check
  check (status in ('running','done','failed','rolled_back'));
-- 一个分隔点只保留一条“有效”结算记录（rolled_back 的旧记录留作审计，不参与唯一约束）
alter table public.settlements drop constraint if exists settlements_boundary_id_key;
create unique index if not exists settlements_boundary_uniq
  on public.settlements(boundary_id) where status <> 'rolled_back';

-- 奖/惩池条目
create table if not exists public.lottery_items (
  id              uuid primary key default gen_random_uuid(),
  pool_type       text not null default 'reward',
  item_kind       text not null default 'plain_text',
  starlight_amount int not null default 0,
  title           text not null,
  description     text not null default '',
  weight          numeric(10,4) not null default 1,
  is_active       boolean not null default true,
  validity_type   text not null default 'month_boundary',
  validity_days   int,
  valid_until     timestamptz,
  sort_order      int not null default 0,
  created_at      timestamptz not null default now()
);
alter table public.lottery_items drop constraint if exists lottery_items_pool_type_check;
alter table public.lottery_items add constraint lottery_items_pool_type_check
  check (pool_type in ('reward','penalty'));
alter table public.lottery_items drop constraint if exists lottery_items_item_kind_check;
alter table public.lottery_items add constraint lottery_items_item_kind_check
  check (item_kind in ('func_card','starlight','starlight_penalty','plain_text'));
alter table public.lottery_items drop constraint if exists lottery_items_validity_type_check;
alter table public.lottery_items add constraint lottery_items_validity_type_check
  check (validity_type in ('month_boundary','days','fixed','permanent'));
alter table public.lottery_items drop constraint if exists lottery_items_weight_check;
alter table public.lottery_items add constraint lottery_items_weight_check check (weight >= 0);

-- 抽选结果仓库（个人 + 小组级）
create table if not exists public.lottery_draws (
  id               uuid primary key default gen_random_uuid(),
  student_id       uuid not null references public.students(id) on delete cascade,
  pool_type        text not null,
  item_id          uuid references public.lottery_items(id) on delete set null,
  item_snapshot    jsonb not null default '{}'::jsonb,
  item_kind        text not null default 'plain_text',
  starlight_amount int not null default 0,
  period_key       text not null default '',
  source           text not null default 'manual',
  group_name       text,
  is_group         boolean not null default false,
  member_ids       jsonb not null default '[]'::jsonb,
  drawn_by         uuid,
  drawn_at         timestamptz not null default now(),
  expire_at        timestamptz,
  status           text not null default 'unused',
  used_by          uuid,
  used_at          timestamptz,
  related_record_id uuid references public.records(id) on delete set null,
  note             text,
  source_week_key  text not null default ''
);
alter table public.lottery_draws add column if not exists source_week_key text not null default '';
alter table public.lottery_draws drop constraint if exists lottery_draws_pool_type_check;
alter table public.lottery_draws add constraint lottery_draws_pool_type_check
  check (pool_type in ('reward','penalty'));
alter table public.lottery_draws drop constraint if exists lottery_draws_source_check;
alter table public.lottery_draws add constraint lottery_draws_source_check
  check (source in ('manual','auto','weekly_group','weekly_group_reward','weekly_group_penalty',
                    'monthly_group_penalty','weekly_group_manual_reward','weekly_group_manual_penalty'));
alter table public.lottery_draws drop constraint if exists lottery_draws_status_check;
alter table public.lottery_draws add constraint lottery_draws_status_check
  check (status in ('unused','used','expired','void','posted'));
create index if not exists draws_student_idx on public.lottery_draws(student_id, drawn_at desc);
create index if not exists draws_period_idx on public.lottery_draws(period_key);
create index if not exists draws_status_idx on public.lottery_draws(status);
create index if not exists draws_group_idx on public.lottery_draws(group_name) where is_group;

-- 每人每月抽选次数（周/月结算写入；月末未用自动抽）
create table if not exists public.lottery_chances (
  id              uuid primary key default gen_random_uuid(),
  student_id      uuid not null references public.students(id) on delete cascade,
  period_key      text not null,
  pool_type       text not null,
  chance_type     text not null,
  amount          int not null default 1,
  used_count      int not null default 0,
  source_week_key text not null default '',
  created_at      timestamptz not null default now(),
  unique (student_id, period_key, chance_type, source_week_key)
);
alter table public.lottery_chances drop constraint if exists lottery_chances_pool_type_check;
alter table public.lottery_chances add constraint lottery_chances_pool_type_check
  check (pool_type in ('reward','penalty'));
alter table public.lottery_chances drop constraint if exists lottery_chances_chance_type_check;
alter table public.lottery_chances add constraint lottery_chances_chance_type_check
  check (chance_type in ('weekly_group','monthly_points','monthly_top15','penalty_points','second_class','group_penalty'));
alter table public.lottery_chances drop constraint if exists lottery_chances_amount_check;
alter table public.lottery_chances add constraint lottery_chances_amount_check
  check (amount >= 0 and used_count >= 0 and used_count <= amount);
create index if not exists chances_student_period_idx on public.lottery_chances(student_id, period_key);

-- 星光值账户与流水（独立于积分，只做台账）
create table if not exists public.starlight_accounts (
  student_id uuid primary key references public.students(id) on delete cascade,
  balance    int not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists public.starlight_logs (
  id               uuid primary key default gen_random_uuid(),
  student_id       uuid not null references public.students(id) on delete cascade,
  change_amount    int not null,
  source           text not null,
  related_draw_id  uuid references public.lottery_draws(id) on delete set null,
  period_key       text not null default '',
  note             text not null default '',
  operator_id      uuid,
  created_at       timestamptz not null default now()
);
alter table public.starlight_logs drop constraint if exists starlight_logs_source_check;
alter table public.starlight_logs add constraint starlight_logs_source_check
  check (source in ('starlight_card','penalty','manual','term_reset'));
create index if not exists slog_student_idx on public.starlight_logs(student_id, created_at desc);
create index if not exists slog_time_idx on public.starlight_logs(created_at desc);

-- 学期星光快照（手动学期清零前自动保存）
create table if not exists public.starlight_term_snapshots (
  id          uuid primary key default gen_random_uuid(),
  term_name   text not null,
  snapshot_at timestamptz not null default now(),
  operator_id uuid,
  summary     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- 通知信箱（按受众展开到人）
create table if not exists public.notifications (
  id           uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  title        text not null,
  body         text not null default '',
  category     text not null default 'system',
  related_type text,
  related_id   uuid,
  is_read      boolean not null default false,
  read_at      timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists notify_recipient_idx on public.notifications(recipient_id, is_read, created_at desc);

-- 积分异议申诉：V2.0.4 起取消该功能（表与 RPC 由 58_teardown.sql 删除）

-- 监督委员当周指派（学生临时授权，到期自动失效）
create table if not exists public.supervisor_assignments (
  id          uuid primary key default gen_random_uuid(),
  period_key  text not null,
  student_id  uuid not null references public.students(id) on delete cascade,
  assigned_by uuid,
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz,
  unique (period_key, student_id)
);
create index if not exists supervisor_period_idx on public.supervisor_assignments(period_key);

-- 操作审计日志（E1/E2）
create table if not exists public.audit_logs (
  id          bigserial primary key,
  actor_id    uuid,
  actor_name  text not null default '',
  action      text not null,
  target_type text not null default '',
  target_id   text not null default '',
  detail      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists audit_created_idx on public.audit_logs(created_at desc);
create index if not exists audit_actor_idx on public.audit_logs(actor_id, created_at desc);
create index if not exists audit_action_idx on public.audit_logs(action, created_at desc);


-- ------------------------------------------------------------
-- 小组集体抽选次数（V2.0.4：周汇总前 3 组奖励 / 后 2 组惩罚各 1 次，由小组代表抽）
--   奖励抽中后全组每人各得一份；惩罚抽中后全组共担执行
-- ------------------------------------------------------------
create table if not exists public.lottery_group_chances (
  id              uuid primary key default gen_random_uuid(),
  group_name      text not null,
  period_key      text not null,
  pool_type       text not null default 'reward',
  chance_type     text not null default 'weekly_group_reward',
  source_week_key text not null default '',
  amount          int  not null default 1,
  used_count      int  not null default 0,
  note            text,
  created_at      timestamptz not null default now(),
  unique (group_name, period_key, chance_type, source_week_key)
);
alter table public.lottery_group_chances drop constraint if exists lottery_group_chances_pool_check;
alter table public.lottery_group_chances add constraint lottery_group_chances_pool_check
  check (pool_type in ('reward','penalty'));
alter table public.lottery_group_chances drop constraint if exists lottery_group_chances_type_check;
alter table public.lottery_group_chances add constraint lottery_group_chances_type_check
  check (chance_type in ('weekly_group_reward','weekly_group_penalty'));
alter table public.lottery_group_chances drop constraint if exists lottery_group_chances_amount_check;
alter table public.lottery_group_chances add constraint lottery_group_chances_amount_check
  check (amount between 1 and 99 and used_count >= 0);
create index if not exists group_chances_group_idx on public.lottery_group_chances(group_name, period_key);

-- V2.0.6：回填记录人 / 修改人姓名（历史数据；匹配不到旧账号的保留 null，前端显示「历史账号」）
update public.records r set recorder_name = p.name
  from public.profiles p
 where r.recorder_name is null and r.recorder_id = p.id;
update public.records r set modified_by_name = p.name
  from public.profiles p
 where r.modified_by_name is null and r.modified_by = p.id;

-- ============================================================
-- 3. 辅助函数（角色 / 时间 / 配置 / 通知 / 审计）
--    约定：全部 security definer + 固定 search_path；
--          caller_role() 是唯一的“调用者身份”入口。
-- ============================================================

-- ------------------------------------------------------------
-- 3.1 调用者身份
--   'system'  = SQL Editor / pg_cron / service_role（无登录用户）
--   'anon'    = 未登录
--   'none'    = 已登录但档案缺失 / 待审核 / 已停用
--   其余为五级角色：super_admin / admin / executive / group_recorder / student
-- ------------------------------------------------------------
create or replace function public.caller_role()
returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_req    text := auth.role();
  v_role   text;
  v_status text;
begin
  if v_req is null or v_req = 'service_role' then
    return 'system';
  end if;
  if v_req = 'anon' then
    return 'anon';
  end if;
  select p.role, p.status into v_role, v_status
    from public.profiles p
   where p.id = auth.uid();
  if v_role is null then
    return 'none';
  end if;
  if v_status is not null and v_status <> 'active' then
    return 'none';
  end if;
  return v_role;
end;
$$;

create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.caller_role() = 'super_admin';
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.caller_role() in ('super_admin','admin');
$$;

create or replace function public.is_teacher() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.caller_role() in ('super_admin','admin','executive');
$$;

create or replace function public.is_recorder() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.caller_role() = 'group_recorder';
$$;

create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.caller_role() not in ('none','anon');
$$;

create or replace function public.my_profile_id() returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select auth.uid();
$$;

create or replace function public.my_student_id() returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select p.student_id from public.profiles p where p.id = auth.uid();
$$;

create or replace function public.my_group_name() returns text
language sql stable security definer set search_path = public, extensions as $$
  -- 优先用账号上登记的小组；账号未填时按绑定的学生档案取（建号/改角色后可能只在学生档案里有小组）
  select coalesce(nullif(btrim(p.group_name), ''),
                  (select s.group_name from public.students s where s.id = p.student_id))
    from public.profiles p
   where p.id = auth.uid();
$$;

-- 该学生是否属于当前登录账号的小组（记录员看本组用；避免策略里再查 students 触发递归 RLS）
create or replace function public.student_in_my_group(p_student_id uuid)
returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.students s
     where s.id = p_student_id
       and s.group_name is not null
       and s.group_name = public.my_group_name()
  );
$$;

-- 当前登录学生是否为“当前周”监督委员（到期自动失效）
-- 注：写成 plpgsql 而非 sql，是为了避免“函数创建时立即校验引用的函数是否存在”
--     （current_week_key 在文件后面才定义，sql 语言函数会在创建时直接报错）。
create or replace function public.is_supervisor_now()
returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if public.caller_role() <> 'student' then
    return false;
  end if;
  return exists (
    select 1 from public.supervisor_assignments sa
     where sa.student_id = public.my_student_id()
       and sa.period_key = public.current_week_key()
       and sa.revoked_at is null
  );
end;
$$;

-- 权限断言：不满足直接抛异常；system 调用直接放行
create or replace function public.require_role(p_roles text[], p_msg text default '没有权限执行此操作')
returns void
language plpgsql stable security definer set search_path = public, extensions as $$
declare v text := public.caller_role();
begin
  if v = 'system' then return; end if;
  if v = any(p_roles) then return; end if;
  raise exception '%', p_msg;
end;
$$;

create or replace function public.require_admin() returns void
language plpgsql stable security definer set search_path = public, extensions as $$
begin perform public.require_role(array['super_admin','admin']); end;
$$;

create or replace function public.require_super_admin() returns void
language plpgsql stable security definer set search_path = public, extensions as $$
begin perform public.require_role(array['super_admin']); end;
$$;

create or replace function public.require_teacher() returns void
language plpgsql stable security definer set search_path = public, extensions as $$
begin perform public.require_role(array['super_admin','admin','executive']); end;
$$;

-- ------------------------------------------------------------
-- 3.2 时间（业务时区 Asia/Shanghai）
-- ------------------------------------------------------------
create or replace function public.bj_today() returns date
language sql stable security definer set search_path = public, extensions as $$
  select (now() at time zone 'Asia/Shanghai')::date;
$$;

create or replace function public.bj_month_key(p_ts timestamptz default now()) returns text
language sql stable security definer set search_path = public, extensions as $$
  select to_char(p_ts at time zone 'Asia/Shanghai', 'YYYY-MM');
$$;

create or replace function public.bj_week_start(p_date date) returns date
language sql immutable as $$
  select p_date - (extract(isodow from p_date)::int - 1);
$$;

-- ------------------------------------------------------------
-- V2.0.19 周期（区间）解析：周/月存 start_date ~ end_date，进行中的月 end_date 为空
-- period_key = 起始日期（稳定，不随周期关闭而改变）
-- ------------------------------------------------------------
create or replace function public.period_of_date(p_type text, p_date date)
returns public.boundaries
language sql stable security definer set search_path = public, extensions as $$
  select b.* from public.boundaries b
   where b.type = p_type
     and b.deprecated = false
     and b.start_date is not null
     and b.start_date <= p_date
     and coalesce(b.end_date, '9999-12-31'::date) >= p_date
   order by b.start_date desc
   limit 1;
$$;

-- 「当前」周期：优先含今天的；否则最近已开始的；否则最早一条
create or replace function public.current_period(p_type text)
returns public.boundaries
language plpgsql stable security definer set search_path = public, extensions as $$
declare v public.boundaries;
begin
  v := public.period_of_date(p_type, public.bj_today());
  if v.id is not null then return v; end if;
  select b.* into v from public.boundaries b
   where b.type = p_type and b.deprecated = false and b.start_date is not null
     and b.start_date <= public.bj_today()
   order by b.start_date desc limit 1;
  if v.id is not null then return v; end if;
  select b.* into v from public.boundaries b
   where b.type = p_type and b.deprecated = false and b.start_date is not null
   order by b.start_date limit 1;
  return v;
end;
$$;

create or replace function public.boundary_of(p_type text)
returns public.boundaries
language sql stable security definer set search_path = public, extensions as $$
  select public.current_period(p_type);
$$;

create or replace function public.period_key_of(p_type text, p_date date)
returns text
language sql stable security definer set search_path = public, extensions as $$
  select (public.period_of_date(p_type, p_date)).period_key;
$$;

create or replace function public.current_month_key() returns text
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((public.current_period('month')).period_key, public.bj_month_key());
$$;

create or replace function public.current_week_key() returns text
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((public.current_period('week')).period_key, public.bj_week_start(public.bj_today())::text);
$$;

create or replace function public.next_month_boundary_at() returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
    (select (b.end_date + 1)::timestamp at time zone 'Asia/Shanghai'
       from public.boundaries b
      where b.type = 'month' and b.deprecated = false and b.end_date is not null
        and b.end_date >= public.bj_today()
      order by b.start_date limit 1),
    ((public.bj_week_start(public.bj_today()) + 7)::timestamp at time zone 'Asia/Shanghai')
  );
$$;

create or replace function public.is_future_date(p_date date) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select p_date > public.bj_today();
$$;

-- 该业务日期是否落在「已结算且已结束」的月区间内（冻结）
create or replace function public.is_month_frozen(p_date date) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.boundaries b
     where b.type = 'month' and b.deprecated = false and b.settled = true
       and b.end_date is not null
       and p_date <= b.end_date
  );
$$;

create or replace function public.is_maintenance() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
    (nullif(public.cfg()->>'maintenance_until',''))::timestamptz > now(),
    false
  );
$$;

-- ------------------------------------------------------------
-- 3.3 系统配置（app_config 单行 → jsonb）
-- ------------------------------------------------------------
create or replace function public.cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
    (select to_jsonb(c) from public.app_config c where c.id = 1),
    '{}'::jsonb
  );
$$;

-- ------------------------------------------------------------
-- 3.4 业务查询辅助
-- ------------------------------------------------------------
create or replace function public.student_group(p_student_id uuid) returns text
language sql stable security definer set search_path = public, extensions as $$
  select s.group_name from public.students s where s.id = p_student_id;
$$;

create or replace function public.group_members(p_group text) returns uuid[]
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(array_agg(s.id order by s.created_at, s.id), array[]::uuid[])
    from public.students s
   where s.group_name = p_group;
$$;

-- ------------------------------------------------------------
-- 3.5 审计与通知（内部函数：仅允许其他 definer 函数调用，不对前端授权）
-- ------------------------------------------------------------
create or replace function public.write_audit(
  p_action      text,
  p_target_type text,
  p_target_id   text,
  p_detail      jsonb default '{}'::jsonb
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_name text;
begin
  select p.name into v_name from public.profiles p where p.id = auth.uid();
  insert into public.audit_logs (actor_id, actor_name, action, target_type, target_id, detail)
  values (
    auth.uid(),
    coalesce(v_name, case when auth.uid() is null then 'system' else '未知用户' end),
    p_action,
    coalesce(p_target_type, ''),
    coalesce(p_target_id, ''),
    coalesce(p_detail, '{}'::jsonb)
  );
end;
$$;

create or replace function public.notify(
  p_recipient  uuid,
  p_title      text,
  p_body       text,
  p_category   text default 'system',
  p_related_type text default null,
  p_related_id uuid default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_recipient is null then
    return;
  end if;
  insert into public.notifications (recipient_id, title, body, category, related_type, related_id)
  values (p_recipient, coalesce(p_title,'通知'), coalesce(p_body,''), coalesce(p_category,'system'),
          p_related_type, p_related_id);
end;
$$;

create or replace function public.notify_audience(
  p_audience   text,
  p_title      text,
  p_body       text,
  p_category   text default 'system',
  p_related_type text default null,
  p_related_id uuid default null
) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_count int := 0;
begin
  insert into public.notifications (recipient_id, title, body, category, related_type, related_id)
  select p.id, coalesce(p_title,'通知'), coalesce(p_body,''), coalesce(p_category,'system'),
         p_related_type, p_related_id
    from public.profiles p
   where p.status = 'active'
     and (
       p_audience = 'all'
       or (p_audience = 'students' and p.role = 'student')
       or (p_audience = 'teachers' and p.role in ('super_admin','admin','executive','group_recorder'))
       or (p_audience = 'admins' and p.role in ('super_admin','admin'))
       or (p_audience = 'executive_plus' and p.role in ('super_admin','admin','executive'))
     );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

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

-- ============================================================
-- 5. 积分记录 RPC（时间限制 / 2 秒冻结 / 规则上限 / 留痕）
--    以及积分规则、学生档案、排行榜
-- ============================================================

-- ------------------------------------------------------------
-- 5.1 内部：规则周期上限校验（add/update 共用，不对前端授权）
--     周期边界 = 最近一个已到点的周分隔点 / 自定义更新点 / 月分隔点
--     统计口径：**按被登记的学生**统计——同一学生在同一规则、同一周期内
--               最多登记 limit_value 次 / limit_value 分（不是全班合计）
-- ------------------------------------------------------------
create or replace function public.check_rule_limit(
  p_rule_id    uuid,
  p_points     numeric,
  p_student_id uuid,
  p_date       date,
  p_exclude    uuid default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  r        public.rules;
  v_w      public.boundaries;
  v_mult   int;
  v_limit  numeric;
  v_used   numeric;
  v_cnt    int;
  v_delta  numeric;
begin
  if p_rule_id is null then
    return;
  end if;
  select * into r from public.rules where id = p_rule_id;
  if r.id is null then
    raise exception '积分规则不存在';
  end if;
  if r.limit_type = 'none' or r.limit_value is null then
    return;
  end if;
  if p_student_id is null then
    raise exception '规则上限需要指定被登记的学生';
  end if;

  -- 周期 = 登记日期所在「周周期」；额度 = 单周期上限 × 规则计分周数
  v_w := public.period_of_date('week', coalesce(p_date, public.bj_today()));
  if v_w.id is null then
    raise exception '登记日期不在任何周周期内，请先在「设置 → 周期定义」补齐周期';
  end if;
  v_mult  := greatest(coalesce(v_w.rule_weeks, 1), 1);
  v_limit := r.limit_value * v_mult;
  v_delta := case when r.score_type = '扣分' then abs(p_points) else p_points end;

  select count(*),
         coalesce(sum(case when r.score_type = '扣分' then abs(rc.points) else rc.points end), 0)
    into v_cnt, v_used
    from public.records rc
   where rc.rule_id = p_rule_id
     and rc.student_id = p_student_id
     and rc.status = '正常'
     and rc.record_date >= to_char(v_w.start_date, 'YYYY-MM-DD')
     and rc.record_date <= to_char(v_w.end_date, 'YYYY-MM-DD')
     and (p_exclude is null or rc.id <> p_exclude);

  if r.limit_type = 'count' then
    if v_cnt + 1 > v_limit then
      raise exception '规则「%」每位学生本周期最多登记 % 次（该生已登记 % 次%s），已达上限',
        r.reason, v_limit::int, v_cnt,
        case when v_mult > 1 then '；本周按 ' || v_mult || ' 个规则计分周' else '' end;
    end if;
  else
    if v_used + v_delta > v_limit then
      raise exception '规则「%」每位学生本周期分值上限 %（该生已用 %，本次 %）%', r.reason, v_limit, v_used, v_delta,
        case when v_mult > 1 then '；本周按 ' || v_mult || ' 个规则计分周' else '' end;
    end if;
  end if;
end;
$$;
revoke all on function public.check_rule_limit(uuid, numeric, uuid, date, uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 5.2 新增记录
-- ------------------------------------------------------------
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
  v_role  text := public.caller_role();
  v_rec   public.records;
  v_week  public.boundaries;
  v_month public.boundaries;
begin
  -- 监督委员（学生，当周临时授权）可以登记积分；其余角色按原权限
  if v_role not in ('system','super_admin','admin','executive','group_recorder') then
    if not public.is_supervisor_now() then
      raise exception '没有权限登记积分';
    end if;
  end if;
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

  v_week  := public.period_of_date('week', p_record_date);
  v_month := public.period_of_date('month', p_record_date);
  if v_week.id is null or v_month.id is null then
    raise exception '该日期不在任何周期内，请先在「设置 → 周期定义」补齐周期';
  end if;

  perform public.check_rule_limit(p_rule_id, p_points, p_student_id, p_record_date, null);

  insert into public.records (
    student_id, score_type, category, reason, points, recorder_id, recorder_name,
    record_date, status, evidence, rule_id, frozen_until, period_key
  ) values (
    p_student_id, p_score_type, coalesce(p_category,''), coalesce(p_reason,''), p_points, auth.uid(),
    (select p.name from public.profiles p where p.id = auth.uid()),
    p_record_date::text, '正常', p_evidence, p_rule_id,
    now() + interval '2 seconds', v_month.period_key
  ) returning * into v_rec;

  perform public.write_audit('add_record', 'record', v_rec.id::text,
    jsonb_build_object('student_id', p_student_id, 'points', p_points,
                       'reason', p_reason, 'record_date', p_record_date));
  return to_jsonb(v_rec);
end;
$$;
revoke all on function public.add_record(uuid, text, text, text, numeric, date, uuid, text) from public, anon, authenticated;
grant execute on function public.add_record(uuid, text, text, text, numeric, date, uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 5.3 修改记录
-- ------------------------------------------------------------
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
  v_old   public.records;
  v_new   public.records;
  v_date  date;
  v_week  public.boundaries;
  v_month public.boundaries;
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

  v_week  := public.period_of_date('week', v_date);
  v_month := public.period_of_date('month', v_date);
  if v_week.id is null or v_month.id is null then
    raise exception '目标日期不在任何周期内，请先在「设置 → 周期定义」补齐周期';
  end if;

  perform public.check_rule_limit(v_old.rule_id, p_points, v_old.student_id, v_date, v_old.id);

  update public.records
     set reason      = coalesce(p_reason, reason),
         points      = p_points,
         evidence    = coalesce(p_evidence, evidence),
         record_date = v_date::text,
         period_key  = v_month.period_key,
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

-- ------------------------------------------------------------
-- 5.4 删除记录（软删除，保留流水与审计）
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 5.5 C4 冻结月纠错（仅 super_admin，强制留痕）
--     p_patch 可含：points / reason / category / record_date / evidence / status('已删除')
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 5.6 积分规则 CRUD（D4：super_admin/admin/executive）
-- ------------------------------------------------------------
create or replace function public.admin_save_rule(p_rule jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id   uuid;
  v_row  public.rules;
  v_type text := coalesce(p_rule->>'limit_type', 'none');
begin
  perform public.require_teacher();
  if coalesce(p_rule->>'score_type','') not in ('加分','扣分') then
    raise exception '积分类型必须是「加分」或「扣分」';
  end if;
  if coalesce(p_rule->>'category','') = '' or coalesce(p_rule->>'reason','') = '' then
    raise exception '请填写规则分类与说明';
  end if;
  if v_type not in ('none','count','points') then
    raise exception '上限类型不合法';
  end if;
  if v_type = 'none' then
    -- 清空上限
    null;
  elsif coalesce((p_rule->>'limit_value')::numeric, 0) <= 0 then
    raise exception '请填写大于 0 的周期上限值';
  end if;

  v_id := nullif(p_rule->>'id','')::uuid;
  if v_id is null then
    insert into public.rules (score_type, category, reason, points, remark, sort_order,
                              limit_type, limit_value)
    values (p_rule->>'score_type', p_rule->>'category', p_rule->>'reason',
            coalesce((p_rule->>'points')::numeric, 0), coalesce(p_rule->>'remark',''),
            coalesce((p_rule->>'sort_order')::int, 0), v_type,
            case when v_type = 'none' then null else (p_rule->>'limit_value')::numeric end)
    returning * into v_row;
  else
    update public.rules
       set score_type  = p_rule->>'score_type',
           category    = p_rule->>'category',
           reason      = p_rule->>'reason',
           points      = coalesce((p_rule->>'points')::numeric, 0),
           remark      = coalesce(p_rule->>'remark',''),
           sort_order  = coalesce((p_rule->>'sort_order')::int, sort_order),
           limit_type  = v_type,
           limit_value = case when v_type = 'none' then null else (p_rule->>'limit_value')::numeric end
     where id = v_id
     returning * into v_row;
    if v_row.id is null then
      raise exception '规则不存在';
    end if;
  end if;

  perform public.write_audit(
    case when nullif(p_rule->>'id','') is null then 'create_rule' else 'update_rule' end,
    'rule', v_row.id::text, jsonb_build_object('reason', v_row.reason, 'points', v_row.points,
                                               'limit_type', v_row.limit_type, 'limit_value', v_row.limit_value));
  return to_jsonb(v_row);
end;
$$;
revoke all on function public.admin_save_rule(jsonb) from public, anon, authenticated;
grant execute on function public.admin_save_rule(jsonb) to authenticated;

create or replace function public.admin_delete_rule(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_row public.rules;
begin
  perform public.require_teacher();
  select * into v_row from public.rules where id = p_id;
  if v_row.id is null then
    raise exception '规则不存在';
  end if;
  delete from public.rules where id = p_id;
  perform public.write_audit('delete_rule', 'rule', p_id::text,
    jsonb_build_object('reason', v_row.reason, 'points', v_row.points));
end;
$$;
revoke all on function public.admin_delete_rule(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_rule(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5.7 学生档案（D1；C6 删除学生仅 super_admin）
-- ------------------------------------------------------------
create or replace function public.admin_save_student(
  p_name       text,
  p_group_name text,
  p_student_no text default null,
  p_id         uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_row public.students;
begin
  perform public.require_teacher();
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_group_name), '') = '' then
    raise exception '请填写学生姓名与小组';
  end if;
  if coalesce(trim(p_student_no), '') <> ''
     and exists (select 1 from public.students s
                  where s.student_no = trim(p_student_no)
                    and (p_id is null or s.id <> p_id)) then
    raise exception '学号「%」已被其他学生使用', trim(p_student_no);
  end if;

  if p_id is null then
    insert into public.students (name, group_name, student_no)
    values (trim(p_name), trim(p_group_name), nullif(trim(p_student_no), ''))
    returning * into v_row;
  else
    update public.students
       set name = trim(p_name), group_name = trim(p_group_name),
           student_no = nullif(trim(p_student_no), '')
     where id = p_id
     returning * into v_row;
    if v_row.id is null then
      raise exception '学生不存在';
    end if;
  end if;

  perform public.write_audit(
    case when p_id is null then 'create_student' else 'update_student' end,
    'student', v_row.id::text, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;
revoke all on function public.admin_save_student(text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.admin_save_student(text, text, text, uuid) to authenticated;

-- 批量导入/覆盖（前端「导入名单」用）：按学号匹配则更新，否则新增
create or replace function public.admin_import_students(p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_row     jsonb;
  v_id      uuid;
  v_ins     int := 0;
  v_upd     int := 0;
  v_skip    jsonb := '[]'::jsonb;
begin
  perform public.require_teacher();
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception '导入数据格式错误';
  end if;
  for v_row in select * from jsonb_array_elements(p_rows) loop
    if coalesce(trim(v_row->>'name'), '') = '' or coalesce(trim(v_row->>'group_name'), '') = '' then
      v_skip := v_skip || jsonb_build_array(jsonb_build_object('row', v_row, 'reason', '姓名或小组为空'));
      continue;
    end if;
    v_id := null;
    if coalesce(trim(v_row->>'student_no'), '') <> '' then
      select id into v_id from public.students where student_no = trim(v_row->>'student_no') limit 1;
    end if;
    if v_id is null then
      insert into public.students (name, group_name, student_no)
      values (trim(v_row->>'name'), trim(v_row->>'group_name'), nullif(trim(v_row->>'student_no'), ''));
      v_ins := v_ins + 1;
    else
      update public.students
         set name = trim(v_row->>'name'), group_name = trim(v_row->>'group_name')
       where id = v_id;
      v_upd := v_upd + 1;
    end if;
  end loop;
  perform public.write_audit('import_students', 'student', '', jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'skipped', v_skip));
  return jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'skipped', v_skip);
end;
$$;
revoke all on function public.admin_import_students(jsonb) from public, anon, authenticated;
grant execute on function public.admin_import_students(jsonb) to authenticated;

-- C6 删除学生档案（仅 super_admin）：连积分记录一起清，保留审计
create or replace function public.admin_delete_student(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_row public.students;
  v_rec int;
  v_users uuid[];
begin
  perform public.require_super_admin();
  select * into v_row from public.students where id = p_id;
  if v_row.id is null then
    raise exception '学生不存在';
  end if;
  -- 该学生已绑定的账号：连 auth.users 一起删除（profiles 随 auth.users 级联），
  -- 否则残留账号会占用邮箱/用户名，导致同学号无法重新建号（验收时实测踩到）
  select coalesce(array_agg(id), array[]::uuid[]) into v_users
    from public.profiles where student_id = p_id;
  delete from public.records where student_id = p_id;
  get diagnostics v_rec = row_count;
  update public.profiles set student_id = null where student_id = p_id;
  if array_length(v_users, 1) is not null then
    delete from auth.users where id = any(v_users);
  end if;
  delete from public.students where id = p_id;  -- 其余子表（抽选/星光/申诉/监督）随外键级联删除
  perform public.write_audit('delete_student', 'student', p_id::text,
    jsonb_build_object('name', v_row.name, 'group_name', v_row.group_name,
                       'student_no', v_row.student_no, 'deleted_records', v_rec,
                       'deleted_accounts', coalesce(array_length(v_users, 1), 0)));
end;
$$;
revoke all on function public.admin_delete_student(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_student(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5.8 排行榜（按学生信息可见范围裁剪：self_rank/all_open 可看排行榜，self_only 只看自己）
-- ------------------------------------------------------------
create or replace function public.student_rankings(p_scope text default 'all')
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text := public.caller_role();
  v_cfg   jsonb := public.cfg();
  v_vis   text := coalesce(v_cfg->>'student_visibility', 'self_rank');
  v_sum   jsonb := coalesce(v_cfg->'summary_visibility', '{}'::jsonb);
  v_month text := public.current_month_key();
  v_week  text := public.current_week_key();
  v_week_start date;
  v_me    uuid := public.my_student_id();
  v_my_group text := public.my_group_name();
  v_ind   jsonb;
  v_grp   jsonb;
  v_perm  jsonb;
begin
  if v_role in ('none','anon') then
    raise exception '请先登录';
  end if;

  select (b.boundary_at at time zone 'Asia/Shanghai')::date into v_week_start
    from public.boundaries b
   where b.type = 'week' and b.boundary_at <= now()
   order by b.boundary_at desc limit 1;
  if v_week_start is null then
    v_week_start := (now() at time zone 'Asia/Shanghai')::date - 6;
  end if;

  -- 个人榜（含总积分、本月、本周，及对应名次）
  select coalesce(jsonb_agg(x order by (x->>'month_rank')::int, x->>'name'), '[]'::jsonb) into v_ind
    from (
      select jsonb_build_object(
               'student_id', t.student_id, 'name', t.name, 'group_name', t.group_name,
               'total', t.total, 'month_total', t.month_total, 'week_total', t.week_total,
               'rank', dense_rank() over (order by t.total desc),
               'month_rank', dense_rank() over (order by t.month_total desc),
               'week_rank', dense_rank() over (order by t.week_total desc)
             ) as x
        from (
          select s.id as student_id, s.name, s.group_name,
                 coalesce(sum(case when r.status = '正常' then r.points else 0 end), 0) as total,
                 coalesce(sum(case when r.status = '正常' and left(r.record_date, 7) = v_month then r.points else 0 end), 0) as month_total,
                 coalesce(sum(case when r.status = '正常' and (nullif(r.record_date,''))::date >= v_week_start then r.points else 0 end), 0) as week_total
            from public.students s
            left join public.records r on r.student_id = s.id
           group by s.id, s.name, s.group_name
        ) t
    ) q;

  -- 小组榜（总积分、本月、本周）
  select coalesce(jsonb_agg(x order by (x->>'week_rank')::int, x->>'group_name'), '[]'::jsonb) into v_grp
    from (
      select jsonb_build_object(
               'group_name', g.group_name, 'total', g.total, 'month_total', g.month_total,
               'week_total', g.week_total,
               'rank', dense_rank() over (order by g.total desc),
               'month_rank', dense_rank() over (order by g.month_total desc),
               'week_rank', dense_rank() over (order by g.week_total desc),
               'members', g.members
             ) as x
        from (
          select s.group_name,
                 coalesce(sum(case when r.status = '正常' then r.points else 0 end), 0) as total,
                 coalesce(sum(case when r.status = '正常' and left(r.record_date, 7) = v_month then r.points else 0 end), 0) as month_total,
                 coalesce(sum(case when r.status = '正常' and (nullif(r.record_date,''))::date >= v_week_start then r.points else 0 end), 0) as week_total,
                 count(distinct s.id) as members
            from public.students s
            left join public.records r on r.student_id = s.id
           group by s.group_name
        ) g
    ) q2;

  if v_role = 'student' then
    -- 管理员配置的四项汇总可见性（旧配置兼容：self_only→全部关闭，all_open→全部开放）
    v_perm := jsonb_build_object(
      'self_month',       coalesce((v_sum->>'self_month')::boolean,       v_vis <> 'self_only'),
      'own_group_week',   coalesce((v_sum->>'own_group_week')::boolean,   v_vis <> 'self_only'),
      'all_month',        coalesce((v_sum->>'all_month')::boolean,        v_vis = 'all_open'),
      'all_group_week',   coalesce((v_sum->>'all_group_week')::boolean,   v_vis = 'all_open')
    );
    -- 个人榜：全部 或 只看自己 或 空
    if not coalesce((v_perm->>'all_month')::boolean, false) then
      if coalesce((v_perm->>'self_month')::boolean, false) then
        v_ind := coalesce((select jsonb_agg(i) from jsonb_array_elements(v_ind) i
                            where (i->>'student_id') = v_me::text), '[]'::jsonb);
      else
        v_ind := '[]'::jsonb;
      end if;
    end if;
    -- 小组榜：全部 或 只看本组 或 空
    if not coalesce((v_perm->>'all_group_week')::boolean, false) then
      if coalesce((v_perm->>'own_group_week')::boolean, false) then
        v_grp := coalesce((select jsonb_agg(g) from jsonb_array_elements(v_grp) g
                            where (g->>'group_name') = v_my_group), '[]'::jsonb);
      else
        v_grp := '[]'::jsonb;
      end if;
    end if;
  else
    v_perm := jsonb_build_object('self_month', true, 'own_group_week', true, 'all_month', true, 'all_group_week', true);
  end if;

  return jsonb_build_object(
    'period_key', v_month,
    'week_key', v_week,
    'week_start', v_week_start,
    'visibility', v_vis,
    'permissions', v_perm,
    'my_group', v_my_group,
    'individuals', v_ind,
    'groups', v_grp
  );
end;
$$;
revoke all on function public.student_rankings(text) from public, anon, authenticated;
grant execute on function public.student_rankings(text) to authenticated;

-- ============================================================
-- 5.1 应用状态 / 时间分隔点 / 系统配置（B1/B2/B3/B8）
-- ============================================================

-- ------------------------------------------------------------
-- 登录配置（登录页用，未登录可调用，不含任何敏感值）
-- ------------------------------------------------------------
create or replace function public.get_login_config()
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'version', '2.0.0',
    'invite_enabled', coalesce((public.cfg()->>'invite_enabled')::boolean, true),
    'register_policy', coalesce(public.cfg()->>'register_policy', 'review'),
    'maintenance', public.is_maintenance()
  );
$$;
revoke all on function public.get_login_config() from public, anon, authenticated;
grant execute on function public.get_login_config() to anon, authenticated;

-- ------------------------------------------------------------
-- 应用状态（登录后首屏：身份 / 可见配置 / 周期 / 未读数）
--   待审核或停用账号也会返回（me.status 供前端提示），不抛错
-- ------------------------------------------------------------
create or replace function public.get_app_state()
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_p        public.profiles;
  v_cfg      jsonb;
  v_unread   int := 0;
begin
  if auth.uid() is null then
    raise exception '请先登录';
  end if;
  select * into v_p from public.profiles where id = auth.uid();

  v_cfg := public.cfg();
  if not public.is_admin() then
    -- 邀请码与初始密码仅管理员可见
    v_cfg := v_cfg - 'invite_code' - 'default_student_password';
  end if;

  if v_p.id is not null then
    select count(*) into v_unread
      from public.notifications n
     where n.recipient_id = auth.uid() and not n.is_read;
  end if;

  return jsonb_build_object(
    'version', '2.0.0',
    'server_now', now(),
    'me', case when v_p.id is null then null else jsonb_build_object(
      'id', v_p.id,
      'username', v_p.username,
      'name', v_p.name,
      'role', v_p.role,
      'status', v_p.status,
      'group_name', v_p.group_name,
      'student_id', v_p.student_id,
      'must_change_password', v_p.must_change_password,
      'positions', to_jsonb(coalesce(v_p.positions, '{}'::text[])),
      'is_supervisor', public.is_supervisor_now(),
      'is_admin', public.is_admin(),
      'is_teacher', public.is_teacher()
    ) end,
    'config', v_cfg,
    'period', jsonb_build_object(
      'month_key', public.current_month_key(),
      'week_key', public.current_week_key(),
      'next_month_at', public.next_month_boundary_at(),
      'next_week_at', coalesce(
        (select min(b.boundary_at) from public.boundaries b where b.type = 'week' and b.boundary_at > now()),
        now() + interval '7 days'),
      'maintenance', public.is_maintenance(),
      'maintenance_until', public.cfg()->>'maintenance_until'
    ),
    'unread', v_unread
  );
end;
$$;
revoke all on function public.get_app_state() from public, anon, authenticated;
grant execute on function public.get_app_state() to authenticated;

-- ------------------------------------------------------------
-- 周期状态（前端倒计时 / 只读提示 / 日期选择禁用范围）
-- ------------------------------------------------------------
create or replace function public.get_period_state()
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_month public.boundaries;
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  v_month := public.boundary_of('month');
  return jsonb_build_object(
    'server_now', now(),
    'month_key', public.current_month_key(),
    'week_key', public.current_week_key(),
    'next_month_at', public.next_month_boundary_at(),
    'next_week_at', coalesce(
      (select min(b.boundary_at) from public.boundaries b where b.type = 'week' and b.boundary_at > now()),
      now() + interval '7 days'),
    'month_boundary_at', v_month.boundary_at,
    'locked_before_date', case when v_month.id is null then null
      else (v_month.boundary_at at time zone 'Asia/Shanghai')::date end,
    'maintenance', public.is_maintenance(),
    'maintenance_until', nullif(public.cfg()->>'maintenance_until','')::timestamptz
  );
end;
$$;
revoke all on function public.get_period_state() from public, anon, authenticated;
grant execute on function public.get_period_state() to authenticated;

-- ------------------------------------------------------------
-- 内部：按配置预生成周/月分隔点（幂等，已存在则跳过）
-- ------------------------------------------------------------
-- ------------------------------------------------------------
-- V2.0.19：不再按规则批量铺底；只保证「当前周」与「当前月（进行中）」各一条作为起点
-- ------------------------------------------------------------
create or replace function public.ensure_boundaries(
  p_months_back    int default 6,
  p_months_forward int default 12
) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_today date := public.bj_today();
  v_ws    date := public.bj_week_start(public.bj_today());
  v_n     int := 0;
begin
  if not exists (select 1 from public.boundaries where type = 'week' and start_date = v_ws) then
    insert into public.boundaries (type, period_key, start_date, end_date, rule_weeks, boundary_at, label, is_manual, settled)
    values ('week', to_char(v_ws, 'YYYY-MM-DD'), v_ws, v_ws + 6, 1,
            ((v_ws + 7)::timestamp at time zone 'Asia/Shanghai'),
            to_char(v_ws, 'YYYY-MM-DD') || ' ~ ' || to_char(v_ws + 6, 'YYYY-MM-DD'), false,
            ((v_ws + 7)::timestamp at time zone 'Asia/Shanghai') <= now() - interval '1 day')
    on conflict do nothing;
    v_n := v_n + 1;
  end if;

  if not exists (select 1 from public.boundaries b
                  where b.type = 'month' and b.start_date <= v_today
                    and coalesce(b.end_date, '9999-12-31'::date) >= v_today) then
    insert into public.boundaries (type, period_key, start_date, end_date, rule_weeks, boundary_at, label, is_manual, settled)
    values ('month', to_char(v_ws, 'YYYY-MM-DD'), v_ws, null, 1, null,
            to_char(v_ws, 'YYYY-MM-DD') || ' ~ （进行中）', false, false)
    on conflict do nothing;
    v_n := v_n + 1;
  end if;

  return v_n;
end;
$$;
revoke all on function public.ensure_boundaries(int, int) from public, anon, authenticated;

-- ------------------------------------------------------------
-- B1 修改周/月分隔规则（仅 super_admin）→ 重算未来分隔点
--   p_week  : {"dow":1,"hour":0,"minute":0}   dow 1=周一 … 7=周日
--   p_month : {"dom":1,"hour":0,"minute":0}   dom 1..28
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- V2.0.6：开启/关闭「按规则自动生成未来分隔点」
--   关闭后：cron/规则保存不再预生成未来分隔点，只能手动新增；已有分隔点与周期作业不受影响
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- B2 手动增/删分隔点（仅 super_admin）与重算
-- ------------------------------------------------------------
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

create or replace function public.admin_delete_boundary(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_row public.boundaries;
begin
  perform public.require_super_admin();
  select * into v_row from public.boundaries where id = p_id;
  if v_row.id is null then
    raise exception '分隔点不存在';
  end if;
  if v_row.boundary_at <= now() then
    raise exception '已到点的分隔点不能删除（会影响历史冻结与汇总判定）';
  end if;
  if v_row.settled then
    raise exception '该分隔点已结算，不能删除';
  end if;
  delete from public.boundaries where id = p_id;
  perform public.write_audit('delete_boundary', 'boundary', p_id::text, to_jsonb(v_row));
end;
$$;
revoke all on function public.admin_delete_boundary(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_boundary(uuid) to authenticated;

create or replace function public.admin_regenerate_boundaries()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_before int;
begin
  perform public.require_super_admin();
  select count(*) into v_before from public.boundaries;
  perform public.ensure_boundaries(6, 12);
  perform public.write_audit('regenerate_boundaries', 'boundary', '',
    jsonb_build_object('before', v_before, 'after', (select count(*) from public.boundaries)));
  return jsonb_build_object('before', v_before, 'after', (select count(*) from public.boundaries));
end;
$$;
revoke all on function public.admin_regenerate_boundaries() from public, anon, authenticated;
grant execute on function public.admin_regenerate_boundaries() to authenticated;

-- ------------------------------------------------------------
-- B3 修改系统配置（仅 super_admin，字段白名单 + 取值校验）
-- ------------------------------------------------------------
create or replace function public.admin_set_config(p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_vis      text;
  v_star_vis text;
  v_policy   text;
  v_new_pwd  text;
  v_sum      jsonb;
  v_key      text;
begin
  perform public.require_super_admin();
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception '配置内容格式错误';
  end if;

  if p_patch ? 'student_visibility' then
    v_vis := p_patch->>'student_visibility';
    if v_vis not in ('self_rank','all_open','self_only') then
      raise exception '学生信息可见范围不合法';
    end if;
  end if;
  if p_patch ? 'starlight_visibility' then
    v_star_vis := p_patch->>'starlight_visibility';
    if v_star_vis not in ('public','self_only') then
      raise exception '星光公示范围不合法';
    end if;
  end if;
  if p_patch ? 'register_policy' then
    v_policy := p_patch->>'register_policy';
    if v_policy not in ('review','auto') then
      raise exception '注册审核策略不合法';
    end if;
  end if;
  if p_patch ? 'default_student_password' then
    v_new_pwd := p_patch->>'default_student_password';
    if length(coalesce(v_new_pwd,'')) < 6 then
      raise exception '初始密码至少 6 位';
    end if;
  end if;
  if p_patch ? 'max_supervisors' and coalesce((p_patch->>'max_supervisors')::int, 0) < 1 then
    raise exception '监督委员人数至少 1 人';
  end if;

  if p_patch ? 'summary_visibility' then
    if jsonb_typeof(p_patch->'summary_visibility') <> 'object' then
      raise exception '汇总可见范围格式错误';
    end if;
    v_sum := '{}'::jsonb;
    foreach v_key in array array['self_month','own_group_week','all_month','all_group_week'] loop
      if p_patch->'summary_visibility' ? v_key then
        v_sum := v_sum || jsonb_build_object(v_key,
          coalesce((p_patch->'summary_visibility'->>v_key)::boolean, false));
      end if;
    end loop;
    if v_sum = '{}'::jsonb then
      raise exception '汇总可见范围没有可识别的选项';
    end if;
  end if;

  update public.app_config set
    student_visibility      = coalesce(p_patch->>'student_visibility', student_visibility),
    starlight_visibility    = coalesce(p_patch->>'starlight_visibility', starlight_visibility),
    invite_code             = coalesce(p_patch->>'invite_code', invite_code),
    invite_enabled          = coalesce((p_patch->>'invite_enabled')::boolean, invite_enabled),
    register_policy         = coalesce(p_patch->>'register_policy', register_policy),
    allow_frozen_appeal     = coalesce((p_patch->>'allow_frozen_appeal')::boolean, allow_frozen_appeal),
    summary_visibility      = coalesce(summary_visibility || v_sum, summary_visibility),
    default_student_password = coalesce(p_patch->>'default_student_password', default_student_password),
    reward_threshold        = coalesce((p_patch->>'reward_threshold')::numeric, reward_threshold),
    penalty_threshold       = coalesce((p_patch->>'penalty_threshold')::numeric, penalty_threshold),
    second_class_count      = coalesce((p_patch->>'second_class_count')::int, second_class_count),
    term_name               = coalesce(p_patch->>'term_name', term_name),
    maintenance_minutes     = coalesce((p_patch->>'maintenance_minutes')::int, maintenance_minutes),
    week_reward_top_groups  = coalesce((p_patch->>'week_reward_top_groups')::int, week_reward_top_groups),
    week_penalty_bottom_groups = coalesce((p_patch->>'week_penalty_bottom_groups')::int, week_penalty_bottom_groups),
    month_reward_top_n      = coalesce((p_patch->>'month_reward_top_n')::int, month_reward_top_n),
    max_supervisors         = coalesce((p_patch->>'max_supervisors')::int, max_supervisors),
    reward_card_count       = coalesce((p_patch->>'reward_card_count')::int, reward_card_count),
    updated_at              = now(),
    updated_by              = auth.uid()
  where id = 1;

  perform public.write_audit('set_config', 'app_config', '1', p_patch);
  return public.cfg();
end;
$$;
revoke all on function public.admin_set_config(jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_config(jsonb) to authenticated;

-- ------------------------------------------------------------
-- B8 维护模式开关（仅 super_admin；月度结算会自动开启）
--   V2.0.6：支持直接指定结束时间 p_until（优先于 p_minutes），可单独设置维护时间
-- ------------------------------------------------------------
drop function if exists public.admin_toggle_maintenance(boolean, int);
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

-- ============================================================
-- 5.2 奖惩抽选（两池独立 / 周月双触发 / 仓库 / 星光即时入账）
-- ============================================================

-- ------------------------------------------------------------
-- 内部：加权随机抽一条池子条目
-- ------------------------------------------------------------
create or replace function public._pick_lottery_item(p_pool text)
returns public.lottery_items
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_item public.lottery_items;
begin
  select li.* into v_item
    from (
      select i.*, sum(i.weight) over (order by i.sort_order, i.id) as cum
        from public.lottery_items i
       where i.pool_type = p_pool and i.is_active and i.weight > 0
    ) li,
    (select sum(i.weight) as total
       from public.lottery_items i
      where i.pool_type = p_pool and i.is_active and i.weight > 0) t
   where li.cum >= random() * t.total
   order by li.cum
   limit 1;
  return v_item;
end;
$$;
revoke all on function public._pick_lottery_item(text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 内部：生成一条抽选记录并立即生效（星光卡/扣星光即时入账）
--   p_is_group=true 时 member_ids 为全组成员：文本惩罚由全组共担执行，
--   星光类效果对全组成员逐一计入（共担）。
-- ------------------------------------------------------------
drop function if exists public._apply_draw(uuid, text, uuid, text, text, text, jsonb, boolean, text, uuid);
create or replace function public._apply_draw(
  p_student_id uuid,
  p_pool_type  text,
  p_item_id    uuid,
  p_period_key text,
  p_source     text,
  p_group_name text    default null,
  p_member_ids jsonb   default '[]'::jsonb,
  p_is_group   boolean default false,
  p_note       text    default null,
  p_drawn_by   uuid    default null,
  p_credit_all_members boolean default true
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_item      public.lottery_items;
  v_draw_id   uuid;
  v_expire    timestamptz;
  v_status    text;
  v_note      text;
  v_member    jsonb;
  v_mid       uuid;
begin
  select * into v_item from public.lottery_items where id = p_item_id;
  if v_item.id is null then
    raise exception '抽选条目不存在';
  end if;

  v_expire := case v_item.validity_type
    when 'month_boundary' then public.next_month_boundary_at()
    when 'days' then now() + make_interval(days => coalesce(v_item.validity_days, 0))
    when 'fixed' then v_item.valid_until
    else null
  end;

  v_status := case when v_item.item_kind = 'func_card' then 'unused' else 'posted' end;
  v_note := coalesce(p_note, '');

  insert into public.lottery_draws (
    student_id, pool_type, item_id, item_snapshot, item_kind, starlight_amount,
    period_key, source, group_name, is_group, member_ids, drawn_by, drawn_at,
    expire_at, status, note
  ) values (
    p_student_id, p_pool_type, v_item.id, to_jsonb(v_item), v_item.item_kind, v_item.starlight_amount,
    p_period_key, p_source, p_group_name, p_is_group,
    coalesce(p_member_ids, '[]'::jsonb), p_drawn_by, now(),
    v_expire, v_status, v_note
  ) returning id into v_draw_id;

  -- 星光类条目：即时入账（星光卡 +N / 扣星光 -N）
  if v_item.item_kind in ('starlight', 'starlight_penalty') then
    if p_credit_all_members and p_is_group and jsonb_typeof(coalesce(p_member_ids,'[]'::jsonb)) = 'array'
       and jsonb_array_length(p_member_ids) > 0 then
      for v_member in select * from jsonb_array_elements(p_member_ids) loop
        v_mid := (v_member #>> '{}')::uuid;
        insert into public.starlight_accounts (student_id, balance, updated_at)
        values (v_mid, v_item.starlight_amount, now())
        on conflict (student_id) do update
          set balance = public.starlight_accounts.balance + excluded.balance,
              updated_at = now();
        insert into public.starlight_logs (student_id, change_amount, source, related_draw_id,
                                           period_key, note, operator_id)
        values (v_mid, v_item.starlight_amount,
                case when v_item.item_kind = 'starlight' then 'starlight_card' else 'penalty' end,
                v_draw_id, p_period_key, '小组共担：' || v_item.title, p_drawn_by);
      end loop;
    else
      insert into public.starlight_accounts (student_id, balance, updated_at)
      values (p_student_id, v_item.starlight_amount, now())
      on conflict (student_id) do update
        set balance = public.starlight_accounts.balance + excluded.balance,
            updated_at = now();
      insert into public.starlight_logs (student_id, change_amount, source, related_draw_id,
                                         period_key, note, operator_id)
      values (p_student_id, v_item.starlight_amount,
              case when v_item.item_kind = 'starlight' then 'starlight_card' else 'penalty' end,
              v_draw_id, p_period_key, v_item.title, p_drawn_by);
    end if;
  end if;

  return v_draw_id;
end;
$$;
revoke all on function public._apply_draw(uuid, text, uuid, text, text, text, jsonb, boolean, text, uuid, boolean) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 内部：把某人某池剩余次数全部自动抽掉（月末/结算用），返回抽了几次
-- ------------------------------------------------------------
create or replace function public.auto_draw_chances(
  p_student_id uuid,
  p_pool_type  text,
  p_period_key text,
  p_source     text default 'auto'
) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_chance  public.lottery_chances;
  v_item    public.lottery_items;
  v_left    int;
  v_done    int := 0;
  v_is_group boolean;
  v_members  jsonb;
  v_group    text;
begin
  for v_chance in
    select * from public.lottery_chances
     where student_id = p_student_id and pool_type = p_pool_type
       and period_key = p_period_key and used_count < amount
     order by created_at, id
  loop
    v_left := v_chance.amount - v_chance.used_count;
    v_is_group := v_chance.chance_type = 'group_penalty';
    v_group := public.student_group(p_student_id);
    v_members := case when v_is_group
      then to_jsonb(public.group_members(v_group))
      else '[]'::jsonb end;
    while v_left > 0 loop
      v_item := public._pick_lottery_item(p_pool_type);
      if v_item.id is null then
        -- 池子为空：落"未抽中"记录，不补抽
        insert into public.lottery_draws (student_id, pool_type, item_id, item_snapshot, item_kind,
          period_key, source, group_name, is_group, member_ids, drawn_by, status, note)
        values (p_student_id, p_pool_type, null, '{}'::jsonb, 'plain_text',
          p_period_key, p_source, case when v_is_group then v_group end, v_is_group,
          v_members, null, 'void', '本期奖池为空，未抽中');
        exit;
      end if;
      perform public._apply_draw(p_student_id, p_pool_type, v_item.id, p_period_key, p_source,
                                 case when v_is_group then v_group end, v_members, v_is_group,
                                 '自动抽选', null);
      v_left := v_left - 1;
      v_done := v_done + 1;
    end loop;
    update public.lottery_chances set used_count = amount where id = v_chance.id;
  end loop;
  return v_done;
end;
$$;
revoke all on function public.auto_draw_chances(uuid, text, text, text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 抽选（学生本人；老师/执行小组可代抽）
--   小组周惩罚：由该组代表抽 1 次，全组共担（p_group_name 指定）
-- ------------------------------------------------------------
create or replace function public.draw_lottery(
  p_pool_type   text,
  p_student_id  uuid default null,
  p_group_name  text default null,
  p_count       int  default 1
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role     text := public.caller_role();
  v_target   uuid;
  v_group    text;
  v_members  jsonb;
  v_is_group boolean := false;
  v_period   text := public.current_month_key();
  v_chance   public.lottery_chances;
  v_item     public.lottery_items;
  v_left     int;
  v_ids      uuid[] := '{}';
  v_draw_id  uuid;
  v_need     int;
  v_profile  uuid;
begin
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能抽选';
  end if;
  if p_pool_type not in ('reward','penalty') then
    raise exception '奖池类型不合法';
  end if;
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;

  -- 小组周惩罚：必须有代抽权（老师/执行小组）或本组代表
  if p_group_name is not null then
    v_is_group := true;
    v_group := p_group_name;
    v_members := to_jsonb(public.group_members(v_group));
    if v_role in ('super_admin','admin','executive') then
      v_target := coalesce(p_student_id,
        (select s.id from public.students s where s.group_name = v_group order by s.created_at, s.id limit 1));
    else
      -- 周结算已由系统自动抽选；小组惩罚补抽只允许老师/执行小组
      raise exception '小组惩罚已由系统在周结算时自动抽选，如需补抽请联系老师';
    end if;
  else
    v_target := coalesce(p_student_id, public.my_student_id());
    if v_target is null then
      raise exception '请选择学生';
    end if;
    if v_role = 'student' then
      if v_target <> public.my_student_id() then
        raise exception '只能给自己抽选';
      end if;
    elsif v_role = 'group_recorder' then
      raise exception '个人抽选已收回记录员代抽权限，请学生本人抽选，或由执行小组及以上代抽';
    elsif v_role not in ('super_admin','admin','executive') then
      raise exception '没有权限抽选';
    end if;
  end if;

  v_need := greatest(coalesce(p_count, 1), 1);

  -- 小组周惩罚不需要次数（由结算触发或代表点击一次）
  if v_is_group then
    for i in 1..v_need loop
      v_item := public._pick_lottery_item('penalty');
      if v_item.id is null then
        raise exception '惩罚池暂无可抽条目';
      end if;
      v_draw_id := public._apply_draw(v_target, 'penalty', v_item.id, v_period,
        'monthly_group_penalty', v_group, v_members, true, '小组代表抽选', auth.uid());
      v_ids := v_ids || v_draw_id;
      perform public.notify_audience('all',
        '小组惩罚抽选结果',
        format('%s 抽中：%s（全组共担执行）', v_group, v_item.title),
        'lottery', 'lottery_draw', v_draw_id);
    end loop;
    perform public.write_audit('draw_group_penalty', 'lottery_draw', v_ids[1]::text,
      jsonb_build_object('group_name', v_group, 'count', v_need));
    return jsonb_build_object(
      'ok', true,
      'draws', (select coalesce(jsonb_agg(to_jsonb(d) order by d.drawn_at), '[]'::jsonb)
                  from public.lottery_draws d where d.id = any(v_ids)));
  end if;

  -- 个人抽选：消耗 lottery_chances
  v_left := v_need;
  for v_chance in
    select * from public.lottery_chances
     where student_id = v_target and pool_type = p_pool_type
       and period_key = v_period and used_count < amount
     order by created_at, id
  loop
    exit when v_left <= 0;
    while v_left > 0 and v_chance.used_count + 1 <= v_chance.amount loop
      v_item := public._pick_lottery_item(p_pool_type);
      if v_item.id is null then
        raise exception '本期奖池为空，无法抽选';
      end if;
      v_draw_id := public._apply_draw(v_target, p_pool_type, v_item.id, v_period,
        'manual', public.student_group(v_target), '[]'::jsonb, false, null, auth.uid());
      v_ids := v_ids || v_draw_id;
      v_chance.used_count := v_chance.used_count + 1;
      update public.lottery_chances set used_count = v_chance.used_count where id = v_chance.id;
      v_left := v_left - 1;
      -- 通知收件人必须是 profiles.id（notifications.recipient_id 外键指向 profiles）
      v_profile := (select p.id from public.profiles p where p.student_id = v_target limit 1);
      if v_profile is not null then
        perform public.notify(v_profile, '抽选结果',
          format('你抽中了：%s', v_item.title), 'lottery', 'lottery_draw', v_draw_id);
      end if;
    end loop;
    exit when v_left <= 0;
  end loop;

  if v_left > 0 then
    raise exception '抽选次数不足（还差 % 次）', v_left;
  end if;

  perform public.write_audit('draw_lottery', 'lottery_draw', v_ids[1]::text,
    jsonb_build_object('student_id', v_target, 'pool', p_pool_type, 'count', v_need));
  return jsonb_build_object(
    'ok', true,
    'draws', (select coalesce(jsonb_agg(to_jsonb(d) order by d.drawn_at), '[]'::jsonb)
                from public.lottery_draws d where d.id = any(v_ids)));
end;
$$;
revoke all on function public.draw_lottery(text, uuid, text, int) from public, anon, authenticated;
grant execute on function public.draw_lottery(text, uuid, text, int) to authenticated;

-- ------------------------------------------------------------
-- 次数总览（本月应得 / 已抽 / 剩余）
-- ------------------------------------------------------------
create or replace function public.list_lottery_chances(p_period_key text default null)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_period text := coalesce(nullif(p_period_key,''), public.current_month_key());
  v_target uuid;
  v_list   jsonb;
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  if v_role in ('super_admin','admin','executive') then
    v_target := null;  -- 全班
  elsif v_role = 'group_recorder' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'student_id', c.student_id, 'student_name', s.name, 'group_name', s.group_name,
             'pool_type', c.pool_type, 'chance_type', c.chance_type,
             'amount', c.amount, 'used_count', c.used_count, 'remaining', c.amount - c.used_count,
             'source_week_key', c.source_week_key) order by s.name), '[]'::jsonb)
      into v_list
      from public.lottery_chances c
      join public.students s on s.id = c.student_id
     where c.period_key = v_period and s.group_name = public.my_group_name();
    return jsonb_build_object('period_key', v_period, 'scope', 'group', 'chances', v_list);
  else
    v_target := public.my_student_id();
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', c.student_id, 'student_name', s.name, 'group_name', s.group_name,
           'pool_type', c.pool_type, 'chance_type', c.chance_type,
           'amount', c.amount, 'used_count', c.used_count, 'remaining', c.amount - c.used_count,
           'source_week_key', c.source_week_key) order by s.name, c.pool_type), '[]'::jsonb)
    into v_list
    from public.lottery_chances c
    join public.students s on s.id = c.student_id
   where c.period_key = v_period
     and (v_target is null or c.student_id = v_target);

  return jsonb_build_object('period_key', v_period, 'scope', case when v_target is null then 'all' else 'self' end, 'chances', v_list);
end;
$$;
revoke all on function public.list_lottery_chances(text) from public, anon, authenticated;
grant execute on function public.list_lottery_chances(text) to authenticated;

-- ------------------------------------------------------------
-- 抽选结果仓库
--   p_scope: self(默认) / group / all
--   p_period_key: 周/月周期键（2026-43 或 2026-10），为空表示全部周期
-- ------------------------------------------------------------
drop function if exists public.list_lottery_draws(text, text, text, int);
create or replace function public.list_lottery_draws(
  p_scope      text default null,
  p_status     text default null,
  p_pool       text default null,
  p_limit      int  default 300,
  p_period_key text default null
) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_role  text := public.caller_role();
  v_me    uuid := public.my_student_id();
  v_scope text;
  v_res   jsonb;
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  -- 未显式指定范围时按角色取默认：学生=本人、记录员=本组、其他=全班
  v_scope := coalesce(nullif(btrim(lower(coalesce(p_scope, ''))), ''),
                      case when v_role = 'student' then 'self'
                           when v_role = 'group_recorder' then 'group'
                           else 'all' end);
  if v_scope not in ('self', 'group', 'all') then
    raise exception '查看范围无效：%', p_scope;
  end if;
  -- 显式 self 时一律只看本人（含「学生兼任执行小组/记录员」的情况）
  if v_scope = 'self' and v_me is null then
    raise exception '当前账号没有绑定学生档案，无法查看「我的仓库」';
  end if;
  if v_scope = 'self' then
    select coalesce(jsonb_agg(x order by x->>'drawn_at' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'id', d.id, 'student_id', d.student_id, 'student_name', s.name,
               'group_name', coalesce(d.group_name, s.group_name),
               'pool_type', d.pool_type, 'item_snapshot', d.item_snapshot,
               'item_kind', d.item_kind, 'status', d.status,
               'is_group', d.is_group, 'member_ids', d.member_ids,
               'expire_at', d.expire_at, 'drawn_at', d.drawn_at, 'used_at', d.used_at, 'note', d.note,
               'source', d.source, 'period_key', d.period_key
             ) as x
        from public.lottery_draws d join public.students s on s.id = d.student_id
       where (d.student_id = v_me
              or (d.is_group and d.member_ids ? (v_me::text)))
         and (p_status is null or d.status = p_status)
         and (p_pool is null or d.pool_type = p_pool)
         and (p_period_key is null or d.period_key = p_period_key)
       order by d.drawn_at desc
       limit greatest(coalesce(p_limit, 300), 1)
    ) q;
  elsif v_scope = 'group' then
    select coalesce(jsonb_agg(x order by x->>'drawn_at' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'id', d.id, 'student_id', d.student_id, 'student_name', s.name,
               'group_name', coalesce(d.group_name, s.group_name),
               'pool_type', d.pool_type, 'item_snapshot', d.item_snapshot,
               'item_kind', d.item_kind, 'status', d.status,
               'is_group', d.is_group, 'member_ids', d.member_ids,
               'expire_at', d.expire_at, 'drawn_at', d.drawn_at, 'used_at', d.used_at, 'note', d.note,
               'source', d.source, 'period_key', d.period_key
             ) as x
        from public.lottery_draws d join public.students s on s.id = d.student_id
       where s.group_name = public.my_group_name()
         and (p_status is null or d.status = p_status)
         and (p_pool is null or d.pool_type = p_pool)
         and (p_period_key is null or d.period_key = p_period_key)
       order by d.drawn_at desc
       limit greatest(coalesce(p_limit, 300), 1)
    ) q;
  else
    select coalesce(jsonb_agg(x order by x->>'drawn_at' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'id', d.id, 'student_id', d.student_id, 'student_name', s.name,
               'group_name', coalesce(d.group_name, s.group_name),
               'pool_type', d.pool_type, 'item_snapshot', d.item_snapshot,
               'item_kind', d.item_kind, 'status', d.status,
               'is_group', d.is_group, 'member_ids', d.member_ids,
               'expire_at', d.expire_at, 'drawn_at', d.drawn_at, 'used_at', d.used_at, 'note', d.note,
               'source', d.source, 'period_key', d.period_key
             ) as x
        from public.lottery_draws d join public.students s on s.id = d.student_id
       where (p_status is null or d.status = p_status)
         and (p_pool is null or d.pool_type = p_pool)
         and (p_period_key is null or d.period_key = p_period_key)
       order by d.drawn_at desc
       limit greatest(coalesce(p_limit, 300), 1)
    ) q;
  end if;
  return jsonb_build_object('draws', v_res);
end;
$$;
revoke all on function public.list_lottery_draws(text, text, text, int, text) from public, anon, authenticated;
grant execute on function public.list_lottery_draws(text, text, text, int, text) to authenticated;

-- ------------------------------------------------------------
-- 卡片使用/回收登记（D11：执行小组及以上；学生不能自己标记）
--   万能卡可指定兑换卡种 p_exchange_item_id → 生成新卡
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 撤销抽选（仅未使用的功能卡；已入账星光请走星光人工调整）
-- ------------------------------------------------------------
create or replace function public.admin_void_draw(p_draw_id uuid, p_note text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_draw public.lottery_draws;
begin
  perform public.require_admin();
  select * into v_draw from public.lottery_draws where id = p_draw_id;
  if v_draw.id is null then
    raise exception '抽选记录不存在';
  end if;
  if v_draw.status <> 'unused' then
    raise exception '只有未使用的功能卡可以作废（星光类已即时入账，请用星光人工调整）';
  end if;
  update public.lottery_draws set status = 'void', note = coalesce(p_note, note) where id = p_draw_id;
  perform public.notify((select p.id from public.profiles p where p.student_id = v_draw.student_id limit 1),
    '抽选结果作废', '你的一条未使用卡片已被管理员作废。', 'lottery', 'lottery_draw', p_draw_id);
  perform public.write_audit('void_draw', 'lottery_draw', p_draw_id::text,
    jsonb_build_object('student_id', v_draw.student_id, 'title', v_draw.item_snapshot->>'title', 'note', p_note));
end;
$$;
revoke all on function public.admin_void_draw(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_void_draw(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 池子条目管理（仅 super_admin）
-- ------------------------------------------------------------
create or replace function public.admin_save_lottery_item(p_item jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id   uuid := nullif(p_item->>'id','')::uuid;
  v_row  public.lottery_items;
  v_kind text := coalesce(p_item->>'item_kind', 'plain_text');
begin
  perform public.require_super_admin();
  if coalesce(p_item->>'pool_type','') not in ('reward','penalty') then
    raise exception '奖池类型不合法';
  end if;
  if v_kind not in ('func_card','starlight','starlight_penalty','plain_text') then
    raise exception '条目类型不合法';
  end if;
  if coalesce(trim(p_item->>'title'),'') = '' then
    raise exception '请填写条目名称';
  end if;
  if coalesce((p_item->>'weight')::numeric, 1) < 0 then
    raise exception '权重不能为负';
  end if;
  if v_kind in ('starlight','starlight_penalty')
     and coalesce((p_item->>'starlight_amount')::int, 0) = 0 then
    raise exception '请填写星光数量（星光卡为正、扣星光为负）';
  end if;

  if v_id is null then
    insert into public.lottery_items (pool_type, item_kind, starlight_amount, title, description,
      weight, is_active, validity_type, validity_days, valid_until, sort_order)
    values (p_item->>'pool_type', v_kind,
      coalesce((p_item->>'starlight_amount')::int, 0), trim(p_item->>'title'),
      coalesce(p_item->>'description',''), coalesce((p_item->>'weight')::numeric, 1),
      coalesce((p_item->>'is_active')::boolean, true),
      coalesce(p_item->>'validity_type','month_boundary'),
      nullif(p_item->>'validity_days','')::int,
      nullif(p_item->>'valid_until','')::timestamptz,
      coalesce((p_item->>'sort_order')::int, 0))
    returning * into v_row;
  else
    update public.lottery_items
       set pool_type = p_item->>'pool_type',
           item_kind = v_kind,
           starlight_amount = coalesce((p_item->>'starlight_amount')::int, 0),
           title = trim(p_item->>'title'),
           description = coalesce(p_item->>'description', description),
           weight = coalesce((p_item->>'weight')::numeric, weight),
           is_active = coalesce((p_item->>'is_active')::boolean, is_active),
           validity_type = coalesce(p_item->>'validity_type', validity_type),
           validity_days = nullif(p_item->>'validity_days','')::int,
           valid_until = nullif(p_item->>'valid_until','')::timestamptz,
           sort_order = coalesce((p_item->>'sort_order')::int, sort_order)
     where id = v_id
     returning * into v_row;
    if v_row.id is null then
      raise exception '条目不存在';
    end if;
  end if;
  perform public.write_audit(case when v_id is null then 'create_lottery_item' else 'update_lottery_item' end,
    'lottery_item', v_row.id::text, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;
revoke all on function public.admin_save_lottery_item(jsonb) from public, anon, authenticated;
grant execute on function public.admin_save_lottery_item(jsonb) to authenticated;

create or replace function public.admin_delete_lottery_item(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_row public.lottery_items;
begin
  perform public.require_super_admin();
  select * into v_row from public.lottery_items where id = p_id;
  if v_row.id is null then
    raise exception '条目不存在';
  end if;
  delete from public.lottery_items where id = p_id;
  perform public.write_audit('delete_lottery_item', 'lottery_item', p_id::text, to_jsonb(v_row));
end;
$$;
revoke all on function public.admin_delete_lottery_item(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_lottery_item(uuid) to authenticated;

-- ------------------------------------------------------------
-- 过期功能卡置为已过期（结算与轮询调用）
-- ------------------------------------------------------------
create or replace function public.expire_function_cards()
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare v_count int;
begin
  update public.lottery_draws
     set status = 'expired'
   where status = 'unused' and item_kind = 'func_card'
     and expire_at is not null and expire_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.expire_function_cards() from public, anon, authenticated;


-- ------------------------------------------------------------
-- 5.2.9 小组集体抽选次数（V2.0.4）
--   周汇总：前 N 组各 1 次集体奖励抽选、后 N 组各 1 次小组惩罚抽选
--   抽选人：小组记录员（本组）/ 班主任、管理员、执行小组（任意组）
--   奖励抽中后全组每人各得一份；惩罚抽中后全组共担执行
-- ------------------------------------------------------------
drop function if exists public.list_group_chances(text);
create or replace function public.list_group_chances(p_period_key text default null, p_week_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_me     text := public.my_group_name();
  v_period text := coalesce(nullif(btrim(coalesce(p_period_key, '')), ''), public.current_month_key());
  v_week   text := nullif(btrim(coalesce(p_week_key, '')), '');
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  return jsonb_build_object(
    'period_key', v_period,
    'week_key', coalesce(v_week, public.current_week_key()),
    'scope', case when v_role in ('super_admin','admin','executive') then 'all' else 'group' end,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id,
               'group_name', c.group_name,
               'pool_type', c.pool_type,
               'chance_type', c.chance_type,
               'period_key', c.period_key,
               'source_week_key', c.source_week_key,
               'amount', c.amount,
               'used_count', c.used_count,
               'remaining', greatest(c.amount - c.used_count, 0),
               'note', c.note,
               'members_count', (select count(*) from public.students s where s.group_name = c.group_name)
             ) order by c.created_at, c.id)
        from public.lottery_group_chances c
       where c.period_key = v_period
         and (v_week is null or c.source_week_key = v_week)
         and (v_role in ('super_admin','admin','executive') or c.group_name = v_me)
    ), '[]'::jsonb)
  );
end;
$$;
revoke all on function public.list_group_chances(text, text) from public, anon, authenticated;
grant execute on function public.list_group_chances(text, text) to authenticated;

create or replace function public.draw_group_lottery(
  p_group_name text,
  p_pool_type  text default 'reward',
  p_chance_id  uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role    text := public.caller_role();
  v_group   text := nullif(btrim(coalesce(p_group_name, '')), '');
  v_chance  public.lottery_group_chances;
  v_item    public.lottery_items;
  v_members jsonb;
  v_ids     uuid[] := '{}';
  v_draw_id uuid;
  v_prof    uuid;
  v_cnt     int := 0;
  v_period  text;
begin
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能抽选';
  end if;
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  if v_group is null then
    raise exception '请选择小组';
  end if;
  if p_pool_type not in ('reward','penalty') then
    raise exception '奖池类型不合法';
  end if;

  -- V2.0.14：小组抽奖收回小组记录员/学生的代抽权限，统一由执行小组及以上操作
  if v_role not in ('system','super_admin','admin','executive') then
    raise exception '小组抽奖仅限执行小组及以上操作，请在「奖惩抽选」里选择小组由班干部抽取';
  end if;

  -- 同一小组同一奖池同一周期串行执行：多人同时点，只有最早一次写入生效
  perform pg_advisory_xact_lock(hashtext('group_draw:' || v_group || ':' || p_pool_type || ':' || public.current_month_key()));

  select * into v_chance
    from public.lottery_group_chances c
   where (p_chance_id is null or c.id = p_chance_id)
     and c.group_name = v_group
     and c.pool_type = p_pool_type
     and c.used_count < c.amount
     and c.period_key = public.current_month_key()
   order by c.created_at, c.id
   limit 1
   for update;
  if v_chance.id is null then
    -- 已经抽过（或被别的成员抢先写完）时，按最早一次为准给出明确提示
    declare
      v_earliest record;
    begin
      select d.drawn_at, coalesce(pr.name, '其他成员') as who
        into v_earliest
        from public.lottery_draws d
        left join public.profiles pr on pr.id = d.drawn_by
       where d.group_name = v_group and d.is_group
         and d.source = 'weekly_group_' || p_pool_type
         and d.period_key = public.current_month_key()
       order by d.drawn_at
       limit 1;
      if v_earliest.drawn_at is not null then
        raise exception '「%」小组本轮%抽选已由 % 于 % 完成，以最早一次写入为准',
          v_group,
          case when p_pool_type = 'reward' then '奖励' else '惩罚' end,
          v_earliest.who,
          to_char(v_earliest.drawn_at at time zone 'Asia/Shanghai', 'MM-DD HH24:MI');
      end if;
    end;
    raise exception '「%s」小组本周没有可用的%s抽选次数', v_group,
      case when p_pool_type = 'reward' then '奖励' else '惩罚' end;
  end if;

  v_period  := v_chance.period_key;
  v_members := to_jsonb(public.group_members(v_group));
  v_item    := public._pick_lottery_item(p_pool_type);

  if v_item.id is null then
    insert into public.lottery_draws (student_id, pool_type, item_id, item_snapshot, item_kind,
      period_key, source, group_name, is_group, member_ids, status, note)
    values (null, p_pool_type, null, '{}'::jsonb, 'plain_text',
      v_period, 'weekly_group_' || p_pool_type, v_group, true, v_members, 'void',
      '本期奖池为空，未抽中');
    update public.lottery_group_chances set used_count = used_count + 1 where id = v_chance.id;
    return jsonb_build_object('ok', true, 'group_name', v_group, 'empty', true, 'draws', '[]'::jsonb);
  end if;

  -- 全组每人各得一份
  for v_prof in
    select s.id from public.students s where s.group_name = v_group order by s.created_at, s.id
  loop
    v_draw_id := public._apply_draw(v_prof, p_pool_type, v_item.id, v_period,
      'weekly_group_' || p_pool_type, v_group, v_members, true,
      format('小组集体抽选（%s）', v_chance.source_week_key), auth.uid(), false);
    v_ids := v_ids || v_draw_id;
    v_cnt := v_cnt + 1;
  end loop;

  update public.lottery_group_chances
     set used_count = used_count + 1
   where id = v_chance.id;

  -- 通知全组成员
  for v_prof in
    select p.id from public.profiles p
      join public.students s on s.id = p.student_id
     where s.group_name = v_group and p.status = 'active'
  loop
    perform public.notify(v_prof, '小组集体抽选结果',
      format('你所在的「%s」小组抽中：%s', v_group, v_item.title),
      'lottery', 'lottery_draw', v_ids[1]);
  end loop;

  perform public.write_audit('draw_group_lottery', 'lottery_draw', v_ids[1]::text,
    jsonb_build_object('group_name', v_group, 'pool', p_pool_type,
      'members', v_cnt, 'item', v_item.title, 'source_week', v_chance.source_week_key));

  return jsonb_build_object(
    'ok', true,
    'group_name', v_group,
    'pool_type', p_pool_type,
    'item', to_jsonb(v_item),
    'members', v_cnt,
    'draws', (select coalesce(jsonb_agg(to_jsonb(d) order by d.drawn_at), '[]'::jsonb)
                from public.lottery_draws d where d.id = any(v_ids))
  );
end;
$$;
revoke all on function public.draw_group_lottery(text, text, uuid) from public, anon, authenticated;
grant execute on function public.draw_group_lottery(text, text, uuid) to authenticated;

-- ============================================================
-- 5.3 周/月周期作业（快照 / 结算 / 自动抽选 / 轮询 / 个人汇总）
--   全部函数幂等：同一分隔点重复调用不会重复产生数据
--   （函数体整体是一个事务，异常时自动回滚，因此“先写快照作幂等闸门”是安全的）
-- ============================================================

-- ------------------------------------------------------------
-- 周结算：写周汇总快照 + 前 N 组每人 1 次奖励次数 + 后 N 组小组级惩罚抽选
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 月结算：快照 + 奖励/惩罚次数 + 第二类 + 功能卡过期 + 未用次数自动抽选
-- ------------------------------------------------------------
create or replace function public.monthly_settle(p_boundary_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b          public.boundaries;
  v_st         public.settlements;
  v_start      timestamptz;
  v_end        timestamptz;
  v_sd         date;
  v_ed         date;
  v_month_key  text;
  v_individuals jsonb;
  v_groups     jsonb;
  v_second     jsonb;
  v_second_ids uuid[] := '{}';
  v_thr        numeric;
  v_n          int := 10;
  v_reward_thr numeric := 10;
  v_penalty_thr numeric := 5;
  v_top_n      int := 15;
  v_summary    jsonb;
  v_auto_total int := 0;
  v_cards_exp  int := 0;
  v_p          record;
  v_amt        int;
  v_forfeit    jsonb := '[]'::jsonb;
  v_reward_rows jsonb;
  v_penalty_rows jsonb;
  v_auto       int;
  v_rec_cnt    int := 0;
  v_in_progress boolean := false;
begin
  select * into v_b from public.boundaries where id = p_boundary_id;
  if v_b.id is null then
    raise exception '分隔点不存在';
  end if;
  if v_b.type <> 'month' then
    raise exception '该分隔点不是月分隔点';
  end if;

  if v_b.start_date is null then
    raise exception '该月周期缺少起始日期，请先在「设置 → 周期定义」补全';
  end if;

  -- V2.1.1：允许对「进行中」的月周期结算，结算范围截至今天；同一周期多次结算以最新一次为准
  v_in_progress := v_b.end_date is null;
  v_sd := v_b.start_date;
  v_ed := coalesce(v_b.end_date, public.bj_today()) + 1;   -- 取不含上界
  v_start := v_sd::timestamp at time zone 'Asia/Shanghai';
  v_end   := v_ed::timestamp at time zone 'Asia/Shanghai';
  v_month_key := v_b.period_key;

  select * into v_st from public.settlements
   where boundary_id = p_boundary_id and status <> 'rolled_back';
  if v_st.id is not null and v_st.status = 'done' then
    if not v_in_progress then
      return v_st.summary;                        -- 已结束的周期：幂等返回既有结算
    end if;
    -- 进行中的周期：允许重算，把上一次结算标记为回滚，并清掉上次生成的次数与抽选
    update public.settlements
       set status = 'rolled_back',
           note = coalesce(nullif(note, ''), '') || '（进行中周期重新结算覆盖）'
     where id = v_st.id;
    delete from public.lottery_draws
     where period_key = v_month_key
       and source in ('auto', 'monthly_group_penalty', 'weekly_group', 'weekly_group_reward', 'weekly_group_penalty');
    delete from public.lottery_chances where period_key = v_month_key;
    delete from public.lottery_group_chances where period_key = v_month_key;
    update public.boundaries set settled = false where id = p_boundary_id;
  end if;

  -- 维护窗口（设计：月结算期间全站只读 30 分钟）；进行中的周期结算不加维护锁，避免锁住正在录分的班级
  if not v_in_progress then
    update public.app_config
       set maintenance_until = greatest(coalesce(maintenance_until, v_b.boundary_at), v_b.boundary_at)
                               + make_interval(mins => maintenance_minutes),
           updated_at = now()
     where id = 1;
  end if;

  select coalesce((public.cfg()->>'second_class_count')::int, 10),
         coalesce((public.cfg()->>'reward_threshold')::numeric, 10),
         coalesce((public.cfg()->>'penalty_threshold')::numeric, 5),
         coalesce((public.cfg()->>'month_reward_top_n')::int, 15)
    into v_n, v_reward_thr, v_penalty_thr, v_top_n;

  insert into public.settlements (period_key, boundary_id, started_at, status, note)
  values (v_month_key, p_boundary_id, now(), 'running',
          case when v_in_progress
               then format('进行中周期结算（截至 %s）', to_char(public.bj_today(), 'YYYY-MM-DD'))
               else null end);

  -- V2.0.14：当月没有任何有效记录时只写空结算，不产生任何次数/抽选/第二类名单
  select count(*) into v_rec_cnt
    from public.records
   where status = '正常'
     and record_date >= to_char(v_sd, 'YYYY-MM-DD')
     and record_date <  to_char(v_ed, 'YYYY-MM-DD');
  if v_rec_cnt = 0 then
    v_summary := jsonb_build_object(
      'type', 'month', 'month_key', v_month_key,
      'range_start', v_start, 'range_end', (v_ed - 1),
      'groups', '[]'::jsonb, 'individuals', '[]'::jsonb,
      'second_class', '[]'::jsonb, 'second_class_count', 0,
      'reward', jsonb_build_object('rows', '[]'::jsonb, 'forfeit', '[]'::jsonb),
      'penalty', jsonb_build_object('rows', '[]'::jsonb),
      'auto_draw_count', 0, 'cards_expired', 0,
      'empty_month', true, 'in_progress', v_in_progress, 'generated_at', now());
    update public.settlements
       set status = 'done', finished_at = now(), summary = v_summary,
           second_class = '[]'::jsonb, auto_draw_count = 0
     where boundary_id = p_boundary_id and status <> 'rolled_back';
    update public.boundaries set settled = true where id = p_boundary_id;
    perform public.write_audit('monthly_settle_empty', 'boundary', p_boundary_id::text,
      jsonb_build_object('month_key', v_month_key, 'records', 0));
    return v_summary;
  end if;

  -- 个人月积分（加分 / 扣分 / 净分）
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', p.id, 'name', p.name, 'group_name', p.group_name,
           'add', p.add_total, 'ded', p.ded_total, 'net', p.net,
           'rank_add', p.rank_add, 'rank_net', p.rank_net) order by p.rank_add, p.name), '[]'::jsonb)
    into v_individuals
    from (
      select s.id, s.name, s.group_name,
             coalesce(x.add_total, 0) as add_total,
             coalesce(x.ded_total, 0) as ded_total,
             coalesce(x.add_total, 0) - coalesce(x.ded_total, 0) as net,
             rank() over (order by coalesce(x.add_total, 0) desc) as rank_add,
             rank() over (order by coalesce(x.add_total, 0) - coalesce(x.ded_total, 0)) as rank_net
        from public.students s
        left join (
          select rec.student_id,
                 sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                 sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) x on x.student_id = s.id
    ) p;

  -- 小组月积分（参考）
  select coalesce(jsonb_agg(jsonb_build_object(
           'group_name', g.group_name, 'add', g.add_total, 'ded', g.ded_total,
           'net', g.add_total - g.ded_total, 'rank', g.rnk) order by g.rnk), '[]'::jsonb)
    into v_groups
    from (
      select q.group_name,
             sum(q.add_total) as add_total,
             sum(q.ded_total) as ded_total,
             rank() over (order by sum(q.add_total) desc) as rnk
        from (
          select s.group_name,
                 coalesce(x.add_total, 0) as add_total,
                 coalesce(x.ded_total, 0) as ded_total
            from public.students s
            left join (
              select rec.student_id,
                     sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                     sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
                from public.records rec
               where rec.status = '正常'
                 and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
                 and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
               group by rec.student_id
            ) x on x.student_id = s.id
           where s.group_name is not null and s.group_name <> ''
        ) q
       group by q.group_name
    ) g;

  -- 第二类：月净积分倒数十名（并列同分一并计入）
  -- 阈值 = 倒数第 N 名那位的净分（即倒数 N 名里最高的净分），net <= 阈值 的人全部入选（含并列）
  select max(net) into v_thr from (
    select net, row_number() over (order by net asc, name) as rn
      from (
        select s.name, coalesce(x.add_total,0) - coalesce(x.ded_total,0) as net
          from public.students s
          left join (
            select rec.student_id,
                   sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                   sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
              from public.records rec
             where rec.status = '正常'
               and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
               and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
             group by rec.student_id
          ) x on x.student_id = s.id
      ) z
  ) w
   where w.rn <= greatest(coalesce(v_n, 1), 1);

  if v_thr is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'student_id', s.id, 'name', s.name, 'net', coalesce(net.net, 0)) order by coalesce(net.net,0) asc, s.name), '[]'::jsonb),
           coalesce(array_agg(s.id), array[]::uuid[])
      into v_second, v_second_ids
      from public.students s
      left join (
        select rec2.student_id,
               coalesce(sum(case when rec2.points > 0 then rec2.points else 0 end), 0)
             - coalesce(sum(case when rec2.points < 0 then abs(rec2.points) else 0 end), 0) as net
          from public.records rec2
         where rec2.status = '正常'
           and rec2.record_date >= to_char(v_sd, 'YYYY-MM-DD')
           and rec2.record_date <  to_char(v_ed, 'YYYY-MM-DD')
         group by rec2.student_id
      ) net on net.student_id = s.id
     where coalesce(net.net, 0) <= v_thr;
  else
    v_second := '[]'::jsonb;
    v_second_ids := '{}';
  end if;

  -- 奖励次数（V2.0.16 口径，用户确认）：
  --   (a) 月净积分排名前 v_top_n（默认 15）名，不论净分正负，每人 1 次 → chance_type = monthly_top15
  --   (b) 净分正分部分每满 v_reward_thr（默认 10）分追加 1 次，不足不计 → chance_type = monthly_points
  --   并列同分同名次、一并计入
  insert into public.lottery_chances (student_id, period_key, pool_type, chance_type, amount, source_week_key)
  select q.student_id, v_month_key, 'reward', 'monthly_top15', 1, ''
    from (
      select s.id as student_id,
             rank() over (order by coalesce(x.add_total,0) - coalesce(x.ded_total,0) desc) as rk
        from public.students s
        left join (
          select rec.student_id,
                 sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                 sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) x on x.student_id = s.id
    ) q
   where q.rk <= v_top_n
  on conflict (student_id, period_key, chance_type, source_week_key) do nothing;

  insert into public.lottery_chances (student_id, period_key, pool_type, chance_type, amount, source_week_key)
  select q.student_id, v_month_key, 'reward', 'monthly_points', q.amount, ''
    from (
      select s.id as student_id,
             floor(greatest(coalesce(x.add_total,0) - coalesce(x.ded_total,0), 0) / v_reward_thr)::int as amount
        from public.students s
        left join (
          select rec.student_id,
                 sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                 sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) x on x.student_id = s.id
    ) q
   where q.amount > 0
  on conflict (student_id, period_key, chance_type, source_week_key) do nothing;

  -- 惩罚次数（V2.0.16 口径，用户确认）：
  --   基础惩罚 = floor(负分绝对值 / v_penalty_thr)
  --   排名惩罚 = 名单内（月净分倒数 v_n 名，含并列）且本月奖励次数 = 0 → 追加 1 次
  --   抵消     = 基础惩罚与排名惩罚重合时自动减 1（等价于：名单内 final = max(基础, 1)）
  --   封顶     = 单人单月惩罚最多 3 次
  insert into public.lottery_chances (student_id, period_key, pool_type, chance_type, amount, source_week_key)
  select q.student_id, v_month_key, 'penalty',
         case when q.base_points > 0 then 'penalty_points' else 'second_class' end,
         q.final_amount, ''
    from (
      select a.student_id, a.base_points,
             least(
               case when a.in_list and a.reward_total = 0
                    then greatest(a.base_points, 1)
                    else a.base_points end,
               3) as final_amount
        from (
          select s.id as student_id,
                 floor(greatest(-(coalesce(x.add_total,0) - coalesce(x.ded_total,0)), 0) / v_penalty_thr)::int as base_points,
                 (s.id = any(v_second_ids)) as in_list,
                 (case when rank() over (order by coalesce(x.add_total,0) - coalesce(x.ded_total,0) desc) <= v_top_n
                       then 1 else 0 end)
                 + floor(greatest(coalesce(x.add_total,0) - coalesce(x.ded_total,0), 0) / v_reward_thr)::int as reward_total
            from public.students s
            left join (
              select rec.student_id,
                     sum(case when rec.points > 0 then rec.points else 0 end) as add_total,
                     sum(case when rec.points < 0 then abs(rec.points) else 0 end) as ded_total
                from public.records rec
               where rec.status = '正常'
                 and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
                 and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
               group by rec.student_id
            ) x on x.student_id = s.id
        ) a
    ) q
   where q.final_amount > 0
  on conflict (student_id, period_key, chance_type, source_week_key) do nothing;


  -- 功能卡过期
  v_cards_exp := public.expire_function_cards();

  -- 记录本月应得/已抽情况（供快照与 reward_forfeit 标注）
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', g.student_id, 'name', g.name,
           'amount', g.amount, 'used_before_auto', g.used,
           'remaining_before_auto', g.amount - g.used,
           'top15_bonus', g.top15_bonus, 'net_bonus', g.net_bonus) order by g.name), '[]'::jsonb)
    into v_reward_rows
    from (
      select c.student_id, s.name,
             sum(c.amount)::int as amount,
             sum(c.used_count)::int as used,
             sum(case when c.chance_type = 'monthly_top15' then c.amount else 0 end)::int as top15_bonus,
             sum(case when c.chance_type = 'monthly_points' then c.amount else 0 end)::int as net_bonus
        from public.lottery_chances c join public.students s on s.id = c.student_id
       where c.period_key = v_month_key and c.pool_type = 'reward'
       group by c.student_id, s.name
    ) g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', g.student_id, 'name', g.name, 'chance_type', g.chance_type,
           'amount', g.amount, 'base_amount', g.base_amount, 'rank_amount', g.rank_amount,
           'in_list', g.in_list,
           'used_before_auto', g.used,
           'remaining_before_auto', g.amount - g.used) order by g.name), '[]'::jsonb)
    into v_penalty_rows
    from (
      select c.student_id, s.name,
             min(c.chance_type) as chance_type,
             sum(c.amount)::int as amount,
             sum(case when c.chance_type = 'penalty_points' then c.amount else 0 end)::int as base_amount,
             sum(case when c.chance_type = 'second_class' then c.amount else 0 end)::int as rank_amount,
             (s.id = any(v_second_ids)) as in_list,
             sum(c.used_count)::int as used
        from public.lottery_chances c join public.students s on s.id = c.student_id
       where c.period_key = v_month_key and c.pool_type = 'penalty'
       group by c.student_id, s.name, s.id
    ) g;

  -- 第二类学生未使用的奖励次数：账面标 reward_forfeit（结果照常自动抽、不追回）
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', g.student_id, 'name', g.name,
           'remaining', g.remaining, 'reward_forfeit', true) order by g.name), '[]'::jsonb)
    into v_forfeit
    from (
      select c.student_id, s.name, sum(c.amount - c.used_count)::int as remaining
        from public.lottery_chances c join public.students s on s.id = c.student_id
       where c.period_key = v_month_key and c.pool_type = 'reward'
         and c.used_count < c.amount
         and c.student_id = any(v_second_ids)
       group by c.student_id, s.name
    ) g
   where true;

  -- 未用次数自动抽选（奖励池 + 惩罚池）
  for v_p in
    select distinct c.student_id from public.lottery_chances c
     where c.period_key = v_month_key and c.used_count < c.amount
  loop
    v_auto := public.auto_draw_chances(v_p.student_id, 'reward', v_month_key, 'auto');
    v_auto_total := v_auto_total + v_auto;
    v_auto := public.auto_draw_chances(v_p.student_id, 'penalty', v_month_key, 'auto');
    v_auto_total := v_auto_total + v_auto;
  end loop;

  v_summary := jsonb_build_object(
    'type', 'month',
    'month_key', v_month_key,
    'range_start', v_start,
    'range_end', (v_ed - 1),
    'groups', v_groups,
    'individuals', v_individuals,
    'second_class', v_second,
    'second_class_count', jsonb_array_length(v_second),
    'reward', jsonb_build_object('rows', v_reward_rows, 'forfeit', v_forfeit),
    'penalty', jsonb_build_object('rows', v_penalty_rows),
    'auto_draw_count', v_auto_total,
    'cards_expired', v_cards_exp,
    'in_progress', v_in_progress,
    'generated_at', now()
  );

  update public.settlements
     set status = 'done', finished_at = now(), summary = v_summary,
         second_class = v_second, auto_draw_count = v_auto_total
   where boundary_id = p_boundary_id and status <> 'rolled_back';
  update public.boundaries set settled = true where id = p_boundary_id;

  perform public.notify_audience('admins', '月度结算完成',
    format('%s %s：第二类 %s 人，自动抽选 %s 次，过期功能卡 %s 张。请核对汇总。',
           v_month_key, case when v_in_progress then '周期进行中结算完成' else '月结算完成' end,
           jsonb_array_length(v_second), v_auto_total, v_cards_exp),
    'period', 'settlement', (select id from public.settlements
                              where boundary_id = p_boundary_id and status <> 'rolled_back' limit 1));
  perform public.write_audit('monthly_settle', 'boundary', p_boundary_id::text,
    jsonb_build_object('month_key', v_month_key, 'penalty_rank_list', jsonb_array_length(v_second),
                       'auto_draw_count', v_auto_total, 'cards_expired', v_cards_exp,
                       'in_progress', v_in_progress));
  return v_summary;
end;
$$;
revoke all on function public.monthly_settle(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 轮询作业入口（pg_cron 每 10 分钟；也可管理员手动触发）
-- ------------------------------------------------------------
create or replace function public.maybe_run_period_jobs()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b       public.boundaries;
  v_results jsonb := '[]'::jsonb;
  v_one     jsonb;
  v_ok      int := 0;
  v_fail    int := 0;
begin
  -- 只有系统定时任务（pg_cron / SQL Editor）或管理员可手动触发，避免学生误触
  if public.caller_role() not in ('system', 'super_admin', 'admin') then
    raise exception '只有管理员或系统定时任务可以执行周期作业';
  end if;

  perform pg_advisory_xact_lock(hashtext('banji_period_jobs'));

  for v_b in
    select * from public.boundaries
     where settled = false and boundary_at <= now()
     order by boundary_at,
              case type when 'week' then 0 when 'rule_update' then 1 else 2 end
     limit 20
  loop
    begin
      if v_b.type = 'week' then
        v_one := public.weekly_snapshot(v_b.id);
      elsif v_b.type = 'month' then
        v_one := public.monthly_settle(v_b.id);
      else
        update public.boundaries set settled = true where id = v_b.id;
        v_one := jsonb_build_object('type', 'rule_update', 'boundary_id', v_b.id,
                                    'note', '规则周期重置点，仅作计数边界');
      end if;
      v_ok := v_ok + 1;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'boundary_id', v_b.id, 'type', v_b.type, 'period_key', v_b.period_key, 'ok', true));
    exception when others then
      v_fail := v_fail + 1;
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'boundary_id', v_b.id, 'type', v_b.type, 'period_key', v_b.period_key,
        'ok', false, 'error', sqlerrm));
      if v_b.type = 'month' then
        update public.settlements set status = 'failed', note = sqlerrm
         where boundary_id = v_b.id and status = 'running';
      end if;
      perform public.write_audit('period_job_failed', 'boundary', v_b.id::text,
        jsonb_build_object('type', v_b.type, 'error', sqlerrm));
    end;
  end loop;

  return jsonb_build_object('ok_count', v_ok, 'fail_count', v_fail, 'results', v_results);
end;
$$;
revoke all on function public.maybe_run_period_jobs() from public, anon, authenticated;
grant execute on function public.maybe_run_period_jobs() to authenticated;

-- ------------------------------------------------------------
-- E4 结算运维：失败/未完成结算的重跑（已完成不自动重算，避免动历史）
-- ------------------------------------------------------------
create or replace function public.admin_resettle(p_boundary_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b  public.boundaries;
  v_st public.settlements;
  v_month_key text;
begin
  perform public.require_super_admin();
  select * into v_b from public.boundaries where id = p_boundary_id;
  if v_b.id is null then
    raise exception '分隔点不存在';
  end if;
  if v_b.type <> 'month' then
    raise exception '仅支持重跑月结算；周汇总重算请等待后续版本或联系维护';
  end if;
  select * into v_st from public.settlements
   where boundary_id = p_boundary_id and status <> 'rolled_back';
  if v_st.id is not null and v_st.status = 'done' then
    raise exception '该月已结算完成，不能自动重算（历史快照与抽选结果不可追改）';
  end if;

  v_month_key := v_b.period_key;

  -- 清理上次失败的半成品（只清理本结算点产生的自动数据与次数）
  delete from public.lottery_draws
   where period_key = v_month_key and source in ('auto','monthly_group_penalty','weekly_group','weekly_group_reward','weekly_group_penalty');
  delete from public.lottery_chances where period_key = v_month_key;
  if v_st.id is not null then
    update public.settlements set status = 'rolled_back', note = '管理员重跑'
     where id = v_st.id;
  end if;

  perform public.write_audit('resettle', 'boundary', p_boundary_id::text,
    jsonb_build_object('month_key', v_month_key, 'previous_status', v_st.status));
  return public.monthly_settle(p_boundary_id);
end;
$$;
revoke all on function public.admin_resettle(uuid) from public, anon, authenticated;
grant execute on function public.admin_resettle(uuid) to authenticated;

-- ------------------------------------------------------------
-- 周汇总列表（老师/记录员/学生按范围）
-- ------------------------------------------------------------
create or replace function public.list_weekly_summaries(p_limit int default 12)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_res  jsonb;
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  if v_role = 'student' then
    select coalesce(jsonb_agg(x order by x->>'range_end' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'period_key', w.period_key,
               'range_start', w.range_start,
               'range_end', w.range_end,
               'me', (select e from jsonb_array_elements(coalesce(w.summary->'individuals','[]'::jsonb)) e
                       where (e->>'student_id') = public.my_student_id()::text limit 1),
               'starlight_me', (select e from jsonb_array_elements(coalesce(w.summary->'starlight_individuals','[]'::jsonb)) e
                       where (e->>'student_id') = public.my_student_id()::text limit 1)
             ) as x
        from public.weekly_summaries w
       order by w.range_end desc
       limit greatest(coalesce(p_limit,12),1)
    ) q;
  else
    select coalesce(jsonb_agg(x order by x->>'range_end' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'period_key', w.period_key,
               'range_start', w.range_start,
               'range_end', w.range_end,
               'summary', w.summary
             ) as x
        from public.weekly_summaries w
       order by w.range_end desc
       limit greatest(coalesce(p_limit,12),1)
    ) q;
  end if;
  return jsonb_build_object('items', v_res);
end;
$$;
revoke all on function public.list_weekly_summaries(int) from public, anon, authenticated;
grant execute on function public.list_weekly_summaries(int) to authenticated;

-- ------------------------------------------------------------
-- 我的周/月汇总（学生只看自己；老师/记录员看全班/本组）
-- ------------------------------------------------------------
create or replace function public.my_summaries(
  p_type  text default 'month',
  p_limit int  default 6
) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_res  jsonb;
  v_me   uuid := public.my_student_id();
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  if p_type not in ('week','month') then
    raise exception '汇总类型不合法';
  end if;

  if p_type = 'week' then
    if v_role = 'student' then
      select coalesce(jsonb_agg(x order by x->>'range_end' desc), '[]'::jsonb) into v_res from (
        select jsonb_build_object(
                 'period_key', w.period_key, 'range_start', w.range_start, 'range_end', w.range_end,
                 'me', (select e from jsonb_array_elements(coalesce(w.summary->'individuals','[]'::jsonb)) e
                         where (e->>'student_id') = v_me::text limit 1),
                 'groups', w.summary->'groups',
                 'reward_groups', w.summary->'reward_groups',
                 'starlight_me', (select e from jsonb_array_elements(coalesce(w.summary->'starlight_individuals','[]'::jsonb)) e
                         where (e->>'student_id') = v_me::text limit 1)
               ) as x
          from public.weekly_summaries w
         order by w.range_end desc limit greatest(coalesce(p_limit,6),1)
      ) q;
    else
      select coalesce(jsonb_agg(x order by x->>'range_end' desc), '[]'::jsonb) into v_res from (
        select jsonb_build_object(
                 'period_key', w.period_key, 'range_start', w.range_start, 'range_end', w.range_end,
                 'summary', w.summary) as x
          from public.weekly_summaries w
         order by w.range_end desc limit greatest(coalesce(p_limit,6),1)
      ) q;
    end if;
    return jsonb_build_object('type', 'week', 'items', v_res);
  end if;

  if v_role = 'student' then
    select coalesce(jsonb_agg(x order by x->>'range_end' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'period_key', s.period_key, 'range_start', s.summary->'range_start',
               'range_end', s.summary->'range_end',
               'me', (select e from jsonb_array_elements(coalesce(s.summary->'individuals','[]'::jsonb)) e
                       where (e->>'student_id') = v_me::text limit 1),
               'second_class', (select e from jsonb_array_elements(coalesce(s.summary->'second_class','[]'::jsonb)) e
                       where (e->>'student_id') = v_me::text limit 1),
               'reward', (select e from jsonb_array_elements(coalesce(s.summary->'reward'->'rows','[]'::jsonb)) e
                       where (e->>'student_id') = v_me::text limit 1),
               'penalty', (select e from jsonb_array_elements(coalesce(s.summary->'penalty'->'rows','[]'::jsonb)) e
                       where (e->>'student_id') = v_me::text limit 1),
               'reward_forfeit', (select e from jsonb_array_elements(coalesce(s.summary->'reward'->'forfeit','[]'::jsonb)) e
                       where (e->>'student_id') = v_me::text limit 1)
             ) as x
        from public.settlements s
       where s.status = 'done'
       order by s.finished_at desc limit greatest(coalesce(p_limit,6),1)
    ) q;
  else
    select coalesce(jsonb_agg(x order by x->>'period_key' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'period_key', s.period_key,
               'range_start', s.summary->'range_start',
               'range_end', s.summary->'range_end',
               'summary', s.summary) as x
        from public.settlements s
       where s.status = 'done'
       order by s.finished_at desc limit greatest(coalesce(p_limit,6),1)
    ) q;
  end if;
  return jsonb_build_object('type', 'month', 'items', v_res);
end;
$$;
revoke all on function public.my_summaries(text, int) from public, anon, authenticated;
grant execute on function public.my_summaries(text, int) to authenticated;

-- ============================================================
-- 54. 账号 RPC（五级角色 / 批量建号 / 自助注册 / 审核 / 状态 / 角色 / 改密 / 日志）
--   依赖：10_extensions(pgcrypto)、20_tables、30_helpers
--   约定：全部 security definer + 固定 search_path；
--         权限只走 public.require_role() / public.caller_role()
--         （SQL Editor / pg_cron 的 system 调用由 require_role 自动放行）；
--         每个函数末尾统一 revoke public/anon/authenticated，再按需 grant authenticated
--         （student_register 额外 grant 给 anon）。
--   分区：
--     54.1 账号创建 / 删除 / 批量建号
--     54.2 学生自助注册与审核
--     54.3 账号状态 / 角色 / 密码重置
--     54.4 自助改密 / 账号列表 / 登录日志
-- ============================================================

-- ============================================================
-- 54.1 账号创建 / 删除 / 批量建号
-- ============================================================

-- 创建用户（保留 V1.6 五参数签名）
--   A1/A8：super_admin 可创建任意五级角色；admin 只能创建 student；
--   system（SQL Editor / 种子数据）放行；
--   用户名已存在返回 null（保留 V1 幂等语义，供 schema 重复执行）。
create or replace function public.admin_create_user(
  p_username text,
  p_password text,
  p_name     text,
  p_role     text,
  p_group    text,
  p_force_change boolean default true
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller     text := public.caller_role();
  v_username   text := lower(btrim(coalesce(p_username, '')));
  v_name       text := btrim(coalesce(p_name, ''));
  v_group      text := nullif(btrim(coalesce(p_group, '')), '');
  v_email      text;
  v_id         uuid;
  v_student    public.students;
  v_student_id uuid;
  v_force      boolean := coalesce(p_force_change, true);
begin
  perform public.require_role(array['super_admin','admin']);

  if v_username = '' or p_password is null or btrim(p_password) = '' or v_name = '' then
    raise exception '请填写完整信息';
  end if;
  if char_length(p_password) < 6 then
    raise exception '密码长度至少 6 位';
  end if;
  if p_role is null or p_role not in ('super_admin','admin','executive','group_recorder','student') then
    raise exception '角色无效：%', coalesce(p_role, '');
  end if;
  -- A1/A8：老师与管理员账号只能由 super_admin 创建；admin 只能建学生账号
  if v_caller = 'admin' and p_role <> 'student' then
    raise exception '班主任只能创建学生账号';
  end if;

  -- 幂等：用户名已存在直接返回 null
  if exists (select 1 from public.profiles p where lower(p.username) = v_username) then
    return null;
  end if;

  if position('@' in v_username) > 0 then
    v_email := v_username;
  else
    v_email := v_username || '@banji.local';
  end if;
  if exists (select 1 from auth.users u where lower(u.email) = v_email) then
    raise exception '该邮箱已被占用，请更换用户名';
  end if;

  if p_role = 'student' then
    -- 学生角色必须绑定学生档案（用户名=学号）
    if position('@' in v_username) > 0 then
      raise exception '学生账号用户名必须为学号';
    end if;
    select s.* into v_student
      from public.students s
     where lower(btrim(coalesce(s.student_no, ''))) = v_username
     order by s.created_at, s.id
     limit 1;
    if not found then
      raise exception '该学号没有对应的学生档案，请先导入学生名单或使用批量建号';
    end if;
    if v_student.user_id is not null then
      raise exception '该学生已绑定登录账号';
    end if;
    if exists (select 1 from public.profiles p where p.student_id = v_student.id) then
      raise exception '该学生已绑定登录账号';
    end if;
    v_student_id := v_student.id;
    v_group := v_student.group_name;
  else
    v_student_id := null;
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    is_sso_user, is_anonymous
  ) values (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(), 'authenticated', 'authenticated', v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('provider','email','providers', jsonb_build_array('email'),
                       'role', p_role, 'group_name', coalesce(v_group,''), 'name', v_name),
    jsonb_build_object('name', v_name, 'role', p_role, 'group_name', coalesce(v_group,'')),
    '', '', '', '',
    false, false
  ) returning id into v_id;

  insert into public.profiles (id, username, name, role, group_name, student_id, status, must_change_password)
  values (v_id, v_username, v_name, p_role, v_group, v_student_id, 'active', v_force);

  if v_student_id is not null then
    update public.students set user_id = v_id where id = v_student_id;
  end if;

  perform public.write_audit('admin_create_user', 'profile', v_id::text,
    jsonb_build_object('username', v_username, 'role', p_role,
                       'group_name', coalesce(v_group, ''), 'student_id', v_student_id,
                       'force_change', v_force));

  return jsonb_build_object(
    'id', v_id,
    'username', v_username,
    'name', v_name,
    'role', p_role,
    'group_name', coalesce(v_group, ''),
    'student_id', v_student_id,
    'must_change_password', v_force
  );
end;
$$;
revoke all on function public.admin_create_user(text,text,text,text,text,boolean) from public, anon, authenticated;
grant execute on function public.admin_create_user(text,text,text,text,text,boolean) to authenticated;

-- 修改用户密码（保留 V1.6 签名；V2 仅 super_admin，A2）
create or replace function public.admin_set_password(p_id uuid, p_password text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_username text;
begin
  perform public.require_role(array['super_admin']);

  if p_id is null then
    raise exception '请选择用户';
  end if;
  if p_password is null or btrim(p_password) = '' then
    raise exception '请输入新密码';
  end if;
  if char_length(p_password) < 6 then
    raise exception '密码长度至少 6 位';
  end if;

  select p.username into v_username from public.profiles p where p.id = p_id;
  if not found then
    raise exception '用户不存在';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = p_id;

  update public.profiles
     set updated_at = now()
   where id = p_id;

  perform public.write_audit('admin_set_password', 'profile', p_id::text,
    jsonb_build_object('username', v_username));
end;
$$;
revoke all on function public.admin_set_password(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_set_password(uuid,text) to authenticated;

-- 删除用户（A1，仅 super_admin；不能删除自己；保留学生档案）
create or replace function public.admin_delete_user(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_username text;
  v_role     text;
begin
  perform public.require_role(array['super_admin']);

  if p_id is null then
    raise exception '请选择用户';
  end if;
  if auth.uid() is not null and p_id = auth.uid() then
    raise exception '不能删除当前登录用户';
  end if;

  -- 用户不存在则直接返回（幂等）
  if not exists (select 1 from auth.users u where u.id = p_id) then
    return;
  end if;

  select p.username, p.role into v_username, v_role
    from public.profiles p where p.id = p_id;

  -- 删除前解除学生绑定，学生档案保留
  update public.students set user_id = null where user_id = p_id;

  perform public.write_audit('admin_delete_user', 'profile', p_id::text,
    jsonb_build_object('username', v_username, 'role', v_role));

  delete from auth.users where id = p_id;
end;
$$;
revoke all on function public.admin_delete_user(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- 批量创建学生账号（A3：super_admin / admin）
--   为 user_id 为空且有学号的学生建号：用户名=学号，初始密码=参数或配置默认值；
--   双向绑定 profiles.student_id / students.user_id，must_change_password=true。
create or replace function public.admin_batch_create_students(
  p_password     text default null,
  p_force_change boolean default true
)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg      jsonb;
  v_pwd      text;
  v_force    boolean := coalesce(p_force_change, true);
  v_created  int := 0;
  v_skipped  jsonb := '[]'::jsonb;
  v_failed   jsonb := '[]'::jsonb;
  v_dup_nos  text[];
  v_id       uuid;
  v_no       text;
  v_email    text;
  r          record;
begin
  perform public.require_role(array['super_admin','admin']);

  v_cfg := public.cfg();
  if p_password is not null and btrim(p_password) <> '' then
    v_pwd := p_password;
  else
    v_pwd := coalesce(
      nullif(btrim(coalesce(v_cfg->>'default_student_password', '')), ''),
      '123456'
    );
  end if;
  if char_length(v_pwd) < 6 then
    raise exception '密码长度至少 6 位';
  end if;

  -- 预统计“未绑定学生中的重复学号”（重复学号一律跳过，避免绑错人）
  select coalesce(array_agg(t.no), array[]::text[])
    into v_dup_nos
    from (
      select lower(btrim(s.student_no)) as no
        from public.students s
       where s.user_id is null
         and btrim(coalesce(s.student_no, '')) <> ''
       group by 1
      having count(*) > 1
    ) t;

  for r in
    select s.id, s.name, s.student_no, s.group_name
      from public.students s
     where s.user_id is null
     order by s.student_no nulls last, s.created_at, s.id
  loop
    v_no := lower(btrim(coalesce(r.student_no, '')));

    if v_no = '' then
      v_skipped := v_skipped || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', '无学号');
      continue;
    end if;

    if v_no = any(v_dup_nos) then
      v_skipped := v_skipped || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', '学号重复');
      continue;
    end if;

    if exists (select 1 from public.profiles p where lower(p.username) = v_no) then
      v_skipped := v_skipped || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', '已存在账号');
      continue;
    end if;

    if exists (select 1 from public.profiles p where p.student_id = r.id) then
      v_skipped := v_skipped || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', '已存在账号');
      continue;
    end if;

    v_email := v_no || '@banji.local';
    if exists (select 1 from auth.users u where lower(u.email) = v_email) then
      v_skipped := v_skipped || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', '邮箱冲突');
      continue;
    end if;

    begin
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, created_at, updated_at,
        raw_app_meta_data, raw_user_meta_data,
        confirmation_token, recovery_token, email_change_token_new, email_change,
        is_sso_user, is_anonymous
      ) values (
        '00000000-0000-0000-0000-000000000000',
        gen_random_uuid(), 'authenticated', 'authenticated', v_email,
        extensions.crypt(v_pwd, extensions.gen_salt('bf')),
        now(), now(), now(),
        jsonb_build_object('provider','email','providers', jsonb_build_array('email'),
                           'role', 'student', 'group_name', coalesce(r.group_name,''), 'name', r.name),
        jsonb_build_object('name', r.name, 'role', 'student', 'group_name', coalesce(r.group_name,'')),
        '', '', '', '',
        false, false
      ) returning id into v_id;

      insert into public.profiles (id, username, name, role, group_name, student_id, status, must_change_password)
      values (v_id, v_no, r.name, 'student', r.group_name, r.id, 'active', v_force);

      update public.students set user_id = v_id where id = r.id;

      v_created := v_created + 1;
    exception when others then
      v_id := null;
      v_failed := v_failed || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', sqlerrm);
    end;
  end loop;

  perform public.write_audit('admin_batch_create_students', 'profile', '',
    jsonb_build_object('created', v_created,
                       'skipped', jsonb_array_length(v_skipped),
                       'failed', jsonb_array_length(v_failed),
                       'force_change', v_force));

  perform public.notify_audience('admins', '学生批量建号完成',
    format('本次新建 %s 个学生账号，跳过 %s 个，失败 %s 个。初始密码已按配置设置，%s。',
           v_created, jsonb_array_length(v_skipped), jsonb_array_length(v_failed),
           case when v_force then '首次登录需修改密码' else '不强制修改密码' end));

  return jsonb_build_object(
    'created', v_created,
    'skipped', v_skipped,
    'failed', v_failed,
    'default_password', v_pwd,
    'must_change_password', v_force
  );
end;
$$;
revoke all on function public.admin_batch_create_students(text,boolean) from public, anon, authenticated;
grant execute on function public.admin_batch_create_students(text,boolean) to authenticated;

-- ============================================================
-- 54.2 学生自助注册与审核
-- ============================================================

-- 学生自助注册（公开可调，无需登录；仅校验邀请码）
--   与名单匹配：按 register_policy 直接激活 / 待审核，并双向绑定；
--   与名单不匹配：置 pending、student_id 空，等待 A4 审核。
create or replace function public.student_register(
  p_code     text,
  p_no       text,
  p_name     text,
  p_password text
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg        jsonb;
  v_enabled    boolean;
  v_invite     text;
  v_code       text := lower(btrim(coalesce(p_code, '')));
  v_no         text := btrim(coalesce(p_no, ''));
  v_name       text := btrim(coalesce(p_name, ''));
  v_pwd        text := coalesce(p_password, '');
  v_username   text;
  v_email      text;
  v_status     text;
  v_msg        text;
  v_id         uuid;
  v_student_id    uuid;
  v_student_group text;
  v_bound_user    uuid;
begin
  v_cfg := public.cfg();

  -- 注册开关与邀请码（去空格、不区分大小写）
  v_enabled := coalesce((v_cfg->>'invite_enabled')::boolean, false);
  if not v_enabled then
    raise exception '自助注册已关闭，请联系老师';
  end if;
  v_invite := lower(btrim(coalesce(v_cfg->>'invite_code', '')));
  if v_invite = '' then
    raise exception '邀请码未设置，暂无法自助注册';
  end if;
  if v_code = '' or v_code <> v_invite then
    raise exception '邀请码错误';
  end if;

  if char_length(v_pwd) < 6 then
    raise exception '密码长度至少 6 位';
  end if;
  if v_no = '' then
    raise exception '请填写学号';
  end if;
  if v_name = '' then
    raise exception '请填写姓名';
  end if;

  v_username := lower(v_no);

  -- 名单匹配：学号 + 姓名（均去空格后完全匹配）
  select s.id, s.group_name, s.user_id
    into v_student_id, v_student_group, v_bound_user
    from public.students s
   where lower(btrim(coalesce(s.student_no, ''))) = lower(v_no)
     and btrim(s.name) = v_name
   order by s.created_at, s.id
   limit 1;

  if found then
    if v_bound_user is not null then
      raise exception '该学号已注册';
    end if;
    if exists (select 1 from public.profiles p where p.student_id = v_student_id) then
      raise exception '该学号已注册';
    end if;
  else
    -- 名单外：等待审核
    v_student_id := null;
    v_student_group := null;
  end if;

  if exists (select 1 from public.profiles p where lower(p.username) = v_username) then
    raise exception '该学号已注册';
  end if;

  v_email := v_username || '@banji.local';
  if exists (select 1 from auth.users u where lower(u.email) = v_email) then
    raise exception '该学号已注册';
  end if;

  -- 匹配到名单且策略为 auto 才直接激活，否则待审核
  if v_student_id is not null
     and coalesce(v_cfg->>'register_policy', 'review') = 'auto' then
    v_status := 'active';
    v_msg := '注册成功，请使用学号和新密码登录';
  else
    v_status := 'pending';
    v_msg := '注册已提交，请等待老师审核';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    is_sso_user, is_anonymous
  ) values (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(), 'authenticated', 'authenticated', v_email,
    extensions.crypt(v_pwd, extensions.gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('provider','email','providers', jsonb_build_array('email'),
                       'role', 'student', 'group_name', coalesce(v_student_group,''), 'name', v_name),
    jsonb_build_object('name', v_name, 'role', 'student', 'group_name', coalesce(v_student_group,'')),
    '', '', '', '',
    false, false
  ) returning id into v_id;

  insert into public.profiles (id, username, name, role, group_name, student_id, status, must_change_password)
  values (v_id, v_username, v_name, 'student',
          case when v_student_id is not null then v_student_group else null end,
          v_student_id, v_status, false);

  if v_student_id is not null then
    update public.students set user_id = v_id where id = v_student_id;
  end if;

  if v_status = 'pending' then
    perform public.notify_audience('admins', '有新的学生注册待审核',
      format('学生 %s（学号 %s）提交了注册申请，请及时审核。', v_name, v_no),
      'system', 'profile', v_id);
  end if;

  perform public.write_audit('student_register', 'profile', v_id::text,
    jsonb_build_object('username', v_username, 'name', v_name, 'student_no', v_no,
                       'status', v_status, 'matched', v_student_id is not null));

  return jsonb_build_object('status', v_status, 'message', v_msg);
end;
$$;
revoke all on function public.student_register(text,text,text,text) from public, anon, authenticated;
grant execute on function public.student_register(text,text,text,text) to anon;
grant execute on function public.student_register(text,text,text,text) to authenticated;

-- 学生注册审核（A4：super_admin / admin）
--   approve：pending → active，profile.student_id 为空时按 username=学号尝试绑定；
--   reject ：pending → disabled，并解除学生绑定。
create or replace function public.admin_review_student(p_id uuid, p_approve boolean)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_profile    public.profiles;
  v_student    public.students;
  v_sid        uuid;
  v_bind_group text;
  v_new_status text;
  v_msg        text;
begin
  perform public.require_role(array['super_admin','admin']);

  if p_id is null then
    raise exception '请选择待审核账号';
  end if;
  if p_approve is null then
    raise exception '请指定审核结果';
  end if;

  select p.* into v_profile from public.profiles p where p.id = p_id;
  if not found then
    raise exception '用户不存在';
  end if;
  if v_profile.role <> 'student' then
    raise exception '该账号不是学生账号';
  end if;
  if v_profile.status <> 'pending' then
    raise exception '该账号当前不是待审核状态';
  end if;

  if p_approve then
    v_sid := v_profile.student_id;
    if v_sid is null then
      -- 按 username=学号 尝试匹配名单
      select s.* into v_student
        from public.students s
       where lower(btrim(coalesce(s.student_no, ''))) = lower(v_profile.username)
       order by s.created_at, s.id
       limit 1;
      if found then
        if v_student.user_id is not null and v_student.user_id <> p_id then
          raise exception '该学号已绑定其他账号，无法通过审核';
        end if;
        if exists (select 1 from public.profiles p
                    where p.student_id = v_student.id and p.id <> p_id) then
          raise exception '该学生已绑定其他账号，无法通过审核';
        end if;
        v_sid := v_student.id;
        v_bind_group := v_student.group_name;
        update public.students set user_id = p_id where id = v_sid;
      end if;
    end if;

    update public.profiles
       set status = 'active', student_id = v_sid,
           group_name = coalesce(v_bind_group, group_name),
           updated_at = now()
     where id = p_id;

    v_new_status := 'active';
    v_msg := '已通过注册审核';
    perform public.notify(p_id, '注册审核通过', '您的账号已通过审核，现在可以登录使用了。');
  else
    update public.profiles
       set status = 'disabled', student_id = null, group_name = null, updated_at = now()
     where id = p_id;
    update public.students set user_id = null where user_id = p_id;

    v_new_status := 'disabled';
    v_msg := '已驳回注册申请';
    perform public.notify(p_id, '注册申请被驳回', '您的注册申请未通过审核，如有疑问请联系老师。');
  end if;

  perform public.write_audit('admin_review_student', 'profile', p_id::text,
    jsonb_build_object('username', v_profile.username, 'approve', p_approve,
                       'status', v_new_status, 'student_id', v_sid));

  return jsonb_build_object('id', p_id, 'status', v_new_status, 'message', v_msg);
end;
$$;
revoke all on function public.admin_review_student(uuid,boolean) from public, anon, authenticated;
grant execute on function public.admin_review_student(uuid,boolean) to authenticated;

-- ============================================================
-- 54.3 账号状态 / 角色 / 密码重置
-- ============================================================

-- 停用/启用/锁定账号（A5：super_admin / admin；脚注¹ 班主任不能操作管理员）
create or replace function public.admin_set_user_status(p_id uuid, p_status text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_target public.profiles;
  v_from   text;
begin
  perform public.require_role(array['super_admin','admin']);

  if p_id is null then
    raise exception '请选择用户';
  end if;
  p_status := btrim(coalesce(p_status, ''));
  if p_status not in ('active','pending','disabled') then
    raise exception '账号状态值无效，仅支持 active / pending / disabled';
  end if;

  select p.* into v_target from public.profiles p where p.id = p_id;
  if not found then
    raise exception '用户不存在';
  end if;

  if auth.uid() is not null and p_id = auth.uid() and p_status <> 'active' then
    raise exception '不能停用当前登录账号';
  end if;

  -- 脚注¹：班主任不能停用/启用 super_admin、admin
  if v_caller = 'admin' and v_target.role in ('super_admin','admin') then
    raise exception '班主任不能停用或启用管理员账号';
  end if;

  v_from := v_target.status;
  if v_from = p_status then
    return;
  end if;

  update public.profiles
     set status = p_status, updated_at = now()
   where id = p_id;

  perform public.write_audit('admin_set_user_status', 'profile', p_id::text,
    jsonb_build_object('username', v_target.username, 'from', v_from, 'to', p_status));

  if p_status = 'disabled' then
    perform public.notify(p_id, '账号已停用', '您的账号已被停用，如有疑问请联系老师。');
  else
    perform public.notify(p_id, '账号状态变更',
      format('您的账号状态已变更为 %s。', p_status));
  end if;
end;
$$;
revoke all on function public.admin_set_user_status(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_set_user_status(uuid,text) to authenticated;

-- 变更用户角色（A6：super_admin / admin；脚注¹ 班主任不能授予/撤销管理员角色，也不能改管理员）
create or replace function public.admin_change_user_role(p_id uuid, p_role text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_target public.profiles;
  v_from   text;
begin
  perform public.require_role(array['super_admin','admin']);

  if p_id is null then
    raise exception '请选择用户';
  end if;
  p_role := btrim(coalesce(p_role, ''));
  if p_role not in ('super_admin','admin','executive','group_recorder','student') then
    raise exception '角色无效：%', p_role;
  end if;

  select p.* into v_target from public.profiles p where p.id = p_id;
  if not found then
    raise exception '用户不存在';
  end if;

  if auth.uid() is not null and p_id = auth.uid() then
    raise exception '不能修改当前登录账号的角色';
  end if;

  -- 脚注¹：防越权
  if v_caller = 'admin' then
    if v_target.role in ('super_admin','admin') then
      raise exception '班主任不能修改管理员账号的角色';
    end if;
    if p_role in ('super_admin','admin') then
      raise exception '班主任不能授予管理员角色';
    end if;
  end if;

  v_from := v_target.role;
  if v_from = p_role then
    return;
  end if;

  update public.profiles
     set role = p_role, updated_at = now()
   where id = p_id;

  -- 同步 auth.users.raw_app_meta_data.role（jsonb_set 保留其他键）
  update auth.users
     set raw_app_meta_data = jsonb_set(
           coalesce(raw_app_meta_data, '{}'::jsonb),
           '{role}', to_jsonb(p_role), true),
         updated_at = now()
   where id = p_id;

  perform public.write_audit('admin_change_user_role', 'profile', p_id::text,
    jsonb_build_object('username', v_target.username, 'from', v_from, 'to', p_role));

  perform public.notify(p_id, '账号角色变更',
    format('您的账号角色已由 %s 调整为 %s。', v_from, p_role));
end;
$$;
revoke all on function public.admin_change_user_role(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_change_user_role(uuid,text) to authenticated;

-- 重置用户密码（A2：仅 super_admin；未传新密码时用默认密码，置强制改密）
create or replace function public.admin_reset_password(p_id uuid, p_new_password text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_target public.profiles;
  v_pwd    text;
begin
  perform public.require_role(array['super_admin']);

  if p_id is null then
    raise exception '请选择用户';
  end if;

  select p.* into v_target from public.profiles p where p.id = p_id;
  if not found then
    raise exception '用户不存在';
  end if;

  if p_new_password is not null and btrim(p_new_password) <> '' then
    v_pwd := p_new_password;
  elsif v_target.role = 'student' then
    v_pwd := coalesce(
      nullif(btrim(coalesce(public.cfg()->>'default_student_password', '')), ''),
      '123456'
    );
  else
    v_pwd := '123456';
  end if;

  if char_length(v_pwd) < 6 then
    raise exception '密码长度至少 6 位';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(v_pwd, extensions.gen_salt('bf')),
         updated_at = now()
   where id = p_id;

  update public.profiles
     set must_change_password = true, updated_at = now()
   where id = p_id;

  perform public.write_audit('admin_reset_password', 'profile', p_id::text,
    jsonb_build_object('username', v_target.username, 'role', v_target.role));

  perform public.notify(p_id, '密码已重置',
    '管理员重置了您的登录密码，请使用新密码登录，并尽快修改为自己的密码。');
end;
$$;
revoke all on function public.admin_reset_password(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_reset_password(uuid,text) to authenticated;

-- ============================================================
-- 54.4 自助改密 / 账号列表 / 登录日志
-- ============================================================

-- 已登录用户自助改密（caller_role 不为 none/anon）
create or replace function public.change_my_password(p_old text, p_new text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid  uuid := auth.uid();
  v_role text := public.caller_role();
  v_ok   boolean;
begin
  if v_uid is null then
    raise exception '请先登录';
  end if;
  if v_role in ('none','anon') then
    raise exception '账号未激活或已停用，无法修改密码';
  end if;
  if p_new is null or char_length(p_new) < 6 then
    raise exception '密码长度至少 6 位';
  end if;

  -- 管理员（管理员/班主任）可直接修改自己的密码；其他角色必须验证旧密码
  if v_role not in ('super_admin','admin') then
    if p_old is null or p_old = '' then
      raise exception '请输入原密码';
    end if;
    select (u.encrypted_password = extensions.crypt(p_old, u.encrypted_password))
      into v_ok
      from auth.users u
     where u.id = v_uid;
    if not coalesce(v_ok, false) then
      raise exception '原密码不正确';
    end if;
  elsif p_old is not null and p_old <> '' then
    select (u.encrypted_password = extensions.crypt(p_old, u.encrypted_password))
      into v_ok
      from auth.users u
     where u.id = v_uid;
    if not coalesce(v_ok, false) then
      raise exception '原密码不正确';
    end if;
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_new, extensions.gen_salt('bf')),
         updated_at = now()
   where id = v_uid;

  update public.profiles
     set must_change_password = false, updated_at = now()
   where id = v_uid;

  perform public.write_audit('change_my_password', 'profile', v_uid::text, '{}'::jsonb);
end;
$$;
revoke all on function public.change_my_password(text,text) from public, anon, authenticated;
grant execute on function public.change_my_password(text,text) to authenticated;

-- 账号管理列表（system/super_admin 看全部；admin 看不到 super_admin；其他角色无权限）
create or replace function public.list_users(p_status text default null, p_role text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_result jsonb;
begin
  if v_caller not in ('system','super_admin','admin') then
    raise exception '没有权限执行此操作';
  end if;

  -- students 用 left join 直读（security definer，不依赖 students 的 RLS）
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', p.id,
             'username', p.username,
             'name', p.name,
             'role', p.role,
             'group_name', p.group_name,
             'status', p.status,
             'student_id', p.student_id,
             'student_no', s.student_no,
             'created_at', p.created_at,
             'must_change_password', p.must_change_password,
             'positions', to_jsonb(p.positions)
           )
           order by p.created_at desc, p.username
         ), '[]'::jsonb)
    into v_result
    from public.profiles p
    left join public.students s on s.id = p.student_id
   where (p_status is null or btrim(p_status) = '' or p.status = btrim(p_status))
     and (p_role is null or btrim(p_role) = '' or p.role = btrim(p_role))
     and (v_caller <> 'admin' or p.role <> 'super_admin');

  return v_result;
end;
$$;
revoke all on function public.list_users(text,text) from public, anon, authenticated;
grant execute on function public.list_users(text,text) to authenticated;

-- 登录日志（任意已登录用户；不抛错）
create or replace function public.log_login()
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid   uuid := auth.uid();
  v_role  text;
  v_group text;
begin
  if v_uid is null then
    return;
  end if;

  select p.role, p.group_name into v_role, v_group
    from public.profiles p
   where p.id = v_uid;
  if v_role is null then
    return;
  end if;

  perform public.write_audit('login', 'auth', v_uid::text,
    jsonb_build_object('role', v_role, 'group_name', coalesce(v_group, '')));
exception when others then
  return; -- 登录日志失败不影响登录
end;
$$;
revoke all on function public.log_login() from public, anon, authenticated;
grant execute on function public.log_login() to authenticated;

-- ============================================================
-- 5.5 通知 / 申诉 / 监督委员 / 星光台账 RPC
--     约定：全部 security definer + search_path = public, extensions；
--           权限判断只用 public.caller_role() / public.require_role()；
--           写操作留痕 public.write_audit()，通知用 public.notify() /
--           public.notify_audience()。
-- ============================================================

-- ------------------------------------------------------------
-- 5.5.1 通知信箱
-- ------------------------------------------------------------

-- 标记单条通知已读：只能操作 recipient_id = 自己 的行
create or replace function public.mark_notification_read(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_n int := 0;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder','student'],
    '没有权限执行此操作'
  );
  if p_id is null then
    raise exception '通知编号不能为空';
  end if;
  update public.notifications
     set is_read = true,
         read_at = coalesce(read_at, now())
   where id = p_id
     and recipient_id = auth.uid();
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception '通知不存在或无权操作';
  end if;
end;
$$;
revoke all on function public.mark_notification_read(uuid) from public, anon, authenticated;
grant execute on function public.mark_notification_read(uuid) to authenticated;

-- 一键全部已读：返回本次置为已读的条数
create or replace function public.mark_all_notifications_read()
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_n int := 0;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder','student'],
    '没有权限执行此操作'
  );
  update public.notifications
     set is_read = true,
         read_at = now()
   where recipient_id = auth.uid()
     and is_read = false;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.mark_all_notifications_read() from public, anon, authenticated;
grant execute on function public.mark_all_notifications_read() to authenticated;

-- D8 发布班级广播（super_admin/admin）：发给全部 active 账号
create or replace function public.admin_publish_broadcast(
  p_title    text,
  p_body     text,
  p_category text default 'broadcast'
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_sent int := 0;
  v_cat  text;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  if p_title is null or btrim(p_title) = '' then
    raise exception '请填写广播标题';
  end if;
  v_cat := coalesce(nullif(btrim(coalesce(p_category,'')), ''), 'broadcast');
  v_sent := public.notify_audience('all', btrim(p_title), coalesce(p_body,''), v_cat);
  perform public.write_audit(
    '发布班级广播',
    'notification',
    '',
    jsonb_build_object('title', p_title, 'category', v_cat, 'sent', v_sent)
  );
  return jsonb_build_object('sent', v_sent);
end;
$$;
revoke all on function public.admin_publish_broadcast(text, text, text) from public, anon, authenticated;
grant execute on function public.admin_publish_broadcast(text, text, text) to authenticated;

-- D9 删除（撤回）通知（super_admin/admin）：物理删除
create or replace function public.admin_delete_notification(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_title text;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  if p_id is null then
    raise exception '通知编号不能为空';
  end if;
  delete from public.notifications
   where id = p_id
  returning title into v_title;
  if not found then
    raise exception '通知不存在或已被删除';
  end if;
  perform public.write_audit(
    '删除通知',
    'notification',
    p_id::text,
    jsonb_build_object('title', v_title)
  );
end;
$$;
revoke all on function public.admin_delete_notification(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_notification(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5.5.2 监督委员当周指派（D15）
-- ------------------------------------------------------------

-- 指派当周监督委员：每周最多 2 名（只统计未撤销的指派）
create or replace function public.admin_assign_supervisor(p_period_key text, p_student_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_period   text;
  v_ids      uuid[];
  v_existing int := 0;
  v_total    int := 0;
  v_found    int := 0;
  v_names    text;
  v_max      int;
  v_p        record;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  v_period := coalesce(
    nullif(btrim(coalesce(p_period_key, '')), ''),
    public.current_week_key()
  );
  if p_student_ids is null or cardinality(p_student_ids) = 0 then
    raise exception '请至少选择一名学生';
  end if;
  select array_agg(distinct x) into v_ids
    from unnest(p_student_ids) as x
   where x is not null;
  if v_ids is null or cardinality(v_ids) = 0 then
    raise exception '请至少选择一名学生';
  end if;
  select count(*) into v_found from public.students where id = any(v_ids);
  if v_found <> cardinality(v_ids) then
    raise exception '部分学生不存在，请刷新名单后重试';
  end if;
  -- 本周已指派且不在本次名单中的未撤销人数
  select count(*) into v_existing
    from public.supervisor_assignments sa
   where sa.period_key = v_period
     and sa.revoked_at is null
     and not (sa.student_id = any(v_ids));
  v_total := v_existing + cardinality(v_ids);
  v_max := greatest(coalesce((public.cfg()->>'max_supervisors')::int, 2), 1);
  if v_total > v_max then
    raise exception '每周最多指派 % 名监督委员（本周已有 % 名未被撤销）', v_max, v_existing;
  end if;

  insert into public.supervisor_assignments (period_key, student_id, assigned_by)
  select v_period, x, auth.uid()
    from unnest(v_ids) as x
  on conflict (period_key, student_id) do update
     set revoked_at  = null,
         assigned_by = excluded.assigned_by;

  select string_agg(s.name, '、' order by s.name) into v_names
    from public.students s
   where s.id = any(v_ids);

  -- 通知被指派的学生本人
  for v_p in
    select p.id
      from public.profiles p
     where p.student_id = any(v_ids)
       and p.status = 'active'
  loop
    perform public.notify(
      v_p.id,
      '监督委员任命',
      format('你已被指派为 %s 周的监督委员，请协助受理本周积分申诉。', v_period),
      'system',
      'supervisor_assignment',
      null
    );
  end loop;
  -- 全班公示
  perform public.notify_audience(
    'all',
    '本周监督委员名单',
    format('本周（%s）监督委员：%s。', v_period, coalesce(v_names, '')),
    'broadcast',
    'supervisor_assignment',
    null
  );

  perform public.write_audit(
    '指派监督委员',
    'supervisor_assignment',
    v_period,
    jsonb_build_object(
      'period_key', v_period,
      'student_ids', to_jsonb(v_ids),
      'names', v_names,
      'active_count', v_total
    )
  );
  return jsonb_build_object(
    'period_key',   v_period,
    'assigned',     cardinality(v_ids),
    'active_count', v_total,
    'student_ids',  to_jsonb(v_ids)
  );
end;
$$;
revoke all on function public.admin_assign_supervisor(text, uuid[]) from public, anon, authenticated;
grant execute on function public.admin_assign_supervisor(text, uuid[]) to authenticated;

-- 撤销一条监督委员指派（置 revoked_at）
create or replace function public.admin_revoke_supervisor(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_student uuid;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  if p_id is null then
    raise exception '指派记录编号不能为空';
  end if;
  update public.supervisor_assignments
     set revoked_at = now()
   where id = p_id
     and revoked_at is null
  returning student_id into v_student;
  if not found then
    raise exception '指派记录不存在或已撤销';
  end if;
  perform public.write_audit(
    '撤销监督委员',
    'supervisor_assignment',
    p_id::text,
    jsonb_build_object('student_id', v_student)
  );
end;
$$;
revoke all on function public.admin_revoke_supervisor(uuid) from public, anon, authenticated;
grant execute on function public.admin_revoke_supervisor(uuid) to authenticated;

-- 监督委员名单（所有已激活账号可读；默认当前周）
create or replace function public.list_supervisors(p_period_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_period text;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder','student'],
    '没有权限执行此操作'
  );
  v_period := coalesce(
    nullif(btrim(coalesce(p_period_key, '')), ''),
    public.current_week_key()
  );
  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'id',           sa.id,
               'student_id',   sa.student_id,
               'student_name', s.name,
               'group_name',   s.group_name,
               'period_key',   sa.period_key,
               'assigned_at',  sa.created_at,
               'revoked_at',   sa.revoked_at
             )
             order by sa.created_at, s.name
           )
      from public.supervisor_assignments sa
      left join public.students s on s.id = sa.student_id
     where sa.period_key = v_period
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.list_supervisors(text) from public, anon, authenticated;
grant execute on function public.list_supervisors(text) to authenticated;

-- ------------------------------------------------------------
-- 5.5.3 星光值台账（D12 / D13 / D14，3.9）
-- ------------------------------------------------------------

-- 星光台账查询（公示范围按 app_config.starlight_visibility 裁剪）
--   public    ：全部已激活账号可看全班
--   self_only ：学生只看自己，老师看全班；记录员始终只看本组
create or replace function public.starlight_list(p_scope text default 'all', p_limit int default 200)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text;
  v_vis   text;
  v_scope text;
  v_limit int;
  v_me    uuid;
  v_group text;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder','student'],
    '没有权限执行此操作'
  );
  v_role  := public.caller_role();
  v_vis   := coalesce(public.cfg()->>'starlight_visibility', 'public');
  v_scope := lower(btrim(coalesce(p_scope, 'all')));
  if v_scope not in ('all','me','group') then
    raise exception '查询范围参数无效';
  end if;
  v_limit := greatest(1, least(coalesce(p_limit, 200), 1000));
  v_me    := public.my_student_id();
  v_group := coalesce(public.student_group(v_me), public.my_group_name());

  if v_role = 'student' then
    if v_vis = 'self_only' then
      v_scope := 'me';
    end if;
  elsif v_role = 'group_recorder' then
    v_scope := 'group';
  elsif v_role in ('super_admin','admin','executive') then
    if v_scope <> 'me' then
      v_scope := 'all';
    end if;
  end if;

  return (
    with base as (
      select s.id as student_id,
             s.name,
             s.group_name,
             coalesce(a.balance, 0) as balance,
             rank() over (order by coalesce(a.balance, 0) desc, s.name) as rnk
        from public.students s
        left join public.starlight_accounts a on a.student_id = s.id
    ),
    acc as (
      select b.* from base b
       where (v_scope = 'all')
          or (v_scope = 'me' and b.student_id = v_me)
          or (v_scope = 'group' and v_group is not null and b.group_name = v_group)
    ),
    lg as (
      select l.change_amount,
             l.source,
             l.note,
             l.created_at,
             l.period_key,
             s.name as student_name
        from public.starlight_logs l
        join public.students s on s.id = l.student_id
       where (v_scope = 'all')
          or (v_scope = 'me' and l.student_id = v_me)
          or (v_scope = 'group' and v_group is not null and s.group_name = v_group)
       order by l.created_at desc, l.id desc
       limit v_limit
    )
    select jsonb_build_object(
      'accounts', coalesce((
        select jsonb_agg(
                 jsonb_build_object(
                   'student_id', a.student_id,
                   'name',       a.name,
                   'group_name', a.group_name,
                   'balance',    a.balance,
                   'rank',       case when v_scope = 'all' then a.rnk else null end
                 )
                 order by a.balance desc, a.name
               )
          from acc a
      ), '[]'::jsonb),
      'logs', coalesce((
        select jsonb_agg(
                 jsonb_build_object(
                   'student_name',  g.student_name,
                   'change_amount', g.change_amount,
                   'source',        g.source,
                   'note',          g.note,
                   'created_at',    g.created_at,
                   'period_key',    g.period_key
                 )
                 order by g.created_at desc
               )
          from lg g
      ), '[]'::jsonb)
    )
  );
end;
$$;
revoke all on function public.starlight_list(text, int) from public, anon, authenticated;
grant execute on function public.starlight_list(text, int) to authenticated;

-- D13 人工调整星光值（super_admin/admin/executive），强制留痕
create or replace function public.starlight_adjust(p_student_id uuid, p_amount int, p_note text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_note    text;
  v_balance int;
begin
  perform public.require_role(array['super_admin','admin','executive'], '没有权限执行此操作');
  if p_student_id is null then
    raise exception '请选择学生';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception '调整数量不能为 0';
  end if;
  v_note := btrim(coalesce(p_note, ''));
  if v_note = '' then
    raise exception '请填写调整说明';
  end if;
  if not exists (select 1 from public.students s where s.id = p_student_id) then
    raise exception '学生不存在';
  end if;

  insert into public.starlight_accounts (student_id, balance, updated_at)
  values (p_student_id, p_amount, now())
  on conflict (student_id) do update
     set balance    = starlight_accounts.balance + excluded.balance,
         updated_at = now()
  returning balance into v_balance;

  insert into public.starlight_logs
    (student_id, change_amount, source, period_key, note, operator_id)
  values
    (p_student_id, p_amount, 'manual', public.current_month_key(), v_note, auth.uid());

  perform public.write_audit(
    '调整星光值',
    'starlight_account',
    p_student_id::text,
    jsonb_build_object(
      'change_amount', p_amount,
      'note',          v_note,
      'balance',       v_balance
    )
  );
  return jsonb_build_object(
    'student_id',    p_student_id,
    'change_amount', p_amount,
    'balance',       v_balance
  );
end;
$$;
revoke all on function public.starlight_adjust(uuid, int, text) from public, anon, authenticated;
grant execute on function public.starlight_adjust(uuid, int, text) to authenticated;

-- D14 学期星光清零（仅 super_admin）：先快照、再写清零流水、最后清零
--   注意：本系统不设学期分隔点，清零为纯手动操作，不产生周期边界。
create or replace function public.term_reset_starlight(p_term_name text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_term       text;
  v_summary    jsonb;
  v_snapshot   uuid;
  v_reset      int := 0;
  v_cfg_rows   int := 0;
begin
  perform public.require_role(array['super_admin'], '没有权限执行此操作');
  v_term := coalesce(
    nullif(btrim(coalesce(p_term_name, '')), ''),
    nullif(public.cfg()->>'term_name', ''),
    '本学期'
  );

  -- 1) 先写学期快照：每人余额 + 流水合计
  select jsonb_build_object(
           'term_name', v_term,
           'accounts', coalesce((
             select jsonb_agg(
                      jsonb_build_object(
                        'student_id',   s.id,
                        'student_name', s.name,
                        'group_name',   s.group_name,
                        'balance',      coalesce(a.balance, 0)
                      )
                      order by s.name
                    )
               from public.students s
               left join public.starlight_accounts a on a.student_id = s.id
           ), '[]'::jsonb),
           'total_balance',  coalesce((select sum(balance) from public.starlight_accounts), 0),
           'total_positive', coalesce((select sum(change_amount) from public.starlight_logs where change_amount > 0), 0),
           'total_negative', coalesce((select sum(change_amount) from public.starlight_logs where change_amount < 0), 0),
           'log_count',      (select count(*) from public.starlight_logs)
         )
    into v_summary;
  insert into public.starlight_term_snapshots (term_name, operator_id, summary)
  values (v_term, auth.uid(), v_summary)
  returning id into v_snapshot;

  -- 2) 对非零余额写 term_reset 负数流水
  insert into public.starlight_logs
    (student_id, change_amount, source, period_key, note, operator_id)
  select a.student_id,
         -a.balance,
         'term_reset',
         public.current_month_key(),
         '学期星光清零（' || v_term || '）',
         auth.uid()
    from public.starlight_accounts a
   where a.balance <> 0;
  get diagnostics v_reset = row_count;

  -- 3) 清零余额
  update public.starlight_accounts
     set balance = 0,
         updated_at = now()
   where balance <> 0;

  -- 4) 记录学期名（单行配置保留 id = 1）
  update public.app_config
     set term_name  = v_term,
         updated_at = now(),
         updated_by = auth.uid()
   where id = 1;
  get diagnostics v_cfg_rows = row_count;
  if v_cfg_rows = 0 then
    insert into public.app_config (id, term_name, updated_at, updated_by)
    values (1, v_term, now(), auth.uid());
  end if;

  perform public.write_audit(
    '学期星光清零',
    'starlight_term_snapshot',
    v_snapshot::text,
    jsonb_build_object(
      'term_name',   v_term,
      'reset_count', v_reset,
      'snapshot_id', v_snapshot
    )
  );
  return jsonb_build_object(
    'term_name',   v_term,
    'reset_count', v_reset,
    'snapshot_id', v_snapshot
  );
end;
$$;
revoke all on function public.term_reset_starlight(text) from public, anon, authenticated;
grant execute on function public.term_reset_starlight(text) to authenticated;

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

-- ============================================================
-- 7. 管理员运维：用户职务标签 / 手动汇总（覆盖重算）
-- ============================================================

-- ------------------------------------------------------------
-- 7.1 用户职务标签
-- 说明：除班主任外，执行管理/记录员等角色往往是学生兼任（团支书、班长、纪律委员……），
--       用 positions 文本数组记录这些标识，仅作展示与筛选，不参与权限判断。
-- ------------------------------------------------------------
alter table public.profiles add column if not exists positions text[] not null default '{}';

create or replace function public.admin_set_user_positions(p_id uuid, p_positions text[])
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text;
  v_arr   text[] := '{}';
  v_x     text;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  if p_id is null then
    raise exception '请选择用户';
  end if;
  select p.role into v_role from public.profiles p where p.id = p_id;
  if v_role is null then
    raise exception '用户不存在';
  end if;

  if p_positions is not null then
    foreach v_x in array p_positions loop
      v_x := btrim(coalesce(v_x, ''));
      if v_x <> '' and char_length(v_x) <= 20 and not (v_x = any(v_arr)) then
        v_arr := array_append(v_arr, v_x);
      end if;
      exit when array_length(v_arr, 1) >= 8;
    end loop;
  end if;

  update public.profiles
     set positions = v_arr,
         updated_at = now()
   where id = p_id;

  perform public.write_audit('admin_set_user_positions', 'profile', p_id::text,
    jsonb_build_object('username', (select p.username from public.profiles p where p.id = p_id),
                       'positions', to_jsonb(v_arr)));
end;
$$;
revoke all on function public.admin_set_user_positions(uuid, text[]) from public, anon, authenticated;
grant execute on function public.admin_set_user_positions(uuid, text[]) to authenticated;

-- ------------------------------------------------------------
-- 7.2 手动周汇总（覆盖重算）
-- 同一周期多次汇总：先清掉该周期已有结果，再按最新数据重新生成，保证“最新覆盖旧结果”。
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 7.3 手动月汇总（覆盖重算）
-- ------------------------------------------------------------
create or replace function public.admin_run_monthly_summary(p_boundary_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b   public.boundaries;
  v_key text;
  v_res jsonb;
begin
  perform public.require_role(array['super_admin','admin','executive'], '只有管理员、班主任或执行小组可以手动汇总');

  if p_boundary_id is null then
    -- V2.1.1：优先「进行中」的月周期（end_date 为空），否则取最近已开始的月周期
    select * into v_b from public.boundaries
     where type = 'month' and start_date is not null and end_date is null
       and start_date <= public.bj_today()
     order by start_date desc limit 1;
    if v_b.id is null then
      select * into v_b from public.boundaries
       where type = 'month' and start_date is not null and start_date <= public.bj_today()
       order by start_date desc limit 1;
    end if;
  else
    select * into v_b from public.boundaries where id = p_boundary_id;
  end if;

  if v_b.id is null then
    raise exception '没有找到可汇总的月分隔点';
  end if;
  if v_b.type <> 'month' then
    raise exception '该分隔点不是月分隔点';
  end if;
  if v_b.boundary_at is not null and v_b.boundary_at > now() then
    raise exception '该月尚未开始，不能汇总';
  end if;

  -- 月分隔点关闭的是「上一个月」，周期键按被结算的月份推导（settlements.period_key 用的是这个）
  v_key := v_b.period_key;

  -- 覆盖：旧结算记录标记为已回滚（保留审计痕迹），清掉该月已生成的次数与自动抽选
  update public.settlements
     set status = 'rolled_back',
         note = coalesce(nullif(note, ''), '') || '（手动重新汇总覆盖）'
   where boundary_id = v_b.id
     and status <> 'rolled_back';

  delete from public.lottery_draws
   where period_key = v_key
     and source in ('auto', 'monthly_group_penalty', 'weekly_group', 'weekly_group_reward', 'weekly_group_penalty');
  delete from public.lottery_chances where period_key = v_key;
  delete from public.lottery_group_chances where period_key = v_key;
  update public.boundaries set settled = false where id = v_b.id;

  v_res := public.monthly_settle(v_b.id);

  perform public.write_audit('admin_run_monthly_summary', 'boundary', v_b.id::text,
    jsonb_build_object('month_key', v_key));

  return jsonb_build_object('month_key', v_key, 'boundary_id', v_b.id,
    'in_progress', (v_b.end_date is null), 'summary', v_res);
end;
$$;
revoke all on function public.admin_run_monthly_summary(uuid) from public, anon, authenticated;
grant execute on function public.admin_run_monthly_summary(uuid) to authenticated;

-- ============================================================
-- 7.5 废弃功能清理（V2.0.4：申诉功能取消）
--   幂等：重复执行无副作用
-- ============================================================

drop function if exists public.submit_appeal(uuid, text) cascade;
drop function if exists public.list_appeals(text) cascade;
drop function if exists public.handle_appeal(uuid, boolean, text) cascade;
drop table if exists public.appeals cascade;

-- 周惩罚组数默认由 3 改为 2（只纠正旧默认值，管理员手工改过的保持原值）
update public.app_config
   set week_penalty_bottom_groups = 2
 where id = 1
   and week_penalty_bottom_groups = 3;

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
    -- 只列「已结束」的周（进行中的周还没有汇总意义）
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
           and coalesce(b.end_date, b.start_date) < public.bj_today()
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
     where type = 'week' and boundary_at <= now()
      and period_key = v_key
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

-- ============================================================
-- 6. 初始数据（全部幂等：重复执行不会重复插入）
-- ============================================================

-- ------------------------------------------------------------
-- 6.1 系统配置单行
-- ------------------------------------------------------------
insert into public.app_config (id) values (1) on conflict (id) do nothing;

-- 初始化分隔点（未来 12 个月 / 回看 6 个月）
select public.ensure_boundaries();

-- 兼容已有库：1 天以前的历史分隔点视为已结算，避免 cron 首次运行时把过去半年周期全部补结算
update public.boundaries
   set settled = true
 where settled = false
   and boundary_at <= now() - interval '1 day';

-- ------------------------------------------------------------
-- 6.2 默认积分规则（V1.6 原有 37 条，原样保留）
-- ------------------------------------------------------------
insert into public.rules (score_type, category, reason, points, sort_order)
select v.score_type, v.category, v.reason, v.points, v.sort_order
from (values
('加分','学业表现','月考/期中/期末成绩进步前三名',3,1),
('加分','学业表现','月考/期中/期末后10名较上次班排进步5名/年排进步15名及以上',2,2),
('加分','学业表现','月考/期中/期末总分前10名',2,3),
('加分','学业表现','月考/期中/期末总分10~20名',1,4),
('加分','学业表现','月考/期中/期末单科前10名',1,5),
('加分','学业表现','周测前3名',1,6),
('加分','学业表现','作业质量获老师表扬',2,7),
('加分','学业表现','主动向老师请教问题、主动整理错题本上交',2,8),
('加分','学业表现','课堂主动举手回答问题（回答正确）',1.5,9),
('加分','学业表现','课堂主动举手回答问题（回答不正确）',0.5,10),
('加分','行为规范','拾金不昧/主动帮助师生解决问题（小额物品）',2,11),
('加分','行为规范','拾金不昧/主动帮助师生解决问题（贵重物品/紧急帮扶）',5,12),
('加分','行为规范','主动承担班级事务/态度认真',2,13),
('加分','文体实践','运动会/文艺活动参赛',1,14),
('加分','文体实践','主动参与班级文化布置',2,15),
('加分','文体实践','班级活动主动报名主持/表演/分享',2,16),
('加分','文体实践','参与赛事后勤、道具搬运、班级啦啦队组织、场地清理等',1,17),
('加分','文体实践','小组积分记录员周积分',1,18),
('加分','特殊加分','提出班级管理优化建议并被采纳',5,19),
('加分','特殊加分','获得校级特长类奖项（一等奖）',3,20),
('加分','特殊加分','获得校级特长类奖项（二等奖）',2,21),
('加分','特殊加分','获得校级特长类奖项（三等奖及以下）',1,22),
('加分','特殊加分','获得市级特长类奖项（一等奖）',6,23),
('加分','特殊加分','获得市级特长类奖项（二等奖）',5,24),
('加分','特殊加分','获得市级特长类奖项（三等奖及以下）',4,25),
('加分','特殊加分','获得省级/国家级特长类奖项（一等奖）',9,26),
('加分','特殊加分','获得省级/国家级特长类奖项（二等奖）',8,27),
('加分','特殊加分','获得省级/国家级特长类奖项（三等奖及以下）',7,28),
('扣分','纪律表现','早操（课间操）迟到/无故不上早操（课间操）',-2,29),
('扣分','纪律表现','作业无故未交',-2,30),
('扣分','纪律表现','课堂被老师点名批评（讲话、睡觉）',-2,31),
('扣分','纪律表现','自习讲话/做与自习无关的事',-3,32),
('扣分','纪律表现','与同学发生冲突且负主要责任',-3,33),
('扣分','纪律表现','考试作弊',-5,34),
('扣分','纪律表现','不做眼保健操',-2,35),
('扣分','纪律表现','顶撞老师',-2,36),
('扣分','纪律表现','年级组重大违纪通报批评',-5,37)
) as v(score_type, category, reason, points, sort_order)
where not exists (
  select 1 from public.rules r
  where r.score_type = v.score_type and r.category = v.category
    and r.reason = v.reason and r.points = v.points
);

-- ------------------------------------------------------------
-- 6.3 奖励池（8 种卡，概率即权重；权重按百分比原值存储，抽选时归一化）
-- ------------------------------------------------------------
insert into public.lottery_items (pool_type, item_kind, starlight_amount, title, description,
  weight, is_active, validity_type, sort_order)
select v.pool_type, v.item_kind, v.amount, v.title, v.descr, v.weight, true, v.validity, v.sort_order
from (values
('reward','func_card',0,'指定惩罚卡','可指定任意一名同学执行 1 条惩罚（惩罚池内容随机，由执行小组登记生效）。',11,'month_boundary',1),
('reward','func_card',0,'免罚卡','免除 1 次本人应执行的惩罚（含小组共担惩罚中本人份额，由执行小组登记）。',11,'month_boundary',2),
('reward','func_card',0,'免扣分卡','免除 1 次扣分（需关联具体扣分记录编号，由执行小组登记）。',11,'month_boundary',3),
('reward','starlight',3,'3 星光卡','抽中即自动入账 +3 星光值（星光卡不入仓库）。',15,'permanent',4),
('reward','starlight',5,'5 星光卡','抽中即自动入账 +5 星光值（星光卡不入仓库）。',15,'permanent',5),
('reward','starlight',10,'10 星光卡','抽中即自动入账 +10 星光值（星光卡不入仓库）。',15,'permanent',6),
('reward','func_card',0,'免值日卡','免除 1 次值日（值日安排仍按班级线下执行，由执行小组登记确认）。',11,'month_boundary',7),
('reward','func_card',0,'万能卡','可兑换为任意 1 张其他奖励卡（由执行小组登记兑换，新卡有效期至下一个月分隔点）。',8,'month_boundary',8)
) as v(pool_type, item_kind, amount, title, descr, weight, validity, sort_order)
where not exists (
  select 1 from public.lottery_items i where i.pool_type = v.pool_type and i.title = v.title
);

-- ------------------------------------------------------------
-- 6.4 惩罚池（20 条，来自 punishments.txt，默认等概率）
--     第 12、13 条为扣星光，抽中即时扣减并写流水
-- ------------------------------------------------------------
insert into public.lottery_items (pool_type, item_kind, starlight_amount, title, description,
  weight, is_active, validity_type, sort_order)
select 'penalty', v.kind, v.amount, v.title, '', 1, true, 'permanent', v.sort_order
from (values
('plain_text',0,'绕丹阳广场跑 3 圈',1),
('plain_text',0,'负责教室全面清扫，连续2天（早中晚）',2),
('plain_text',0,'课后主动请教任课老师连续 3 天',3),
('plain_text',0,'撰写 300 字《我的行为反思与改进方向》，重点写问题成因、自身不足以及具体改进做法',4),
('plain_text',0,'帮助学困生辅导功课（向学习成绩好的同学请教），连续一周',5),
('plain_text',0,'配合班委，课后检查班级门窗、电器关闭情况并做好简单记录，连续 1 周',6),
('plain_text',0,'撰写详细的个人行为改正计划书（不少于200字）',7),
('plain_text',0,'为全班朗读一篇励志教育文章（不少于5分钟）',8),
('plain_text',0,'整理班级粉笔、板擦等教具，连续 1 周',9),
('plain_text',0,'抄写名人励志名言20条（手写）',10),
('plain_text',0,'在班会上做200字以上自我反省发言，听取大家意见',11),
('starlight_penalty',-3,'星光积分扣除3颗',12),
('starlight_penalty',-5,'星光积分扣除5颗',13),
('plain_text',0,'整理班级劳动工具并摆放整齐，连续 1 周',14),
('plain_text',0,'替班级换水，连续一周',15),
('plain_text',0,'写一封给未来自己的信，畅谈自我改正的决心',16),
('plain_text',0,'主动向被自己影响的同学真诚道歉信（不少于100字）',17),
('plain_text',0,'为班级绿植浇水养护，连续 1 个星期',18),
('plain_text',0,'协助值日生完成全部值日工作，连续1天',19),
('plain_text',0,'写出任意一个小组的所有组员的优点',20)
) as v(kind, amount, title, sort_order)
where not exists (
  select 1 from public.lottery_items i where i.pool_type = 'penalty' and i.title = v.title
);

-- ------------------------------------------------------------
-- 6.5 首次初始化：默认账号（仅当 profiles 为空时创建；线上已有账号则跳过）
--     依赖 54_accounts.sql 的 admin_create_user(p_username,p_password,p_name,p_role,p_group)
--     super_admin 说明：V2.0 的 A1/A2/A8/B1/B3/B4/B7/B8/C1 等专属权限只属于
--     超级管理员。全新空库会建一个 guanliyuan 超级管理员；已存在的线上库不会自动
--     提权任何人，迁移后用 SQL Editor 手动把指定账号提升为 super_admin（见部署说明）。
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.profiles) then
    perform public.admin_create_user('admin',       'admin123',      '班主任',  'admin',       null);
    perform public.admin_create_user('guanliyuan',  'guanliyuan123', '管理员',  'super_admin', null);
    perform public.admin_create_user('banzhang',    'banzhang123',   '班长',    'executive',   null);
    perform public.admin_create_user('tuanzhishu',  'tuanzhishu123', '团支书',  'executive',   null);
  end if;
end $$;

-- 已升级库若没有任何超级管理员：只提示、不自动提权（权限变更必须由人决定）
do $$
begin
  if exists (select 1 from public.profiles)
     and not exists (select 1 from public.profiles where role = 'super_admin') then
    raise notice '提醒：当前没有任何超级管理员(super_admin)账号。请用 SQL Editor 执行：';
    raise notice '  update public.profiles set role = ''super_admin'' where username = ''<你的账号>'';';
    raise notice '否则老师账号管理、分隔点规则、备份导出等管理员专属功能无人可用。';
  end if;
end $$;

-- ============================================================
-- 6.1 V2.0.8 星光台账表格预览 / 历史流水快速编辑
--   1) _recalc_starlight        内部：按流水重算某学生星光余额
--   2) starlight_table          表格预览（每人余额 / 本月变动 / 流水条数 / 最近变动）
--   3) starlight_logs           某学生的历史星光流水（编辑页用）
--   4) starlight_insert_log     补录一条历史星光流水（可指定过去时间）
--   5) starlight_edit_log       修改一条历史星光流水（金额 / 说明 / 时间），自动重算余额
--   6) starlight_delete_log     删除一条误录流水，自动重算余额
--
-- 说明：星光值与积分是两套独立账本，本模块只动星光，不碰积分流水。
-- ============================================================

create or replace function public._recalc_starlight(p_student_id uuid)
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_balance int;
begin
  select coalesce(sum(l.change_amount), 0)::int into v_balance
    from public.starlight_logs l
   where l.student_id = p_student_id;

  insert into public.starlight_accounts (student_id, balance, updated_at)
  values (p_student_id, v_balance, now())
  on conflict (student_id) do update
     set balance = excluded.balance,
         updated_at = now();

  return v_balance;
end;
$$;
revoke all on function public._recalc_starlight(uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 表格预览：每人当前星光 + 本月变动 + 流水条数 + 最近一次变动
-- ------------------------------------------------------------
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
  v_month := coalesce(nullif(btrim(coalesce(p_month_key, '')), ''), public.current_month_key());
  if v_month !~ '^\d{4}-\d{2}$' then
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
         where l.period_key = v_month
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
    'month_key', v_month,
    'scope',     case when v_group is null then 'all' else 'group' end,
    'items',     v_out
  );
end;
$$;
revoke all on function public.starlight_table(text) from public, anon, authenticated;
grant execute on function public.starlight_table(text) to authenticated;

-- ------------------------------------------------------------
-- 某学生的历史星光流水（编辑页用）
-- ------------------------------------------------------------
create or replace function public.starlight_logs(p_student_id uuid, p_limit int default 200)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text;
  v_group text;
  v_limit int;
  v_out   jsonb;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder'],
    '没有权限查看星光流水'
  );
  if p_student_id is null then
    raise exception '请选择学生';
  end if;
  v_role  := public.caller_role();
  v_group := public.student_group(p_student_id);
  if v_role = 'group_recorder' and v_group is distinct from public.my_group_name() then
    raise exception '记录员只能查看本组学生的星光流水';
  end if;
  v_limit := greatest(1, least(coalesce(p_limit, 200), 500));

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            x.id,
           'student_id',    x.student_id,
           'change_amount', x.change_amount,
           'source',        x.source,
           'note',          x.note,
           'period_key',    x.period_key,
           'created_at',    x.created_at,
           'editable',      (x.source <> 'term_reset'),
           'operator_name', x.operator_name
         ) order by x.created_at desc, x.id desc), '[]'::jsonb)
    into v_out
    from (
      select l.*, p.name as operator_name
        from public.starlight_logs l
        left join public.profiles p on p.id = l.operator_id
       where l.student_id = p_student_id
       order by l.created_at desc, l.id desc
       limit v_limit
    ) x;

  return jsonb_build_object(
    'student_id', p_student_id,
    'balance',    public._recalc_starlight(p_student_id),
    'items',      v_out
  );
end;
$$;
revoke all on function public.starlight_logs(uuid, int) from public, anon, authenticated;
grant execute on function public.starlight_logs(uuid, int) to authenticated;

-- ------------------------------------------------------------
-- 补录一条历史星光流水（可指定过去时间，用于补录漏记）
-- ------------------------------------------------------------
create or replace function public.starlight_insert_log(
  p_student_id uuid,
  p_change_amount int,
  p_note text,
  p_created_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_note    text;
  v_at      timestamptz;
  v_log     public.starlight_logs;
  v_balance int;
begin
  perform public.require_role(array['super_admin','admin','executive'], '没有权限补录星光流水');
  if p_student_id is null then
    raise exception '请选择学生';
  end if;
  if p_change_amount is null or p_change_amount = 0 then
    raise exception '变动数量不能为 0';
  end if;
  if not exists (select 1 from public.students s where s.id = p_student_id) then
    raise exception '学生不存在';
  end if;
  v_note := btrim(coalesce(p_note, ''));
  if v_note = '' then
    raise exception '请填写说明';
  end if;
  v_at := coalesce(p_created_at, now());
  if v_at > now() + interval '1 minute' then
    raise exception '变动时间不能晚于当前时间';
  end if;

  insert into public.starlight_logs
    (student_id, change_amount, source, period_key, note, operator_id, created_at)
  values
    (p_student_id, p_change_amount, 'manual',
     coalesce(public.period_key_of('month', (v_at at time zone 'Asia/Shanghai')::date), public.current_month_key()), v_note, auth.uid(), v_at)
  returning * into v_log;

  v_balance := public._recalc_starlight(p_student_id);

  perform public.write_audit(
    '补录星光流水',
    'starlight_log',
    v_log.id::text,
    jsonb_build_object('student_id', p_student_id, 'change_amount', p_change_amount,
                       'note', v_note, 'created_at', v_at, 'balance', v_balance)
  );

  return jsonb_build_object('log', to_jsonb(v_log), 'balance', v_balance);
end;
$$;
revoke all on function public.starlight_insert_log(uuid, int, text, timestamptz) from public, anon, authenticated;
grant execute on function public.starlight_insert_log(uuid, int, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 修改一条历史星光流水（金额 / 说明 / 时间）
-- ------------------------------------------------------------
create or replace function public.starlight_edit_log(
  p_log_id uuid,
  p_change_amount int default null,
  p_note text default null,
  p_created_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_old     public.starlight_logs;
  v_log     public.starlight_logs;
  v_balance int;
  v_amount  int;
  v_note    text;
  v_at      timestamptz;
begin
  perform public.require_role(array['super_admin','admin','executive'], '没有权限修改星光流水');
  if p_log_id is null then
    raise exception '请选择要修改的星光流水';
  end if;
  select * into v_old from public.starlight_logs where id = p_log_id;
  if v_old.id is null then
    raise exception '星光流水不存在';
  end if;
  if v_old.source = 'term_reset' then
    raise exception '学期清零流水不允许修改';
  end if;

  v_amount := coalesce(p_change_amount, v_old.change_amount);
  if v_amount = 0 then
    raise exception '变动数量不能为 0（如需删除请使用「删除」）';
  end if;
  v_note := coalesce(nullif(btrim(coalesce(p_note, '')), ''), v_old.note);
  v_at   := coalesce(p_created_at, v_old.created_at);
  if v_at > now() + interval '1 minute' then
    raise exception '变动时间不能晚于当前时间';
  end if;

  update public.starlight_logs l
     set change_amount = v_amount,
         note          = v_note,
         created_at    = v_at,
         period_key    = coalesce(public.period_key_of('month', (v_at at time zone 'Asia/Shanghai')::date), public.current_month_key())
   where l.id = p_log_id
   returning * into v_log;

  v_balance := public._recalc_starlight(v_log.student_id);

  perform public.write_audit(
    '编辑星光流水',
    'starlight_log',
    p_log_id::text,
    jsonb_build_object(
      'student_id',   v_log.student_id,
      'before',       jsonb_build_object('change_amount', v_old.change_amount,
                                         'note', v_old.note, 'created_at', v_old.created_at),
      'after',        jsonb_build_object('change_amount', v_log.change_amount,
                                         'note', v_log.note, 'created_at', v_log.created_at),
      'balance',      v_balance
    )
  );

  return jsonb_build_object('log', to_jsonb(v_log), 'balance', v_balance);
end;
$$;
revoke all on function public.starlight_edit_log(uuid, int, text, timestamptz) from public, anon, authenticated;
grant execute on function public.starlight_edit_log(uuid, int, text, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 删除一条误录的星光流水（学期清零流水不可删）
-- ------------------------------------------------------------
create or replace function public.starlight_delete_log(p_log_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_old     public.starlight_logs;
  v_balance int;
begin
  perform public.require_role(array['super_admin','admin','executive'], '没有权限删除星光流水');
  select * into v_old from public.starlight_logs where id = p_log_id;
  if v_old.id is null then
    raise exception '星光流水不存在';
  end if;
  if v_old.source = 'term_reset' then
    raise exception '学期清零流水不允许删除';
  end if;

  delete from public.starlight_logs where id = p_log_id;
  v_balance := public._recalc_starlight(v_old.student_id);

  perform public.write_audit(
    '删除星光流水',
    'starlight_log',
    p_log_id::text,
    jsonb_build_object('student_id', v_old.student_id, 'change_amount', v_old.change_amount,
                       'note', v_old.note, 'created_at', v_old.created_at, 'balance', v_balance)
  );

  return jsonb_build_object('deleted', p_log_id, 'student_id', v_old.student_id, 'balance', v_balance);
end;
$$;
revoke all on function public.starlight_delete_log(uuid) from public, anon, authenticated;
grant execute on function public.starlight_delete_log(uuid) to authenticated;

-- ============================================================
-- 62_ops_v209.sql  V2.0.9 需求批
--   1) 数据管理：积分明细导入（兼容 V1.6）、星光台账替换/补充导入、各类导出
--   2) 仓库管理：按小组 / 按个人查看学生仓库并批量标记卡片
--   3) 星光台账表格像 Excel 一样直接改数值（按差额生成调整流水）
-- 说明：建号强制改密、设置页改密码、执行小组手动汇总 直接改在 54_accounts.sql / 57_admin_ops.sql 内，
--       不在本模块重复定义（check_sql 禁止同一签名多处定义）。
-- 全部函数幂等（create or replace + drop 旧签名），安全定义者 + 固定 search_path。
-- ============================================================

-- ------------------------------------------------------------
-- 6.4 数据管理：积分明细导入（兼容 V1.6）
-- ------------------------------------------------------------
create or replace function public.admin_import_records(p_rows jsonb, p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role     text := public.caller_role();
  v_row      jsonb;
  v_idx      int := 0;
  v_ok       int := 0;
  v_skip     int := 0;
  v_fail     int := 0;
  v_errors   jsonb := '[]'::jsonb;
  v_no       text;
  v_name     text;
  v_stype    text;
  v_cat      text;
  v_reason   text;
  v_points   numeric;
  v_date     text;
  v_recname  text;
  v_status   text;
  v_stu      public.students;
  v_stu_id   uuid;
  v_recdate  date;
  v_key      text;
begin
  perform public.require_role(array['super_admin','admin'], '只有管理员或班主任可以导入积分明细');
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception '导入数据格式错误：需要数组';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception '单次最多导入 5000 条记录';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_no      := nullif(btrim(coalesce(v_row->>'student_no', v_row->>'学号', '')), '');
      v_name    := nullif(btrim(coalesce(v_row->>'student_name', v_row->>'姓名', v_row->>'学生', '')), '');
      v_stype   := nullif(btrim(coalesce(v_row->>'score_type', v_row->>'类型', '')), '');
      v_cat     := nullif(btrim(coalesce(v_row->>'category', v_row->>'分类', '')), '');
      v_reason  := nullif(btrim(coalesce(v_row->>'reason', v_row->>'原因', '')), '');
      v_recname := nullif(btrim(coalesce(v_row->>'recorder_name', v_row->>'记录人', '')), '');
      v_status  := coalesce(nullif(btrim(coalesce(v_row->>'status', v_row->>'状态', '')), ''), '正常');
      v_date    := nullif(btrim(coalesce(v_row->>'record_date', v_row->>'日期', '')), '');

      begin
        v_points := nullif(btrim(coalesce(v_row->>'points', v_row->>'分值', '')), '')::numeric;
      exception when others then
        raise exception '第 % 行：分值不是数字', v_idx;
      end;

      if v_reason is null then raise exception '第 % 行：缺少原因', v_idx; end if;
      if v_points is null then raise exception '第 % 行：缺少分值', v_idx; end if;
      if v_stype is null then v_stype := case when v_points >= 0 then '加分' else '扣分' end; end if;

      v_stu_id := null;
      if v_no is not null then
        select s.* into v_stu from public.students s
         where lower(btrim(coalesce(s.student_no, ''))) = lower(v_no)
         order by s.created_at, s.id limit 1;
        if found then v_stu_id := v_stu.id; end if;
      end if;
      if v_stu_id is null and v_name is not null then
        select s.* into v_stu from public.students s
         where btrim(s.name) = v_name
         order by s.created_at, s.id limit 1;
        if found then
          if exists (select 1 from public.students s where btrim(s.name) = v_name and s.id <> v_stu.id) then
            raise exception '第 % 行：姓名「%」对应多名学生，请补充学号', v_idx, v_name;
          end if;
          v_stu_id := v_stu.id;
        end if;
      end if;
      if v_stu_id is null then
        raise exception '第 % 行：找不到学生（学号 % / 姓名 %）', v_idx, coalesce(v_no, '空'), coalesce(v_name, '空');
      end if;

      if v_date is null then
        v_recdate := public.bj_today();
      else
        begin
          v_recdate := (replace(replace(btrim(v_date), '/', '-'), '.', '-'))::date;
        exception when others then
          raise exception '第 % 行：日期格式无法识别（%）', v_idx, v_date;
        end;
      end if;
      if v_recdate > public.bj_today() then
        raise exception '第 % 行：日期不能晚于今天（%）', v_idx, v_recdate;
      end if;

      if p_dry_run then
        v_ok := v_ok + 1;
        continue;
      end if;

      v_key := coalesce(public.period_key_of('month', v_recdate), public.current_month_key());
      insert into public.records (
        id, student_id, score_type, category, reason, points,
        recorder_id, record_date, status, evidence,
        period_key, recorder_name, created_at
      ) values (
        gen_random_uuid(), v_stu_id, v_stype, coalesce(v_cat, '导入'), v_reason, v_points,
        null, to_char(v_recdate, 'YYYY-MM-DD'), v_status, null,
        v_key, coalesce(v_recname, '历史导入'), v_recdate::timestamptz + interval '8 hours'
      );
      v_ok := v_ok + 1;
    exception when others then
      v_fail := v_fail + 1;
      if jsonb_array_length(v_errors) < 30 then
        v_errors := v_errors || jsonb_build_object('row', v_idx, 'reason', sqlerrm);
      end if;
    end;
  end loop;

  perform public.write_audit('admin_import_records', 'records', null,
    jsonb_build_object('total', v_idx, 'imported', v_ok, 'failed', v_fail, 'dry_run', p_dry_run));

  return jsonb_build_object('total', v_idx, 'imported', v_ok, 'skipped', v_skip,
                            'failed', v_fail, 'errors', v_errors, 'dry_run', p_dry_run);
end;
$$;
revoke all on function public.admin_import_records(jsonb, boolean) from public, anon, authenticated;
grant execute on function public.admin_import_records(jsonb, boolean) to authenticated;

-- ------------------------------------------------------------
-- 6.5 数据管理：星光台账 替换导入 / 补充导入
-- ------------------------------------------------------------
create or replace function public.starlight_import(p_rows jsonb, p_mode text default 'append')
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_mode    text := lower(btrim(coalesce(p_mode, 'append')));
  v_row     jsonb;
  v_idx     int := 0;
  v_ok      int := 0;
  v_fail    int := 0;
  v_errors  jsonb := '[]'::jsonb;
  v_no      text;
  v_name    text;
  v_amt     int;
  v_note    text;
  v_at      timestamptz;
  v_at_raw  text;
  v_mk      text;
  v_stu     public.students;
  v_stu_id  uuid;
  v_cleared int := 0;
begin
  perform public.require_role(array['super_admin','admin'], '只有管理员或班主任可以导入星光台账');
  if v_mode not in ('replace', 'append') then
    raise exception '导入方式无效：%', v_mode;
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception '导入数据格式错误：需要数组';
  end if;

  if v_mode = 'replace' then
    delete from public.starlight_logs where true;
    get diagnostics v_cleared = row_count;
    update public.starlight_accounts set balance = 0, updated_at = now();
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_no   := nullif(btrim(coalesce(v_row->>'student_no', v_row->>'学号', '')), '');
      v_name := nullif(btrim(coalesce(v_row->>'student_name', v_row->>'姓名', v_row->>'学生', '')), '');
      v_note := nullif(btrim(coalesce(v_row->>'note', v_row->>'说明', '')), '');
      v_at_raw := nullif(btrim(coalesce(v_row->>'created_at', v_row->>'时间', v_row->>'日期', '')), '');

      begin
        v_amt := nullif(btrim(coalesce(v_row->>'change_amount', v_row->>'变动', v_row->>'变化', '')), '')::int;
      exception when others then
        raise exception '第 % 行：变动数量不是整数', v_idx;
      end;
      if v_amt is null or v_amt = 0 then raise exception '第 % 行：变动数量不能为空或 0', v_idx; end if;

      v_stu_id := null;
      if v_no is not null then
        select s.* into v_stu from public.students s
         where lower(btrim(coalesce(s.student_no, ''))) = lower(v_no)
         order by s.created_at, s.id limit 1;
        if found then v_stu_id := v_stu.id; end if;
      end if;
      if v_stu_id is null and v_name is not null then
        select s.* into v_stu from public.students s
         where btrim(s.name) = v_name order by s.created_at, s.id limit 1;
        if found then
          if exists (select 1 from public.students s where btrim(s.name) = v_name and s.id <> v_stu.id) then
            raise exception '第 % 行：姓名「%」对应多名学生，请补充学号', v_idx, v_name;
          end if;
          v_stu_id := v_stu.id;
        end if;
      end if;
      if v_stu_id is null then
        raise exception '第 % 行：找不到学生（学号 % / 姓名 %）', v_idx, coalesce(v_no, '空'), coalesce(v_name, '空');
      end if;

      if v_at_raw is null then
        v_at := now();
      else
        begin
          v_at := replace(replace(btrim(v_at_raw), '/', '-'), '.', '-')::timestamptz;
        exception when others then
          raise exception '第 % 行：时间格式无法识别（%）', v_idx, v_at_raw;
        end;
      end if;

      v_mk := coalesce(public.period_key_of('month', (v_at at time zone 'Asia/Shanghai')::date), public.current_month_key());
      insert into public.starlight_logs (student_id, change_amount, source, period_key, note, created_at)
      values (v_stu_id, v_amt, 'manual', v_mk, coalesce(v_note, '导入'), v_at);
      v_ok := v_ok + 1;
    exception when others then
      v_fail := v_fail + 1;
      if jsonb_array_length(v_errors) < 30 then
        v_errors := v_errors || jsonb_build_object('row', v_idx, 'reason', sqlerrm);
      end if;
    end;
  end loop;

  perform public._recalc_starlight(s.id) from public.students s;

  perform public.write_audit('starlight_import', 'starlight_logs', null,
    jsonb_build_object('mode', v_mode, 'total', v_idx, 'imported', v_ok,
                       'failed', v_fail, 'cleared', v_cleared));

  return jsonb_build_object('mode', v_mode, 'total', v_idx, 'imported', v_ok,
                            'failed', v_fail, 'cleared', v_cleared, 'errors', v_errors);
end;
$$;
revoke all on function public.starlight_import(jsonb, text) from public, anon, authenticated;
grant execute on function public.starlight_import(jsonb, text) to authenticated;

-- ------------------------------------------------------------
-- 6.6 数据管理：导出（积分明细 / 星光流水 / 周月汇总）
-- ------------------------------------------------------------
create or replace function public.admin_export_records(p_from date default null, p_to date default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_res    jsonb;
begin
  if v_caller not in ('system','super_admin','admin','executive') then
    raise exception '没有权限导出积分明细';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'record_date', r.record_date,
           'student_no', s.student_no,
           'student_name', s.name,
           'group_name', s.group_name,
           'score_type', r.score_type,
           'category', r.category,
           'reason', r.reason,
           'points', r.points,
           'status', r.status,
           'period_key', r.period_key,
           'recorder_name', coalesce(r.recorder_name, rp.name, ''),
           'created_at', r.created_at
         ) order by r.record_date, s.student_no nulls last, r.created_at), '[]'::jsonb)
    into v_res
    from public.records r
    join public.students s on s.id = r.student_id
    left join public.profiles rp on rp.id = r.recorder_id
   where (p_from is null or r.record_date >= to_char(p_from, 'YYYY-MM-DD'))
     and (p_to is null or r.record_date <= to_char(p_to, 'YYYY-MM-DD'));

  return jsonb_build_object('count', jsonb_array_length(v_res),
                            'from', p_from, 'to', p_to, 'rows', v_res);
end;
$$;
revoke all on function public.admin_export_records(date, date) from public, anon, authenticated;
grant execute on function public.admin_export_records(date, date) to authenticated;

create or replace function public.starlight_export_logs(p_from date default null, p_to date default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_res    jsonb;
begin
  if v_caller not in ('system','super_admin','admin','executive') then
    raise exception '没有权限导出星光流水';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'created_at', l.created_at,
           'student_no', s.student_no,
           'student_name', s.name,
           'group_name', s.group_name,
           'change_amount', l.change_amount,
           'source', l.source,
           'period_key', l.period_key,
           'note', coalesce(l.note, '')
         ) order by l.created_at), '[]'::jsonb)
    into v_res
    from public.starlight_logs l
    join public.students s on s.id = l.student_id
   where (p_from is null or (l.created_at at time zone 'Asia/Shanghai')::date >= p_from)
     and (p_to is null or (l.created_at at time zone 'Asia/Shanghai')::date <= p_to);

  return jsonb_build_object('count', jsonb_array_length(v_res),
                            'from', p_from, 'to', p_to, 'rows', v_res);
end;
$$;
revoke all on function public.starlight_export_logs(date, date) from public, anon, authenticated;
grant execute on function public.starlight_export_logs(date, date) to authenticated;

create or replace function public.admin_export_summaries(p_type text default 'week', p_limit int default 60)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_type   text := lower(btrim(coalesce(p_type, 'week')));
  v_res    jsonb;
begin
  if v_caller not in ('system','super_admin','admin','executive','group_recorder') then
    raise exception '没有权限导出汇总';
  end if;
  if v_type = 'week' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'period_key', w.period_key,
             'range_start', w.range_start,
             'range_end', w.range_end,
             'groups', w.summary->'groups',
             'individuals', w.summary->'individuals',
             'reward_groups', w.summary->'reward_groups',
             'penalty_groups', w.summary->'penalty_groups',
             'reward_group_chances', coalesce((w.summary->>'reward_group_chances')::int, 0),
             'penalty_group_chances', coalesce((w.summary->>'penalty_group_chances')::int, 0)
           ) order by w.range_end desc), '[]'::jsonb)
      into v_res
      from (select * from public.weekly_summaries order by range_end desc limit greatest(coalesce(p_limit, 60), 1)) w;
    return jsonb_build_object('type', 'week', 'count', jsonb_array_length(v_res), 'rows', v_res);
  elsif v_type = 'month' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'period_key', st.period_key,
             'status', st.status,
             'finished_at', st.finished_at,
             'auto_draw_count', st.auto_draw_count,
             'second_class', st.second_class,
             'reward_rows', st.summary->'reward'->'rows',
             'penalty_rows', st.summary->'penalty'->'rows'
           ) order by st.period_key desc), '[]'::jsonb)
      into v_res
      from (select * from public.settlements
             where status <> 'rolled_back'
             order by period_key desc limit greatest(coalesce(p_limit, 60), 1)) st;
    return jsonb_build_object('type', 'month', 'count', jsonb_array_length(v_res), 'rows', v_res);
  else
    raise exception '汇总类型无效：%', v_type;
  end if;
end;
$$;
revoke all on function public.admin_export_summaries(text, int) from public, anon, authenticated;
grant execute on function public.admin_export_summaries(text, int) to authenticated;

-- ------------------------------------------------------------
-- 6.7 星光台账表格：像 Excel 一样直接改数值（按差额生成调整流水）
-- ------------------------------------------------------------
create or replace function public.starlight_batch_set_balance(p_rows jsonb, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role    text := public.caller_role();
  v_row     jsonb;
  v_idx     int := 0;
  v_changed int := 0;
  v_skip    int := 0;
  v_errors  jsonb := '[]'::jsonb;
  v_stu_id  uuid;
  v_new     int;
  v_cur     int;
  v_diff    int;
  v_mk      text := public.current_month_key();
begin
  perform public.require_role(array['super_admin','admin','executive'], '只有执行小组及以上可以修改星光');
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception '数据格式错误：需要数组';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_stu_id := nullif(btrim(coalesce(v_row->>'student_id', '')), '')::uuid;
      if v_stu_id is null then
        raise exception '第 % 行：缺少学生', v_idx;
      end if;
      v_new := nullif(btrim(coalesce(v_row->>'balance', v_row->>'new_balance', '')), '')::int;
      if v_new is null then
        v_skip := v_skip + 1;
        continue;
      end if;
      if v_new < 0 then
        raise exception '第 % 行：星光值不能为负数', v_idx;
      end if;

      select coalesce(sum(change_amount), 0)::int into v_cur
        from public.starlight_logs where student_id = v_stu_id;
      v_diff := v_new - coalesce(v_cur, 0);
      if v_diff = 0 then
        v_skip := v_skip + 1;
        continue;
      end if;

      insert into public.starlight_logs (student_id, change_amount, source, period_key, note, created_at)
      values (v_stu_id, v_diff, 'manual', v_mk,
              coalesce(nullif(btrim(coalesce(p_note, '')), ''), '表格批量调整'), now());
      perform public._recalc_starlight(v_stu_id);
      v_changed := v_changed + 1;
    exception when others then
      if jsonb_array_length(v_errors) < 30 then
        v_errors := v_errors || jsonb_build_object('row', v_idx, 'reason', sqlerrm);
      end if;
    end;
  end loop;

  perform public.write_audit('starlight_batch_set_balance', 'starlight_logs', null,
    jsonb_build_object('rows', v_idx, 'changed', v_changed, 'note', coalesce(p_note, '')));

  return jsonb_build_object('rows', v_idx, 'changed', v_changed, 'skipped', v_skip, 'errors', v_errors);
end;
$$;
revoke all on function public.starlight_batch_set_balance(jsonb, text) from public, anon, authenticated;
grant execute on function public.starlight_batch_set_balance(jsonb, text) to authenticated;

-- ------------------------------------------------------------
-- 6.8 仓库管理：按小组 / 按个人查看并批量标记
-- ------------------------------------------------------------
create or replace function public.admin_warehouse(
  p_scope      text default 'group',
  p_group      text default null,
  p_student_id uuid default null,
  p_status     text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_scope  text := lower(btrim(coalesce(p_scope, 'group')));
  v_stmt   text;
  v_result jsonb;
begin
  if v_role not in ('system','super_admin','admin','executive') then
    raise exception '只有执行小组及以上可以管理仓库';
  end if;
  if v_scope not in ('group','student') then
    raise exception '查看方式无效：%', v_scope;
  end if;

  v_stmt := $q$
    select coalesce(jsonb_agg(row_data order by grp, stu_name), '[]'::jsonb)
      from (
        select s.group_name as grp,
               s.name as stu_name,
               s.id as student_id,
               jsonb_build_object(
                 'student_id', s.id,
                 'student_no', s.student_no,
                 'name', s.name,
                 'group_name', s.group_name,
                 'cards', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'id', d.id,
                            'drawn_at', d.drawn_at,
                            'pool_type', d.pool_type,
                            'item_title', coalesce(d.item_snapshot->>'title', ''),
                            'status', d.status,
                            'expire_at', d.expire_at,
                            'source', d.source,
                            'note', coalesce(d.note, ''),
                            'is_group', d.is_group
                          ) order by d.drawn_at desc)
                     from public.lottery_draws d
                    where d.student_id = s.id
                      and ($4 is null or d.status = $4)
                 ), '[]'::jsonb)
               ) as row_data
          from public.students s
         where ($2 is null or s.group_name = $2)
           and ($3 is null or s.id = $3)
      ) t
  $q$;

  execute v_stmt into v_result using p_scope, p_group, p_student_id, p_status;

  return jsonb_build_object('scope', v_scope, 'students', v_result,
                            'total_students', jsonb_array_length(v_result));
end;
$$;
revoke all on function public.admin_warehouse(text, text, uuid, text) from public, anon, authenticated;
grant execute on function public.admin_warehouse(text, text, uuid, text) to authenticated;

create or replace function public.admin_batch_mark_cards(
  p_draw_ids uuid[],
  p_status   text default 'used',
  p_note     text default null,
  p_used_at  timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role     text := public.caller_role();
  v_status   text := lower(btrim(coalesce(p_status, 'used')));
  v_id       uuid;
  v_draw     public.lottery_draws;
  v_ok       int := 0;
  v_skip     int := 0;
  v_errors   jsonb := '[]'::jsonb;
  v_used     timestamptz := coalesce(p_used_at, now());
begin
  if v_role not in ('system','super_admin','admin','executive') then
    raise exception '只有执行小组及以上可以标记仓库卡片';
  end if;
  if v_status not in ('used','void','expired') then
    raise exception '标记状态无效：%', v_status;
  end if;
  if p_draw_ids is null or array_length(p_draw_ids, 1) is null then
    raise exception '请先选择要标记的卡片';
  end if;

  foreach v_id in array p_draw_ids loop
    begin
      select * into v_draw from public.lottery_draws where id = v_id for update;
      if not found then
        v_skip := v_skip + 1;
        v_errors := v_errors || jsonb_build_object('id', v_id, 'reason', '卡片不存在');
        continue;
      end if;
      if v_status = 'void' and v_role not in ('system','super_admin','admin') then
        raise exception '只有管理员或班主任可以作废卡片';
      end if;
      -- 已使用 / 已过期 / 已即时生效（星光类、文本类）的卡片不能被作废
      if v_status = 'void' and v_draw.status <> 'unused' then
        raise exception '只有「未使用」的卡片可以作废（当前状态：%），已使用/已过期/已生效的卡片不能作废',
          case v_draw.status
            when 'used' then '已使用' when 'expired' then '已过期'
            when 'posted' then '已即时生效' when 'void' then '已作废' else v_draw.status end;
      end if;
      if v_draw.status = v_status then
        v_skip := v_skip + 1;
        continue;
      end if;
      if v_status = 'used' then
        if v_draw.status not in ('unused','expired') then
          raise exception '该卡片当前状态为「%」，不能标记已使用', v_draw.status;
        end if;
        if v_draw.expire_at is not null and v_used > v_draw.expire_at then
          raise exception '使用时间超出卡片有效期（有效期至 %）', to_char(v_draw.expire_at at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI');
        end if;
        update public.lottery_draws
           set status = 'used', used_by = auth.uid(), used_at = v_used,
               note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note)
         where id = v_id;
      else
        if v_status = 'expired' and v_draw.status not in ('unused','expired') then
          raise exception '只有「未使用」的卡片可以置为已过期（当前状态：%）', v_draw.status;
        end if;
        update public.lottery_draws
           set status = v_status,
               note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note)
         where id = v_id;
      end if;
      v_ok := v_ok + 1;
    exception when others then
      v_skip := v_skip + 1;
      if jsonb_array_length(v_errors) < 30 then
        v_errors := v_errors || jsonb_build_object('id', v_id, 'reason', sqlerrm);
      end if;
    end;
  end loop;

  perform public.write_audit('admin_batch_mark_cards', 'lottery_draws', null,
    jsonb_build_object('status', v_status, 'ok', v_ok, 'skip', v_skip));

  return jsonb_build_object('status', v_status, 'ok', v_ok, 'skipped', v_skip, 'errors', v_errors);
end;
$$;
revoke all on function public.admin_batch_mark_cards(uuid[], text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.admin_batch_mark_cards(uuid[], text, text, timestamptz) to authenticated;

-- ============================================================
-- V2.0.11 后端：仓库管理手动发卡
--   仅 super_admin / admin（管理员、班主任）可调用
--   支持「按个人」或「按小组」发放奖励卡 / 惩罚卡
--   每次发放为每名学生各生成一张互相独立的卡片（不合并为小组级记录）
-- ============================================================

create or replace function public.admin_grant_cards(
  p_pool_type   text,
  p_item_id     uuid,
  p_student_ids uuid[] default null,
  p_group_name  text   default null,
  p_note        text   default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_item   public.lottery_items;
  v_ids    uuid[];
  v_sid    uuid;
  v_draw   uuid;
  v_cnt    int := 0;
  v_scope  text;
  v_group  text;
  v_note   text;
  v_period text := public.current_month_key();
begin
  if v_role not in ('system', 'super_admin', 'admin') then
    raise exception '只有管理员或班主任可以手动发放卡片';
  end if;

  if p_pool_type not in ('reward', 'penalty') then
    raise exception '奖池类型无效：%', coalesce(p_pool_type, 'null');
  end if;

  select * into v_item from public.lottery_items where id = p_item_id;
  if v_item.id is null then
    raise exception '卡片不存在';
  end if;
  if v_item.pool_type <> p_pool_type then
    raise exception '卡片「%」不属于所选奖池', coalesce(v_item.title, '');
  end if;
  if not coalesce(v_item.is_active, true) then
    raise exception '卡片「%」已停用，不能发放', coalesce(v_item.title, '');
  end if;

  v_group := nullif(btrim(coalesce(p_group_name, '')), '');
  if v_group is not null then
    v_scope := 'group';
    select array_agg(s.id order by s.name) into v_ids
      from public.students s
     where s.group_name = v_group;
    if v_ids is null then
      raise exception '小组「%」还没有学生', v_group;
    end if;
  else
    v_scope := 'students';
    select array_agg(x order by x) into v_ids
      from (select distinct unnest(coalesce(p_student_ids, array[]::uuid[])) as x) t;
    if v_ids is null then
      raise exception '请选择要发放卡片的学生或小组';
    end if;
  end if;

  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if v_note is null then
    v_note := case when v_scope = 'group' then '手动发放（小组统一发放）' else '手动发放' end;
  end if;

  foreach v_sid in array v_ids loop
    v_draw := public._apply_draw(
      v_sid,
      p_pool_type,
      v_item.id,
      v_period,
      'manual',
      coalesce(v_group, public.student_group(v_sid)),
      '[]'::jsonb,
      false,
      v_note,
      auth.uid(),
      false
    );
    v_cnt := v_cnt + 1;
    perform public.notify(
      (select p.id from public.profiles p where p.student_id = v_sid limit 1),
      '收到一张' || (case when p_pool_type = 'reward' then '奖励卡' else '惩罚卡' end),
      '「' || coalesce(v_item.title, '卡片') || '」已放入你的仓库，可在「我的仓库」查看。' ||
        case when v_scope = 'group' then '（小组统一发放）' else '' end,
      'lottery',
      'lottery_draw',
      v_draw
    );
  end loop;

  perform public.write_audit(
    'grant_cards', 'lottery_draw', null,
    jsonb_build_object(
      'scope', v_scope,
      'group_name', v_group,
      'pool_type', p_pool_type,
      'item_id', v_item.id,
      'item_title', v_item.title,
      'count', v_cnt,
      'note', v_note
    )
  );

  return jsonb_build_object(
    'ok', true,
    'scope', v_scope,
    'group_name', v_group,
    'pool_type', p_pool_type,
    'item_title', coalesce(v_item.title, ''),
    'item_kind', v_item.item_kind,
    'count', v_cnt,
    'period_key', v_period
  );
end;
$$;
revoke all on function public.admin_grant_cards(text, uuid, uuid[], text, text) from public, anon, authenticated;
grant execute on function public.admin_grant_cards(text, uuid, uuid[], text, text) to authenticated;

-- ============================================================
-- 6.4 周期结算调整（V2.0.14）
--   周结算只出汇总快照；小组抽奖改为「人工选择小组」由执行小组及以上操作
--   月度个人结算保持原规则（含奖励/惩罚次数与自动抽选）
-- ============================================================

-- ------------------------------------------------------------
-- 6.4.1 周小组抽奖看板：本周小组排名 + 建议名单 + 已抽状态
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 6.4.2 人工小组抽奖：执行小组及以上为指定小组抽奖（每组每池每周限一次）
--   奖励：全组每人各得一份（星光卡每人入账）；惩罚：一条结果全组共担
-- ------------------------------------------------------------
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

-- ============================================================
-- 8.5 V2.0.19 周期定义（周 / 月起止日期 + 规则计分周）
--    设计：开发文件/docs/周期定义改造方案_V2.0.17.md
--    · 周：直接设置起止日期（可跨自然月），相邻周首尾相接
--    · 月：两段式——先设起始（进行中，结束日期为空），再设结束；
--          结束日+1 自动成为下月起始日；月起止必须落在周边界上
--    · 规则计分周：该周按 N 个规则计分周计算（上限 ×N）
--    · period_key = 起始日期（如 2026-10-26），周期结束不改变键
-- ============================================================

-- ------------------------------------------------------------
-- 8.5.0 日期中文/ISO 显示辅助
-- ------------------------------------------------------------
create or replace function public.fmt_cn_date(p_date date)
returns text
language sql immutable security definer set search_path = public, extensions as $$
  select case when p_date is null then '—' else to_char(p_date, 'YYYY-MM-DD') end;
$$;

-- ------------------------------------------------------------
-- 8.5.1 周期一致性检查：返回 {ok, issues:[{level,type,detail,start_date}]}
-- ------------------------------------------------------------
create or replace function public.admin_validate_periods()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_issues jsonb := '[]'::jsonb;
  v_w      record;
  v_m      record;
  v_prev   date;
begin
  if public.caller_role() not in ('system', 'super_admin', 'admin', 'executive') then
    raise exception '没有权限检查周期定义';
  end if;

  -- 周：时间递进 + 首尾相接
  v_prev := null;
  for v_w in
    select b.* from public.boundaries b
     where b.type = 'week' and b.deprecated = false and b.start_date is not null
     order by b.start_date
  loop
    if v_w.end_date is null then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'week',
        'start_date', v_w.start_date, 'detail', '周周期缺少结束日期');
    elsif v_w.end_date < v_w.start_date then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'week',
        'start_date', v_w.start_date, 'detail', '结束日期早于起始日期');
    end if;
    if v_prev is not null and v_w.start_date <> v_prev + 1 then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'week',
        'start_date', v_w.start_date, 'detail',
        format('与前一周不连续：上一周结束于 %s，本周开始于 %s', v_prev, v_w.start_date));
    end if;
    v_prev := v_w.end_date;
  end loop;

  -- 月：起止必须落在周边界
  for v_m in
    select b.* from public.boundaries b
     where b.type = 'month' and b.deprecated = false and b.start_date is not null
     order by b.start_date
  loop
    if not exists (select 1 from public.boundaries w
                    where w.type = 'week' and w.deprecated = false and w.start_date = v_m.start_date) then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'month',
        'start_date', v_m.start_date, 'detail', '月起始日不在任何周周期的起始日上');
    end if;
    if v_m.end_date is not null and not exists (
         select 1 from public.boundaries w
          where w.type = 'week' and w.deprecated = false and w.start_date = v_m.end_date + 1) then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'month',
        'start_date', v_m.start_date, 'detail', '月结束日的下一天不是任何周周期的起始日');
    end if;
    if v_m.end_date is not null and v_m.end_date < v_m.start_date then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'month',
        'start_date', v_m.start_date, 'detail', '月结束日期早于起始日期');
    end if;
  end loop;

  -- 月之间：只能有一个进行中，且相邻月必须首尾相接
  if (select count(*) from public.boundaries
       where type = 'month' and deprecated = false and end_date is null) > 1 then
    v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'month',
      'detail', '存在多个「进行中」的月周期，最多只能有一个');
  end if;
  for v_m in
    select b.*, lag(b.end_date) over (order by b.start_date) as prev_end
      from public.boundaries b
     where b.type = 'month' and b.deprecated = false and b.start_date is not null
  loop
    if v_m.prev_end is not null and v_m.start_date <> v_m.prev_end + 1 then
      v_issues := v_issues || jsonb_build_object('level', 'warn', 'type', 'month',
        'start_date', v_m.start_date, 'detail',
        format('与上一个月不连续：上一月结束于 %s，本月开始于 %s', v_m.prev_end, v_m.start_date));
    end if;
  end loop;

  return jsonb_build_object(
    'ok', jsonb_array_length(v_issues) = 0,
    'issue_count', jsonb_array_length(v_issues),
    'issues', v_issues
  );
end;
$$;

-- ------------------------------------------------------------
-- 8.5.2 设置/修改周期
--   p_type: week | month
--   p_start: 起始日期（周一或任意，但月必须是某个周的起始日）
--   p_end:   结束日期（含当天）；week 必填，month 可为空 = 进行中
--   p_rule_weeks: 该周按几个「规则计分周」算（1~4，默认 1）
-- ------------------------------------------------------------
create or replace function public.admin_set_period(
  p_type text,
  p_start date,
  p_end date default null,
  p_rule_weeks int default 1
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_id     uuid;
  v_b      public.boundaries;
  v_prev   public.boundaries;
  v_next   public.boundaries;
  v_pk     text;
  v_at     timestamptz;
  v_weeks  int := coalesce(p_rule_weeks, 1);
  v_new    public.boundaries;
begin
  if v_role not in ('system', 'super_admin') then
    raise exception '只有管理员可以修改周期定义';
  end if;
  if p_type not in ('week', 'month') then
    raise exception '周期类型只能是 week 或 month';
  end if;
  if p_start is null then
    raise exception '请选择起始日期';
  end if;
  if v_weeks < 1 or v_weeks > 4 then
    raise exception '规则计分周只能是 1~4';
  end if;

  if p_type = 'week' then
    if p_end is null then
      raise exception '周周期需要填写结束日期';
    end if;
    if p_end < p_start then
      raise exception '结束日期不能早于起始日期';
    end if;
    if (p_end - p_start) > 27 then
      raise exception '一周最多 28 天，请检查日期';
    end if;
    v_prev := (select b from public.boundaries b
                where b.type = 'week' and b.deprecated = false and b.end_date is not null
                  and b.end_date < p_start
                order by b.end_date desc limit 1);
    if v_prev.id is not null and v_prev.end_date + 1 <> p_start then
      raise exception '与前一周不连续：上一周结束于 %，本周应从 % 开始',
        public.fmt_cn_date(v_prev.end_date), public.fmt_cn_date(v_prev.end_date + 1);
    end if;
    v_next := (select b from public.boundaries b
                where b.type = 'week' and b.deprecated = false
                  and b.start_date > p_start
                order by b.start_date limit 1);
    if v_next.id is not null and v_next.start_date - 1 <> p_end then
      raise exception '与后一周重叠或留空：下一周开始于 %，本周应结束于 %',
        public.fmt_cn_date(v_next.start_date), public.fmt_cn_date(v_next.start_date - 1);
    end if;
  else
    -- 月：起止必须落在周边界上
    if not exists (select 1 from public.boundaries w
                    where w.type = 'week' and w.deprecated = false and w.start_date = p_start) then
      raise exception '月起始日必须是某个周周期的第一天（当前不是），请先设置对应的周';
    end if;
    if p_end is not null then
      if p_end < p_start then
        raise exception '结束日期不能早于起始日期';
      end if;
      if not exists (select 1 from public.boundaries w
                      where w.type = 'week' and w.deprecated = false and w.start_date = p_end + 1) then
        raise exception '月结束日的下一天必须是某个周周期的第一天，请把结束日设为该周的周日';
      end if;
    end if;
    v_prev := (select b from public.boundaries b
                where b.type = 'month' and b.deprecated = false and b.start_date < p_start
                order by b.start_date desc limit 1);
    if v_prev.id is not null then
      if v_prev.end_date is null then
        if p_end is not null then
          raise exception '上一个月（% 起）还在进行中，请先为它设置结束日期',
            public.fmt_cn_date(v_prev.start_date);
        else
          raise exception '已有一个进行中的月周期（% 起），不能再开新的',
            public.fmt_cn_date(v_prev.start_date);
        end if;
      elsif v_prev.end_date + 1 <> p_start then
        raise exception '与上一个月不连续：上一月结束于 %，本月应从 % 开始',
          public.fmt_cn_date(v_prev.end_date), public.fmt_cn_date(v_prev.end_date + 1);
      end if;
    end if;
    v_next := (select b from public.boundaries b
                where b.type = 'month' and b.deprecated = false and b.start_date > p_start
                order by b.start_date limit 1);
    if v_next.id is not null and p_end is not null and v_next.start_date <> p_end + 1 then
      raise exception '与下一个月重叠或留空：下一月开始于 %，本月应结束于 %',
        public.fmt_cn_date(v_next.start_date), public.fmt_cn_date(v_next.start_date - 1);
    end if;
    if v_next.id is not null and p_end is null then
      raise exception '后面已经有月周期（% 起），不能把本月设成进行中', public.fmt_cn_date(v_next.start_date);
    end if;
  end if;

  v_pk := to_char(p_start, 'YYYY-MM-DD');
  v_at := case when p_end is null then null
               else (p_end + 1)::timestamp at time zone 'Asia/Shanghai' end;

  select * into v_b from public.boundaries
   where type = p_type and start_date = p_start;
  if v_b.id is null then
    insert into public.boundaries (type, period_key, boundary_at, label, is_manual,
                                   start_date, end_date, rule_weeks, settled)
    values (p_type, v_pk, v_at,
            case when p_type = 'week' then '周 ' || v_pk else '月 ' || v_pk end,
            true, p_start, p_end,
            case when p_type = 'week' then v_weeks else 1 end,
            false)
    returning * into v_new;
  else
    update public.boundaries
       set period_key = v_pk,
           boundary_at = v_at,
           end_date = p_end,
           rule_weeks = case when p_type = 'week' then v_weeks else 1 end,
           label = case when p_type = 'week' then '周 ' || v_pk else '月 ' || v_pk end,
           is_manual = true,
           settled = false
     where id = v_b.id
     returning * into v_new;
  end if;

  -- 关闭上一个月（写入结束日期）时，自动把下一月的起始日补上
  if p_type = 'month' and p_end is not null then
    if not exists (select 1 from public.boundaries w
                    where w.type = 'month' and w.deprecated = false and w.start_date = p_end + 1) then
      v_pk := to_char(p_end + 1, 'YYYY-MM-DD');
      insert into public.boundaries (type, period_key, boundary_at, label, is_manual,
                                     start_date, end_date, rule_weeks, settled)
      values ('month', v_pk, null, '月 ' || v_pk, true, p_end + 1, null, 1, false);
    end if;
  end if;

  perform public.write_audit('set_period', p_type, v_new.id::text,
    jsonb_build_object('start_date', p_start, 'end_date', p_end, 'rule_weeks', v_weeks));

  return jsonb_build_object('ok', true, 'period', to_jsonb(v_new));
end;
$$;

-- ------------------------------------------------------------
-- 8.5.3 关闭「进行中」的月：结束日默认取本周周日（所在周的 end_date）
-- ------------------------------------------------------------
create or replace function public.admin_close_period(p_end date default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b    public.boundaries;
  v_end  date;
  v_res  jsonb;
begin
  if public.caller_role() not in ('system', 'super_admin') then
    raise exception '只有管理员可以关闭月周期';
  end if;
  select * into v_b from public.boundaries
   where type = 'month' and deprecated = false and end_date is null
   order by start_date desc limit 1;
  if v_b.id is null then
    raise exception '当前没有进行中的月周期';
  end if;
  v_end := coalesce(p_end, (select w.end_date from public.boundaries w
                             where w.type = 'week' and w.deprecated = false
                               and w.start_date <= public.bj_today()
                             order by w.start_date desc limit 1));
  if v_end is null then
    raise exception '找不到可用的周周期，请先设置周周期';
  end if;
  if v_end < v_b.start_date then
    raise exception '结束日期不能早于本月的起始日期 %', public.fmt_cn_date(v_b.start_date);
  end if;
  v_res := public.admin_set_period('month', v_b.start_date, v_end, 1);
  perform public.notify_audience('admins', '月周期已关闭',
    format('月周期 %s ~ %s 已关闭，可进行月度结算', public.fmt_cn_date(v_b.start_date), public.fmt_cn_date(v_end)),
    'system', 'boundaries', v_b.id);
  return v_res;
end;
$$;

-- ------------------------------------------------------------
-- 8.5.4 补周：在 [p_from, p_to] 之间按 7 天一段补周周期（需与前后衔接）
-- ------------------------------------------------------------
create or replace function public.admin_fill_weeks(p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_d    date := p_from;
  v_cnt  int := 0;
  v_last public.boundaries;
begin
  if v_role not in ('system', 'super_admin') then
    raise exception '只有管理员可以补周周期';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception '补周区间不合法';
  end if;
  if (p_to - p_from) > 400 then
    raise exception '一次最多补 400 天，请分段执行';
  end if;
  while v_d <= p_to loop
    if not exists (select 1 from public.boundaries w
                    where w.type = 'week' and w.deprecated = false
                      and w.start_date <= v_d and coalesce(w.end_date, w.start_date) >= v_d) then
      insert into public.boundaries (type, period_key, boundary_at, label, is_manual,
                                     start_date, end_date, rule_weeks, settled)
      values ('week', to_char(v_d, 'YYYY-MM-DD'),
              (v_d + 7)::timestamp at time zone 'Asia/Shanghai',
              '周 ' || to_char(v_d, 'YYYY-MM-DD'), true, v_d, v_d + 6, 1, false)
      on conflict (type, start_date) where start_date is not null do nothing;
      v_cnt := v_cnt + 1;
    end if;
    v_d := v_d + 7;
  end loop;
  perform public.write_audit('fill_weeks', 'week', null,
    jsonb_build_object('from', p_from, 'to', p_to, 'created', v_cnt));
  return jsonb_build_object('ok', true, 'created', v_cnt,
                            'validate', public.admin_validate_periods());
end;
$$;

-- ------------------------------------------------------------
-- 8.5.5 删除周期（仅未结算、区间内无记录）
-- ------------------------------------------------------------
create or replace function public.admin_delete_period(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b   public.boundaries;
  v_n   int := 0;
begin
  if public.caller_role() not in ('system', 'super_admin') then
    raise exception '只有管理员可以删除周期';
  end if;
  select * into v_b from public.boundaries where id = p_id;
  if v_b.id is null then
    raise exception '周期不存在';
  end if;
  if v_b.settled then
    raise exception '该周期已结算/已汇总，不能删除';
  end if;
  if v_b.end_date is not null then
    select count(*) into v_n from public.records
     where status = '正常'
       and record_date >= to_char(v_b.start_date, 'YYYY-MM-DD')
       and record_date <= to_char(v_b.end_date, 'YYYY-MM-DD');
    if v_n > 0 then
      raise exception '该周期内有 % 条积分记录，不能删除', v_n;
    end if;
  end if;
  if v_b.type = 'month' and exists (select 1 from public.boundaries w
                                     where w.type = 'month' and w.deprecated = false
                                       and w.start_date = v_b.end_date + 1) then
    raise exception '后面还有月周期，不能删除本月（会断开连续性）';
  end if;
  delete from public.boundaries where id = p_id;
  perform public.write_audit('delete_period', v_b.type, p_id::text,
    jsonb_build_object('start_date', v_b.start_date, 'end_date', v_b.end_date));
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 8.5.6 周期列表（前端周期定义页）
-- ------------------------------------------------------------
create or replace function public.list_periods(p_type text default 'week', p_limit int default 40)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_rows jsonb;
begin
  if v_role not in ('system', 'super_admin', 'admin', 'executive') then
    raise exception '没有权限查看周期定义';
  end if;
  select coalesce(jsonb_agg(x order by x->>'start_date' desc), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'id', b.id,
               'type', b.type,
               'period_key', b.period_key,
               'start_date', b.start_date,
               'end_date', b.end_date,
               'rule_weeks', b.rule_weeks,
               'settled', b.settled,
               'is_manual', b.is_manual,
               'ongoing', (b.end_date is null),
               'records_count', case
                 when b.end_date is null then (
                   select count(*) from public.records r
                    where r.status = '正常'
                      and r.record_date >= to_char(b.start_date, 'YYYY-MM-DD'))
                 else (
                   select count(*) from public.records r
                    where r.status = '正常'
                      and r.record_date >= to_char(b.start_date, 'YYYY-MM-DD')
                      and r.record_date <= to_char(b.end_date, 'YYYY-MM-DD'))
               end
             ) as x
        from public.boundaries b
       where b.type = p_type and b.deprecated = false and b.start_date is not null
       order by b.start_date desc
       limit greatest(coalesce(p_limit, 40), 1)
    ) q;
  return jsonb_build_object('type', p_type, 'items', v_rows,
                            'current_key', case when p_type = 'week'
                                                then public.current_week_key()
                                                else public.current_month_key() end,
                            'validate', public.admin_validate_periods());
end;
$$;

-- ------------------------------------------------------------
-- 8.5.7 授权：仅管理员可用
-- ------------------------------------------------------------
revoke all on function public.admin_validate_periods() from public, anon;
revoke all on function public.admin_set_period(text, date, date, int) from public, anon;
revoke all on function public.admin_close_period(date) from public, anon;
revoke all on function public.admin_fill_weeks(date, date) from public, anon;
revoke all on function public.admin_delete_period(uuid) from public, anon;
revoke all on function public.list_periods(text, int) from public, anon;

grant execute on function public.admin_validate_periods() to authenticated;
grant execute on function public.admin_set_period(text, date, date, int) to authenticated;
grant execute on function public.admin_close_period(date) to authenticated;
grant execute on function public.admin_fill_weeks(date, date) to authenticated;
grant execute on function public.admin_delete_period(uuid) to authenticated;
grant execute on function public.list_periods(text, int) to authenticated;

-- ============================================================
-- 9. 最终权限收口
--   原则：anon / authenticated 对业务表“零写权限”，只有 select（且受 RLS 限制）；
--         所有写操作必须走 RPC（security definer）。app_config 连 select 都不给，只走 RPC。
--   本段在全部模块之后执行，可重复执行。
-- ============================================================

do $$
declare
  v_tables text[] := array[
    'profiles','students','records','rules','boundaries','weekly_summaries','settlements',
    'lottery_items','lottery_draws','lottery_chances','starlight_accounts','starlight_logs',
    'starlight_term_snapshots','notifications','lottery_group_chances','supervisor_assignments','audit_logs'
  ];
  t text;
begin
  foreach t in array v_tables loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
    execute format('grant select on table public.%I to authenticated', t);
  end loop;

  -- 配置表：完全只读给 RPC，不给前端直读
  execute 'alter table public.app_config enable row level security';
  execute 'revoke all on table public.app_config from anon, authenticated';
end $$;

-- 审计日志主键序列：写入由 definer 函数完成，前端无需 usage
revoke all on sequence public.audit_logs_id_seq from anon, authenticated;

-- 公开函数（登录前可调用）：登录配置 / 自助注册
grant execute on function public.get_login_config() to anon, authenticated;
do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'student_register') then
    execute 'grant execute on function public.student_register(text, text, text, text) to anon, authenticated';
  end if;
end $$;

-- ============================================================
-- 10. 迁移后自检（只读，不改任何数据）
--   用法：整份脚本跑完后，单独再跑一次本段；或直接跑 build 生成的 verify 部分。
--   若结构缺项会 raise exception 并列出缺了什么；最后一行输出统计供肉眼核对。
-- ============================================================

do $$
declare
  v_missing text := '';
  v_tables text[] := array['app_config','boundaries','weekly_summaries','settlements',
    'lottery_items','lottery_draws','lottery_chances','starlight_accounts','starlight_logs',
    'starlight_term_snapshots','notifications','lottery_group_chances','supervisor_assignments','audit_logs'];
  v_funcs text[] := array['caller_role','is_admin','is_super_admin','is_teacher','my_student_id',
    'is_supervisor_now','bj_today','current_month_key','current_week_key','boundary_of',
    'next_month_boundary_at','is_maintenance','cfg','write_audit','notify','notify_audience',
    'add_record','update_record','delete_record','admin_fix_frozen_record','admin_save_rule',
    'admin_delete_rule','admin_save_student','admin_import_students','admin_delete_student',
    'student_rankings','get_login_config','get_app_state','get_period_state','admin_save_separator_rules',
    'admin_add_boundary','admin_delete_boundary','admin_regenerate_boundaries','admin_set_config',
    'admin_toggle_maintenance','admin_set_auto_boundaries','draw_lottery','list_lottery_chances','list_lottery_draws',
    'mark_draw_used','admin_void_draw','admin_save_lottery_item','admin_delete_lottery_item',
    'weekly_snapshot','monthly_settle','maybe_run_period_jobs','admin_resettle',
  'admin_set_user_positions','admin_run_weekly_summary','admin_run_monthly_summary',
  'admin_group_week_board','admin_draw_group_manual',
    'admin_edit_boundary','admin_delete_boundaries','admin_create_immediate_boundary',
    'list_weekly_summaries','my_summaries',
    'list_group_chances','draw_group_lottery','list_summary_periods','get_period_summary',
  'starlight_table','starlight_logs','starlight_insert_log','starlight_edit_log','starlight_delete_log',
    'admin_import_records',
    'starlight_import',
    'admin_export_records',
    'starlight_export_logs',
    'admin_export_summaries',
    'starlight_batch_set_balance',
    'admin_warehouse',
    'admin_batch_mark_cards', 'admin_grant_cards'];
  t text;
  f text;
  v_cnt int;
begin
  foreach t in array v_tables loop
    if not exists (select 1 from information_schema.tables
                    where table_schema = 'public' and table_name = t) then
      v_missing := v_missing || ' 表' || t || ';';
    elsif exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                   where n.nspname = 'public' and c.relname = t and c.relrowsecurity = false) then
      v_missing := v_missing || ' 表' || t || '未启用RLS;';
    end if;
  end loop;

  -- 关键字段
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='profiles' and column_name='student_id') then
    v_missing := v_missing || ' profiles.student_id;';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='students' and column_name='user_id') then
    v_missing := v_missing || ' students.user_id;';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='records' and column_name='frozen_until') then
    v_missing := v_missing || ' records.frozen_until;';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='records' and column_name='period_key') then
    v_missing := v_missing || ' records.period_key;';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='rules' and column_name='limit_type') then
    v_missing := v_missing || ' rules.limit_type;';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='records' and column_name='rule_id') then
    v_missing := v_missing || ' records.rule_id;';
  end if;

  foreach f in array v_funcs loop
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = f) then
      v_missing := v_missing || ' 函数' || f || ';';
    end if;
  end loop;

  if v_missing <> '' then
    raise exception 'V2.0 结构自检失败，缺少：%', v_missing;
  end if;
  raise notice 'V2.0 结构自检通过';
end $$;

-- 统计核对（应看到：14 张新表、奖励池 8 条、惩罚池 20 条、规则 37 条、配置 1 行）
select '数据表总数' as 检查项, count(*)::text as 结果
  from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE'
union all
select 'RPC 函数', count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
union all
select 'RLS 策略', count(*)::text from pg_policies where schemaname = 'public'
union all
select '奖励池条目（应为 8）', count(*)::text from public.lottery_items where pool_type = 'reward'
union all
select '惩罚池条目（应为 20）', count(*)::text from public.lottery_items where pool_type = 'penalty'
union all
select '积分规则（应为 37）', count(*)::text from public.rules
union all
select '系统配置行（应为 1）', count(*)::text from public.app_config
union all
select '分隔点数量（>=12）', count(*)::text from public.boundaries
union all
select '未结算的到点分隔点（正常应为 0 或 1）', count(*)::text
  from public.boundaries where settled = false and boundary_at <= now()
union all
select '当前周 / 本月', public.current_week_key() || ' / ' || public.current_month_key();
