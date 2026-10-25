#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V2.0 数据库脚本构建器

把 _build/sql/ 下的模块按固定顺序拼接成三个交付文件（写到上一级 supabase/ 目录）：
  schema.sql                  V2.0 全量、幂等（空库初始化 / 已升级库重跑都安全）
  migration_v2.0.sql          V1.6 -> V2.0 增量迁移（内容与全量一致，均为幂等；含末尾自检）
  rollback_v1.6_policies.sql  应急回退（恢复 V1.6 RLS 与前端直写权限；V2 表/函数保留）

用法：python build_sql.py
"""
import os
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.path.join(HERE, "sql")
OUT_DIR = os.path.dirname(HERE)

ORDER = [
    "00_header.sql",
    "10_extensions.sql",
    "20_tables.sql",
    "30_helpers.sql",
    "40_rls.sql",
    "50_records.sql",
    "51_config_period.sql",
    "52_lottery.sql",
    "53_period_jobs.sql",
    "54_accounts.sql",
    "55_notify_appeals.sql",
    "56_admin_data.sql",
    "57_admin_ops.sql",
    "58_teardown.sql",
    "59_ops_v205.sql",
    "60_seeds.sql",
    "61_ops_v208.sql",
    "62_ops_v209.sql",
    "63_ops_v211.sql",
    "95_grants.sql",
    "90_verify.sql",
]

TOC = """--  【脚本目录】（在 SQL Editor 里搜索下面的标题文字可快速定位）
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
"""

MIGRATION_HEADER = """-- ============================================================
--  班级积分管理系统 V2.0.0 · 数据库增量迁移脚本（V1.6 -> V2.0）
--  目标项目：Supabase（Postgres 15+）
--  生成方式：由 _build/build_sql.py 从 _build/sql/ 模块拼接，请勿手改本文件
--  生成时间：{ts}
--
--  【执行顺序 / 重要提醒】
--  1) 先备份：Supabase 控制台 → Database → Backups；或在系统内「数据导出」保存一份 JSON。
--  2) 建议先在测试项目执行一遍，确认无误再操作线上项目。
--  3) 控制台 → SQL Editor → 新建查询 → 粘贴全文 → Run（整份一次执行）。
--     * 若编辑器提示超时，就按文件开头的【脚本目录】分段复制执行
--       （先跑 1~4 段，再跑 5 段以后的函数定义，最后跑 12~14 段）；
--       本脚本全部语句都是幂等的，分几次跑不会重复建表/重复插数据。
--  4) 跑完看最后“14. 迁移后自检”的统计表，确认各项数字与预期一致。
--
--  【本脚本做了什么】
--  - 现有 4 张表加字段、放宽 role 约束（新增 super_admin / student）
--  - 新增 14 张 V2.0 业务表、索引与约束
--  - 重建 RLS：前端写入权限全部收回，所有写操作改为 RPC
--  - 新增/替换全部 V2.0 函数（积分登记、抽选、周月结算、账号、通知、申诉、星光、备份等）
--  - 回填旧数据（records.period_key、profiles.status、students.user_id 等）
--  - 种子数据：系统配置、分隔点、37 条积分规则、8 张奖励卡、20 条惩罚
--  - 末尾：结构自检 + 统计核对
--
--  【可重复执行】全部语句幂等；重复执行不会重复插入种子、不会重复建策略。
-- ============================================================
"""

ROLLBACK_SQL = r"""-- ============================================================
--  班级积分管理系统 · 应急回退脚本（V2.0 -> V1.6 读权限/写权限）
--  生成方式：由 _build/build_sql.py 生成（静态模板），请勿手改本文件
--  生成时间：__TS__
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
"""


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def main():
    missing = [n for n in ORDER if not os.path.exists(os.path.join(SQL_DIR, n))]
    if missing:
        print("缺少模块文件：" + ", ".join(missing))
        sys.exit(1)

    parts = []
    for name in ORDER:
        text = read(os.path.join(SQL_DIR, name))
        if name == "00_header.sql":
            # 全量脚本直接用模块里的头，但补上生成时间与脚本目录
            text = (text.rstrip("\n") + "\n--  生成时间：{}\n\n".format(
                datetime.now().strftime("%Y-%m-%d %H:%M:%S")) + TOC)
        parts.append(text.rstrip("\n"))

    body = "\n\n".join(parts) + "\n"
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    schema = body
    migration = MIGRATION_HEADER.format(ts=ts) + "\n" + TOC + "\n" + body
    rollback = ROLLBACK_SQL.replace("__TS__", ts)

    outputs = {
        "schema.sql": schema,
        "migration_v2.0.sql": migration,
        "rollback_v1.6_policies.sql": rollback,
    }
    for name, content in outputs.items():
        path = os.path.join(OUT_DIR, name)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        print("写入 {:32s} {:>8d} 字节".format(name, len(content.encode("utf-8"))))

    total_lines = sum(c.count("\n") for c in outputs.values())
    print("完成：{} 个文件，共 {} 行（含重复模块内容）".format(len(outputs), total_lines))


if __name__ == "__main__":
    main()
