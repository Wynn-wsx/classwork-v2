-- ============================================================
-- V2.0 定时作业（pg_cron）配置脚本
--   在 Supabase SQL Editor 执行一次即可；可重复执行。
--   前提：Dashboard → Database → Extensions 里已启用 pg_cron。
-- ============================================================

-- 1. 确认 pg_cron 已启用（未启用会报错，去控制台打开即可）
create extension if not exists pg_cron;

-- 2. 先删旧作业（重复执行不会重复建）
do $$
begin
  if exists (select 1 from cron.job where jobname = 'banji_period_jobs') then
    perform cron.unschedule('banji_period_jobs');
  end if;
end $$;

-- 3. 每 10 分钟检查一次：有到点未处理的周/月分隔点就执行快照/结算
--    说明：判断依据是 boundaries.boundary_at（timestamptz），与 cron 的 UTC 时区无关。
select cron.schedule(
  'banji_period_jobs',
  '*/10 * * * *',
  $$select public.maybe_run_period_jobs();$$
);

-- 4. 立即手动跑一次，验证函数可用（幂等，可随时执行）
select public.maybe_run_period_jobs() as first_run;

-- 5. 查看作业与最近执行记录
select jobid, jobname, schedule, command, active from cron.job where jobname = 'banji_period_jobs';
select jobid, status, return_message, start_time
  from cron.job_run_details
 order by start_time desc
 limit 5;

-- 6. 需要暂停时：
-- update cron.job set active = false where jobname = 'banji_period_jobs';
-- 需要彻底删除时：
-- select cron.unschedule('banji_period_jobs');
