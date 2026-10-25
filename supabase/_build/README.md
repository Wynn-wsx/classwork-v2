# `_build` 目录说明

本目录是 V2.0 数据库层的**模块化源码**与构建工具，最终交付物（`../schema.sql`、`../migration_v2.0.sql`、`../rollback_v1.6_policies.sql`）由脚本生成，**请勿手工修改生成物**。

## 结构

```
_build/
├── SPEC.md              模块契约（拼接顺序、幂等约定、函数模板）
├── build_sql.py         拼装：sql/*.sql → ../schema.sql / ../migration_v2.0.sql / ../rollback_v1.6_policies.sql
├── check_sql.py         静态检查：pglast 解析、函数签名重复、security definer/search_path、策略/授权/幂等关键字等
├── gen_rpc_doc.py       生成 ../docs/V2.0_RPC接口清单.md
├── sql/                 数据库模块（按文件名前缀顺序拼接）
│   ├── 00_header.sql / 10_extensions.sql / 20_tables.sql / 30_helpers.sql
│   ├── 40_rls.sql / 50_records.sql / 51_config_period.sql / 52_lottery.sql
│   ├── 53_period_jobs.sql / 54_accounts.sql / 55_notify_appeals.sql
│   ├── 56_admin_data.sql / 57_admin_ops.sql / 58_teardown.sql
│   ├── 59_ops_v205.sql / 60_seeds.sql / 61_ops_v208.sql
│   ├── 62_ops_v209.sql / 63_ops_v211.sql
│   └── 90_verify.sql / 95_grants.sql
├── test/                可复跑的验证脚本（PGlite 后端套件 + REST/真机前端脚本，归档用）
└── scratch/             开发期一次性补丁脚本（已并入 sql/ 模块，仅作历史留档，不要执行）
```

## 常用命令

```powershell
cd 开发文件\supabase\_build
python build_sql.py        # 重新生成 ../schema.sql / ../migration_v2.0.sql / ../rollback_v1.6_policies.sql
python check_sql.py        # 静态检查（必须通过）
python gen_rpc_doc.py      # 重新生成 RPC 清单
```

PGlite 回归（真跑 Postgres 语义）：

```powershell
# 1) 把最新 schema.sql 复制到本地 pglite 工作目录
# 2) 依次执行：
node test_schema.mjs      # 幂等（schema 跑两遍）
node test_smoke.mjs       # 主要 RPC 冒烟
node test_rls.mjs         # 越权/可见性
node test_integration.mjs # 业务流程
node test_migration.mjs   # V1.6 → V2.0 升级演练
```

> `test/` 下的脚本依赖 `K:\DEEPSEEK\work\_tmp\pglite` 环境（`@electric-sql/pglite` + `bootstrap.sql` 伪造 Supabase 的 auth schema），仅用于开发期回归，不影响交付物。
