# V2.0 数据库模块化构建说明（内部开发用，不交付用户）

本目录是 V2.0 数据库脚本的**唯一来源**。交付给用户的成品由 `build_sql.py` 生成到上一级目录：

- `../schema.sql`：V2.0 全量、幂等（空库初始化 + 已升级库重跑都安全）
- `../migration_v2.0.sql`：V1.6 → V2.0 增量迁移（含旧数据回填、旧对象清理；末尾附验证查询）
- `../rollback_v1.6_policies.sql`：应急回退（恢复 V1.6 直接写权限）

**禁止直接手改生成出来的三个成品文件**，改 `sql/` 模块后重新执行 `python build_sql.py`。

## 文件与拼接顺序

| 文件 | 内容 | 归属 |
|---|---|---|
| `sql/00_header.sql` | 版本与执行顺序说明 | lead |
| `sql/10_extensions.sql` | pgcrypto | lead |
| `sql/20_tables.sql` | 现有表字段变更 + 14 张新表 + 索引 + 约束 | lead |
| `sql/30_helpers.sql` | 时间/角色/配置/通知/审计等辅助函数 | lead |
| `sql/40_rls.sql` | RLS 策略 + 权限收回 | lead |
| `sql/50_records.sql` | 积分记录 RPC + 规则 CRUD + 学生档案 CRUD | lead |
| `sql/51_config_period.sql` | 配置/分隔点/周期状态/维护 RPC | lead |
| `sql/52_lottery.sql` | 抽选 RPC（池管理/抽选/仓库/次数） | lead |
| `sql/53_period_jobs.sql` | weekly_snapshot / monthly_settle / maybe_run_period_jobs / admin_resettle | lead |
| `sql/54_accounts.sql` | 账号 RPC（五级角色/批量建号/注册/审核/改密） | teammate-A |
| `sql/55_notify_appeals.sql` | 通知/申诉/监督委员/星光台账 RPC | teammate-B |
| `sql/56_admin_data.sql` | 备份导出/恢复/清空/物理删除 RPC | teammate-B |
| `sql/60_seeds.sql` | app_config 单行、分隔点预生成、奖池 8 卡、惩罚 20 条、默认账号、37 条规则 | lead |
| `sql/95_grants.sql` | 最终 grant/revoke（函数与表） | lead |
| `sql/90_verify.sql` | 迁移后自检查询（只读，输出统计） | lead |

## 硬性约定（每个模块都必须遵守）

1. **幂等**：所有语句可重复执行。建表 `create table if not exists`；加字段 `alter table … add column if not exists`；函数一律 `create or replace function`；策略 `drop policy if exists … ; create policy …`；种子数据必须带 `where not exists` / `on conflict do nothing`。
2. **函数模板**：`language plpgsql`，`security definer`，**必须** `set search_path = public, extensions`；异常信息用中文「没有权限执行此操作」「…已冻结」「…已超出上限」。
3. **权限判断只用** `public.caller_role()`（内置：`'system'`=SQL Editor/pg_cron，`'anon'`，`'none'`=未激活，或五级角色之一）。**不要**用 `auth_role()`、不要直接读 `auth.jwt()`、不要用 `current_user` 判断调用者（security definer 里 current_user 恒为属主）。
4. **一切写操作走 RPC**：authenticated/anon 没有任何表的 insert/update/delete 权限，只有 select（且受 RLS 限制）。RPC 内部不做 RLS 依赖，自己做权限校验。
5. **审计**：凡是改数据/改权限/结算/清零的动作，末尾调用 `perform public.write_audit(动作, 目标类型, 目标id::text, detail jsonb)`。
6. **通知**：需要通知时调用 `perform public.notify(...)` / `public.notify_audience(...)`。
7. 返回 jsonb（列表用 `jsonb_agg` 或 `to_jsonb`），单条操作用 `returns void` 或 `returns jsonb`，失败即 `raise exception`。
8. 时间一律东八区：用 `public.bj_today()`、`public.bj_month_key(ts)`、`public.bj_week_start(date)`；DB 存 `timestamptz`。
9. 不要新建表/列；确实需要时先告诉 lead。
10. 不要改 `sql/20_tables.sql` `sql/30_helpers.sql` 里的对象（另两个模块的作者也在用），缺什么函数先找 lead 加。

## 20_tables 已定结构（可直接读文件确认）

现有表（已存在，V2 变更）：`profiles`（+student_id/status/must_change_password，role 加 super_admin、student）、`students`（+user_id）、`rules`（+limit_type/limit_value）、`records`（+rule_id/frozen_until/period_key）。

新表：`app_config`、`boundaries`、`weekly_summaries`、`settlements`、`lottery_items`、`lottery_draws`、`lottery_chances`、`starlight_accounts`、`starlight_logs`、`starlight_term_snapshots`、`notifications`、`appeals`、`supervisor_assignments`、`audit_logs`。

## 30_helpers 可用函数（签名与语义）

### 身份
- `public.caller_role() returns text` — 见约定 3。
- `public.is_admin() returns bool` — super_admin/admin。
- `public.is_super_admin() returns bool`
- `public.is_teacher() returns bool` — super_admin/admin/executive。
- `public.my_profile_id() returns uuid` — auth.uid()。
- `public.my_student_id() returns uuid` — 当前登录账号绑定的 students.id（profiles.student_id）。
- `public.my_group_name() returns text` — 当前账号小组（profiche.group_name，记录员用）。
- `public.is_supervisor_now() returns bool` — 当前登录学生是否是「当前周」监督委员（读 supervisor_assignments + 当前周 key，revoked_at is null）。
- `public.require_role(p_roles text[], p_msg text default '没有权限执行此操作') returns void` — 不满足则 raise（system 直接放行）。
- 便捷包装：`require_admin()`、`require_super_admin()`、`require_teacher()`。

### 时间与周期
- `public.bj_today() returns date`
- `public.bj_month_key(p_ts timestamptz default now()) returns text` — 'YYYY-MM'
- `public.bj_week_start(p_date date) returns date` — 该日期所在周的周一
- `public.current_month_key() returns text` — 最近一个已到点的月分隔点的 period_key
- `public.current_week_key() returns text`
- `public.boundary_of(p_type text) returns public.boundaries` — 最近一个已到点的指定类型分隔点行（无则返回 null 行）。
- `public.next_month_boundary_at() returns timestamptz` — 下一个未来月分隔点（算卡片有效期用）。
- `public.is_future_date(p_date date) returns bool`
- `public.is_month_frozen(p_date date) returns bool` — 该业务日期所属登记月是否已被冻结（早于当前月分隔点即冻结；C4 除外由 RPC 处理）。
- `public.is_maintenance() returns bool`
- `public.cfg() returns jsonb` — app_config 单行转 jsonb（安全，任何登录角色可调用；不含敏感字段的裁剪由 RPC 自己做）。

### 写辅助（内部用，已 revoke execute from authenticated，只能被其他 definer 函数调用）
- `public.write_audit(p_action text, p_target_type text, p_target_id text, p_detail jsonb default '{}'::jsonb)`
- `public.notify(p_recipient uuid, p_title text, p_body text, p_category text default 'system', p_related_type text default null, p_related_id uuid default null)`
- `public.notify_audience(p_audience text, p_title text, p_body text, p_category text default 'system', p_related_type text default null, p_related_id uuid default null)` — audience ∈ `all`(全部 active 账号) / `students` / `teachers`(super_admin/admin/executive/group_recorder) / `admins`(super_admin/admin) / `executive_plus`。

### 业务查询辅助
- `public.student_group(p_student_id uuid) returns text`
- `public.group_members(p_group text) returns uuid[]`

## 交付验收（lead 会跑）
- `python _build/check_sql.py`：pglast 全量语法解析 + 名字/签名静态检查。
- 每个 RPC 必须 `revoke all on function … from public` 并 `grant execute … to authenticated`（公开注册类函数额外 grant 给 anon，并在 SPEC 里注明）。
