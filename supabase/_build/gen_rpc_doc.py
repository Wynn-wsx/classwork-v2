# -*- coding: utf-8 -*-
"""从各 SQL 模块生成 RPC 接口清单（开发文件/docs/V2.0_RPC接口清单.md）。"""
import re
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.path.join(HERE, "sql")
OUT = os.path.join(HERE, "..", "..", "docs", "V2.0_RPC接口清单.md")

FILES = [
    ("50_records.sql", "积分登记与排名"),
    ("51_config_period.sql", "时间规则 / 系统配置"),
    ("52_lottery.sql", "奖惩抽选 / 卡片仓库"),
    ("53_period_jobs.sql", "周月结算 / 汇总查询"),
    ("54_accounts.sql", "账号与用户管理"),
    ("55_notify_appeals.sql", "通知 / 监督委员 / 星光"),
    ("56_admin_data.sql", "备份导出 / 恢复 / 清理 / 审计"),
    ("57_admin_ops.sql", "手动汇总 / 职务"),
    ("59_ops_v205.sql", "分隔点编辑 / 周期汇总查看"),
    ("61_ops_v208.sql", "星光台账表格预览 / 流水编辑"),
    ("62_ops_v209.sql", "数据导入导出 / 仓库管理 / 批量标记"),
    ("63_ops_v211.sql", "手动发放卡片"),
    ("64_ops_v214.sql", "小组人工抽奖看板"),
    ("65_ops_v219.sql", "周期定义（起止日期）/ 一致性检查"),
]

FUNC_RE = re.compile(
    r"create\s+or\s+replace\s+function\s+public\.(\w+)\s*\((.*?)\)\s*returns\s+([\w.]+)",
    re.I | re.S,
)
INTERNAL = {"_pick_lottery_item", "_apply_draw", "auto_draw_chances", "check_rule_limit",
            "ensure_boundaries", "expire_function_cards", "write_audit", "notify",
            "notify_audience"}


def clean_comment(lines):
    out = []
    for ln in lines:
        t = ln.strip()
        if not t.startswith("--"):
            continue
        t = t[2:].strip(" -")
        if not t or t.startswith("---"):
            continue
        # 跳过标题性噪声
        if re.match(r"^\d+(\.\d+)?\s", t) and len(t) < 8:
            continue
        out.append(t)
    return out


def main():
    parts = ["# V2.0 RPC 接口清单\n",
             "> 由 `_build/gen_rpc_doc.py` 从 SQL 模块自动生成，接口有变动请改 SQL 后重新生成。\n",
             "> 所有函数均为 `security definer`，前端只能通过 `supabase.rpc(名称, 参数)` 调用；业务表前端无写权限。\n",
             "> 权限列取自函数注释，具体判定逻辑以 SQL 为准。\n"]
    total = 0
    for fname, title in FILES:
        path = os.path.join(SQL_DIR, fname)
        if not os.path.exists(path):
            continue
        text = open(path, encoding="utf-8").read()
        rows = []
        for m in FUNC_RE.finditer(text):
            name, args, ret = m.group(1), m.group(2).strip(), m.group(3).lower()
            # 往上收集紧邻的注释行
            head = text[:m.start()].rstrip("\n").split("\n")
            cmt = []
            for ln in reversed(head):
                if ln.strip().startswith("--"):
                    cmt.append(ln)
                else:
                    break
            cmt = clean_comment(list(reversed(cmt)))
            desc = " / ".join(cmt[-3:]) if cmt else ""
            if name in INTERNAL:
                desc = ("【内部函数，前端不可调用】" + desc).strip()
            args_norm = re.sub(r"\s+", " ", args).strip() or "（无）"
            rows.append((name, args_norm, ret, desc))
        if not rows:
            continue
        total += len(rows)
        parts.append(f"\n## {title}（`{fname}`，{len(rows)} 个）\n")
        parts.append("| 函数 | 参数 | 返回 | 说明 |")
        parts.append("|---|---|---|---|")
        for name, args, ret, desc in rows:
            desc = desc.replace("|", "\\|")
            parts.append(f"| `{name}` | `{args}` | `{ret}` | {desc} |")
    parts.append(f"\n---\n\n共 **{total}** 个 RPC。\n")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    open(OUT, "w", encoding="utf-8").write("\n".join(parts) + "\n")
    print("写入", os.path.normpath(OUT), "共", total, "个 RPC")


if __name__ == "__main__":
    main()
