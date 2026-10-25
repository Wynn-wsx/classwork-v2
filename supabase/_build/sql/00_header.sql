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
