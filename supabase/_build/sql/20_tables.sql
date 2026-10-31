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
