-- ============================================================================
-- V2.0.19 周期数据迁移（把「分隔点」模型转成「起止日期」模型）
-- 适用：已按旧模型（boundaries.boundary_at 分隔点）跑过的库，例如开发测试库。
-- 前置：已执行最新 schema.sql（幂等，含新列 start_date/end_date/rule_weeks/deprecated
--       与新函数 admin_set_period / admin_close_period / admin_validate_periods 等）。
-- 执行环境：Supabase SQL Editor。建议先备份（数据导出）。
-- 本脚本可重复执行：每次都会按「周 → 月 → 回填 → 清理派生数据」重建周期。
--
-- 迁移策略：
--   1. 周：从 2026-06-01（周一）起按 7 天一节生成到约 2027-04；
--   2. 月：由周推导 —— 每月取该自然月内第一个周的开始日作为月开始，
--         结束日 = 下一个月开始日 - 1 天；当前月为「进行中」（结束日为空）；
--   3. 回填 records.period_key = 记录日期所属「月周期」的开始日期；
--   4. 清空按旧口径派生的汇总/结算/次数/抽选与相关通知，重新由管理员手动汇总。
-- ============================================================================

-- 1) 清空周期与派生数据 --------------------------------------------------------
delete from public.lottery_draws;
delete from public.lottery_chances;
delete from public.lottery_group_chances;
delete from public.weekly_summaries;
delete from public.settlements;
delete from public.boundaries;

-- 2) 生成周周期（2026-06-01 起 47 周，可自行调整起点与周数）---------------------
insert into public.boundaries(type, period_key, boundary_at, label, is_manual,
                              start_date, end_date, rule_weeks, settled)
select 'week',
       to_char(d::date, 'YYYY-MM-DD'),
       (((d::date) + 7)::timestamp at time zone 'Asia/Shanghai'),
       '周 ' || to_char(d::date, 'YYYY-MM-DD'),
       true,
       d::date,
       (d::date) + 6,
       1,
       false
  from generate_series(date '2026-06-01', date '2026-06-01' + 322, interval '7 day') g(d);

-- 3) 由周推导月周期 ------------------------------------------------------------
do $$
declare
  w record;
  v_mon_s date;
  v_mon_e date;
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
begin
  -- 收集每个「自然月」的第一个周开始日
  for w in
    select start_date, end_date,
           row_number() over (order by start_date) rn,
           date_trunc('month', start_date)::date as mon
      from public.boundaries
     where type = 'week'
     order by start_date
  loop
    if v_mon_s is null then
      v_mon_s := w.start_date;
    elsif w.mon > date_trunc('month', v_mon_s)::date then
      -- 关闭上一个月：结束日 = 本周开始日 - 1 天
      v_mon_e := w.start_date - 1;
      insert into public.boundaries(type, period_key, boundary_at, label, is_manual,
                                    start_date, end_date, rule_weeks, settled)
      values ('month', to_char(v_mon_s, 'YYYY-MM-DD'),
              ((v_mon_e + 1)::timestamp at time zone 'Asia/Shanghai'),
              '月 ' || to_char(v_mon_s, 'YYYY-MM-DD'),
              true, v_mon_s, v_mon_e, 1, v_mon_e < v_today);
      v_mon_s := w.start_date;
    end if;
    v_mon_e := w.end_date;
  end loop;
  -- 最后一个月先按已结束写入，随后由下面的「当前月」处理改成进行中
  insert into public.boundaries(type, period_key, boundary_at, label, is_manual,
                                start_date, end_date, rule_weeks, settled)
  values ('month', to_char(v_mon_s, 'YYYY-MM-DD'),
          ((v_mon_e + 1)::timestamp at time zone 'Asia/Shanghai'),
          '月 ' || to_char(v_mon_s, 'YYYY-MM-DD'),
          true, v_mon_s, v_mon_e, 1, v_mon_e < v_today);

  -- 只保留「当前月及以前」；当前月为进行中（结束日为空）
  select start_date into v_mon_s
    from public.boundaries
   where type = 'month' and start_date <= v_today
   order by start_date desc limit 1;
  if v_mon_s is not null then
    delete from public.boundaries where type = 'month' and start_date > v_mon_s;
    update public.boundaries
       set end_date = null, boundary_at = null
     where type = 'month' and start_date = v_mon_s;
  end if;
end $$;

-- 4) 回填记录的月周期键 --------------------------------------------------------
update public.records r
   set period_key = m.period_key
  from public.boundaries m
 where m.type = 'month'
   and r.record_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
   and r.record_date::date between m.start_date and coalesce(m.end_date, date '9999-12-31');

-- 5) 结算标记：已结束的周期置 settled=true ------------------------------------
update public.boundaries
   set settled = (coalesce(end_date, date '9999-12-31') < (now() at time zone 'Asia/Shanghai')::date)
 where true;

-- 6) 自检 ----------------------------------------------------------------------
select (select count(*) from public.boundaries where type = 'week')  as 周数,
       (select count(*) from public.boundaries where type = 'month') as 月数,
       (select count(*) from public.boundaries where type = 'month' and end_date is null) as 进行中的月,
       (select count(*) from public.records where period_key is null or period_key = '') as 未回填记录,
       public.current_week_key() as 当前周,
       public.current_month_key() as 当前月;

-- 7) 迁移后请到「设置 → 周期定义」点一次「检查周期一致性」，再到「周期汇总」手动汇总/结算需要的周期。
notify pgrst, 'reload schema';
