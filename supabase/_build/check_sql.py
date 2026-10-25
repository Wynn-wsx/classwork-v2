#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V2.0 数据库脚本静态检查器（无需数据库）

检查内容：
  1. pglast 语法解析（逐模块 + 拼接后的成品文件）
  2. 函数签名重复定义（同一签名被定义两次会静默覆盖，必须报出）
  3. security definer 函数是否都带 set search_path = public, extensions
  4. grant/revoke execute 引用的函数是否都存在
  5. create policy 引用的表是否存在、每张表是否启用 RLS
  6. 期望的函数清单是否齐全、是否出现被禁用的 auth_role()/auth.jwt() 调用
  7. 编码/换行/BOM 检查

用法：python check_sql.py
失败时返回非 0，并列出全部问题。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.path.join(HERE, "sql")
OUT_DIR = os.path.dirname(HERE)

ORDER = [
    "00_header.sql", "10_extensions.sql", "20_tables.sql", "30_helpers.sql", "40_rls.sql",
    "50_records.sql", "51_config_period.sql", "52_lottery.sql", "53_period_jobs.sql",
    "54_accounts.sql", "55_notify_appeals.sql", "56_admin_data.sql", "57_admin_ops.sql",
    "58_teardown.sql", "59_ops_v205.sql", "60_seeds.sql", "61_ops_v208.sql", "62_ops_v209.sql", "63_ops_v211.sql",
    "95_grants.sql", "90_verify.sql",
]

EXPECTED_FUNCS = [
    "admin_import_records",
    "starlight_import",
    "admin_export_records",
    "starlight_export_logs",
    "admin_export_summaries",
    "starlight_batch_set_balance",
    "admin_warehouse",
    "admin_batch_mark_cards",
    "admin_grant_cards",

    "caller_role", "is_admin", "is_super_admin", "is_teacher", "my_student_id",
    "is_supervisor_now", "bj_today", "current_month_key", "current_week_key", "boundary_of",
    "next_month_boundary_at", "is_maintenance", "cfg", "write_audit", "notify", "notify_audience",
    "add_record", "update_record", "delete_record", "admin_fix_frozen_record", "admin_save_rule",
    "admin_delete_rule", "admin_save_student", "admin_import_students", "admin_delete_student",
    "student_rankings", "get_login_config", "get_app_state", "get_period_state",
    "admin_save_separator_rules", "admin_add_boundary", "admin_delete_boundary",
    "admin_regenerate_boundaries", "admin_set_config", "admin_toggle_maintenance", "admin_set_auto_boundaries",
    "draw_lottery", "list_lottery_chances", "list_lottery_draws", "mark_draw_used",
    "admin_void_draw", "admin_save_lottery_item", "admin_delete_lottery_item",
    "weekly_snapshot", "monthly_settle", "maybe_run_period_jobs", "admin_resettle",
    "list_weekly_summaries", "my_summaries",
    "admin_set_user_positions", "admin_run_weekly_summary", "admin_run_monthly_summary",
    "admin_edit_boundary", "admin_delete_boundaries", "admin_create_immediate_boundary",
    "list_summary_periods", "get_period_summary",
    "list_group_chances", "draw_group_lottery",
    "starlight_table", "starlight_logs", "starlight_insert_log", "starlight_edit_log", "starlight_delete_log",
]

errors = []
warnings = []


def err(msg):
    errors.append(msg)


def warn(msg):
    warnings.append(msg)


def split_args(argstr):
    """按顶层逗号切分参数列表"""
    out, depth, buf = [], 0, ""
    for ch in argstr:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(buf.strip())
            buf = ""
        else:
            buf += ch
    if buf.strip():
        out.append(buf.strip())
    return out


def norm_arg(arg):
    a = arg.strip()
    a = re.split(r"\s+default\s+", a, flags=re.I)[0].strip()
    if a.startswith("p_") or re.match(r"^[a-zA-Z_]\w*\s+", a):
        a = re.sub(r"^[a-zA-Z_]\w*\s+", "", a, count=1)
    return re.sub(r"\s+", " ", a).lower()


def function_defs(text):
    """返回 [(name, [argtypes], 函数体片段)]"""
    res = []
    pattern = re.compile(
        r"create\s+(?:or\s+replace\s+)?function\s+public\.(\w+)\s*\((.*?)\)\s*returns",
        re.I | re.S)
    for m in pattern.finditer(text):
        name = m.group(1).lower()
        args = [norm_arg(a) for a in split_args(m.group(2))]
        # 找函数体结束（$$ 成对）
        tail = text[m.end():]
        parts = tail.split("$$")
        body = "$$".join(parts[:3]) if len(parts) >= 2 else tail[:4000]
        res.append((name, args, m.group(0) + body))
    return res


def main():
    modules = {}
    for name in ORDER:
        path = os.path.join(SQL_DIR, name)
        if not os.path.exists(path):
            err("缺少模块文件：" + name)
            continue
        raw = open(path, "rb").read()
        if raw.startswith(b"\xef\xbb\xbf"):
            err("%s 带 UTF-8 BOM" % name)
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as e:
            err("%s 不是合法 UTF-8：%s" % (name, e))
            continue
        modules[name] = text
        if "\r\n" in text:
            warn("%s 含 CRLF 换行" % name)

    if errors:
        report()
        return

    full = "\n\n".join(modules[n].rstrip("\n") for n in ORDER) + "\n"

    # 1. 语法解析
    try:
        import pglast
    except ImportError:
        err("未安装 pglast，无法做 SQL 语法解析（pip install pglast）")
        pglast = None

    if pglast:
        for name in ORDER:
            try:
                pglast.parse_sql(modules[name])
            except Exception as e:
                line = getattr(e, "location", None)
                ln = line if line else "?"
                src_lines = modules[name].split("\n")
                snippet = ""
                if isinstance(ln, int) and 0 < ln <= len(src_lines):
                    snippet = src_lines[ln - 1].strip()[:120]
                err("%s 语法错误（第 %s 行附近）：%s | %s" % (name, ln, str(e).split("\n")[0], snippet))
        try:
            stmts = pglast.parse_sql(full)
            print("pglast 解析成品文件：%d 条语句" % len(stmts))
        except Exception as e:
            line = getattr(e, "location", None)
            err("成品文件拼接后语法错误（第 %s 行）：%s" % (line, str(e).split("\n")[0]))

    # 2. 函数签名重复
    sig_seen = {}
    for mname in ORDER:
        text = modules.get(mname, "")
        for name, args, body in function_defs(text):
            key = name + "(" + ",".join(args) + ")"
            if key in sig_seen:
                err("函数签名重复定义：%s（%s 与 %s）" % (key, sig_seen[key], mname))
            else:
                sig_seen[key] = mname

    # 3. security definer / search_path
    for mname in ORDER:
        text = modules.get(mname, "")
        for m in re.finditer(r"create\s+(?:or\s+replace\s+)?function\s+public\.(\w+)", text, re.I):
            chunk = text[m.start():]
            nxt = re.search(r"create\s+(?:or\s+replace\s+)?(?:function|policy|table|index|view)",
                            chunk[10:], re.I)
            chunk = chunk[: nxt.start() + 10] if nxt else chunk[:20000]
            if "security definer" in chunk.lower() and "set search_path" not in chunk.lower():
                err("%s：函数 %s 是 security definer 但没有 set search_path" % (mname, m.group(1)))

    # 4. grant/revoke execute 的函数必须已定义
    defined = {}
    for name, args, _ in function_defs(full):
        defined.setdefault(name, set()).add(tuple(args))
    for mname in ORDER:
        text = modules.get(mname, "")
        for m in re.finditer(r"(?:grant|revoke)\s+(?:all|execute).*?on\s+function\s+public\.(\w+)", text, re.I | re.S):
            fn = m.group(1).lower()
            if fn not in defined:
                err("%s：grant/revoke 引用了未定义的函数 %s" % (mname, fn))

    # 5. 表与策略
    tables = set(re.findall(r"create\s+table\s+if\s+not\s+exists\s+public\.(\w+)", full, re.I))
    if len(tables) != 18:
        warn("建表数量为 %d（预期 18：4 张现有 + 14 张新增）" % len(tables))
    for m in re.finditer(r"create\s+policy\s+(\w+)\s+on\s+public\.(\w+)", full, re.I):
        pol, tbl = m.group(1), m.group(2).lower()
        if tbl not in tables:
            err("策略 %s 引用了未建的表 public.%s" % (pol, tbl))
    for tbl in sorted(tables):
        if not re.search(r"alter\s+table\s+public\.%s\s+enable\s+row\s+level\s+security" % tbl,
                         full, re.I):
            err("表 public.%s 没有启用 RLS" % tbl)

    # 6. 期望函数 + 禁用调用
    names = set(defined.keys())
    for fn in EXPECTED_FUNCS:
        if fn not in names:
            err("缺少期望函数：" + fn)
    for mname in ORDER:
        text = modules.get(mname, "")
        for bad in ("auth_role()", "auth_group()", "auth.jwt()"):
            if bad in text:
                err("%s：出现被禁用的调用 %s（权限判断请只用 caller_role()）" % (mname, bad))

    # 7. 幂等关键字抽查
    if "create table if not exists" not in full.lower():
        err("建表未使用 if not exists")
    if re.search(r"create\s+table\s+public\.", full, re.I):
        err("存在不带 if not exists 的建表语句")

    # 9. 调用 public.xxx( 的函数都应在某个模块里定义（捕获跨模块拼写错误）
    known_builtin = {"gen_random_uuid", "now", "hashtext", "pg_advisory_xact_lock",
                     "jsonb_build_object", "jsonb_build_array", "jsonb_agg", "row_number",
                     "random", "to_char", "coalesce", "greatest", "least", "format",
                     "crypt", "gen_salt", "set_config", "current_setting"}
    table_ctx = re.compile(r"(?:insert\s+into|from|join|update|delete\s+from|table|"
                           r"policy|index|on|references|truncate)\s+$", re.I)
    for mname in ORDER:
        text = modules.get(mname, "")
        for m in re.finditer(r"public\.(\w+)\s*\(", text):
            fn = m.group(1).lower()
            if fn in known_builtin or fn in tables:
                continue
            prev = text[max(0, m.start() - 60):m.start()]
            if table_ctx.search(prev):
                continue
            # drop function [if exists] public.xxx(...) 不是在「调用」函数，跳过
            if re.search(r"function\s+(?:if\s+exists\s+)?$", prev, re.I):
                continue
            if fn not in defined:
                err("%s：调用了未定义的函数 public.%s(...)" % (mname, fn))

    # 8. 成品文件存在性
    for name in ("schema.sql", "migration_v2.0.sql", "rollback_v1.6_policies.sql"):
        p = os.path.join(OUT_DIR, name)
        if not os.path.exists(p):
            err("成品文件缺失：%s（先运行 python build_sql.py）" % name)

    report(len(tables), len(defined), len(sig_seen))


def report(tables=0, funcs=0, sigs=0):
    print("=" * 60)
    print("模块 {} 个，表 {} 张，函数 {} 个（唯一签名 {} 个）".format(
        len(ORDER), tables, funcs, sigs))
    if warnings:
        print("\n提醒 %d 条：" % len(warnings))
        for w in warnings:
            print("  [warn] " + w)
    if errors:
        print("\n发现 %d 个问题：" % len(errors))
        for e in errors:
            print("  [ERR ] " + e)
        sys.exit(1)
    print("\n检查通过：没有发现问题。")


if __name__ == "__main__":
    main()
