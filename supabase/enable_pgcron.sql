-- ============================================================
-- 定时作业（pg_cron）——已于 2026-10-31 取消
--   现状：系统不再自动跑「周汇总 / 月结算」，全部由管理员手动触发：
--     · 周汇总：周期汇总 → 周汇总 → 「立即汇总上周」/「重新汇总该周期」
--     · 月结算：周期汇总 → 月度结算 → 「立即结算上月」/「重新结算该周期」
--   本文件保留「取消/清理」脚本，以及恢复自动化的完整写法（默认不启用）。
-- ============================================================

-- 1. 取消已存在的自动作业（可重复执行；没有 pg_cron 的库会跳过）
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'banji_period_jobs') then
      perform cron.unschedule('banji_period_jobs');
      raise notice '已取消定时作业 banji_period_jobs';
    else
      raise notice '没有找到定时作业 banji_period_jobs，无需取消';
    end if;
    -- 清理历史上可能用过的临时作业名
    if exists (select 1 from cron.job where jobname = 'banji_period_jobs_fast') then
      perform cron.unschedule('banji_period_jobs_fast');
      raise notice '已取消临时定时作业 banji_period_jobs_fast';
    end if;
  else
    raise notice '本库未启用 pg_cron，无需取消';
  end if;
end $$;

-- 2. 检查：应返回 0 行
select jobid, jobname, schedule, command, active
  from cron.job
 where jobname like 'banji%';

-- ============================================================
-- 3. 如需恢复自动作业（默认不要执行），取消下面注释后执行：
-- ------------------------------------------------------------
-- create extension if not exists pg_cron;
-- select cron.schedule(
--   'banji_period_jobs',
--   '*/10 * * * *',
--   $$select public.maybe_run_period_jobs();$$
-- );
-- select public.maybe_run_period_jobs() as first_run;   -- 手动跑一次验证
-- select jobid, jobname, schedule, active from cron.job where jobname = 'banji_period_jobs';
-- ============================================================
