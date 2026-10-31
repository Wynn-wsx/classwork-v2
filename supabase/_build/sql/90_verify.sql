-- ============================================================
-- 10. 迁移后自检（只读，不改任何数据）
--   用法：整份脚本跑完后，单独再跑一次本段；或直接跑 build 生成的 verify 部分。
--   若结构缺项会 raise exception 并列出缺了什么；最后一行输出统计供肉眼核对。
-- ============================================================

do $$
declare
  v_missing text := '';
  v_tables text[] := array['app_config','boundaries','weekly_summaries','settlements',
    'lottery_items','lottery_draws','lottery_chances','starlight_accounts','starlight_logs',
    'starlight_term_snapshots','notifications','lottery_group_chances','supervisor_assignments','audit_logs'];
  v_funcs text[] := array['caller_role','is_admin','is_super_admin','is_teacher','my_student_id',
    'is_supervisor_now','bj_today','current_month_key','current_week_key','boundary_of',
    'next_month_boundary_at','is_maintenance','cfg','write_audit','notify','notify_audience',
    'add_record','update_record','delete_record','admin_fix_frozen_record','admin_save_rule',
    'admin_delete_rule','admin_save_student','admin_import_students','admin_delete_student',
    'student_rankings','get_login_config','get_app_state','get_period_state','admin_save_separator_rules',
    'admin_add_boundary','admin_delete_boundary','admin_regenerate_boundaries','admin_set_config',
    'admin_toggle_maintenance','admin_set_auto_boundaries','draw_lottery','list_lottery_chances','list_lottery_draws',
    'mark_draw_used','admin_void_draw','admin_save_lottery_item','admin_delete_lottery_item',
    'weekly_snapshot','monthly_settle','maybe_run_period_jobs','admin_resettle',
  'admin_set_user_positions','admin_run_weekly_summary','admin_run_monthly_summary',
  'admin_group_week_board','admin_draw_group_manual',
    'admin_edit_boundary','admin_delete_boundaries','admin_create_immediate_boundary',
    'list_weekly_summaries','my_summaries',
    'list_group_chances','draw_group_lottery','list_summary_periods','get_period_summary',
  'starlight_table','starlight_logs','starlight_insert_log','starlight_edit_log','starlight_delete_log',
    'admin_import_records',
    'starlight_import',
    'admin_export_records',
    'starlight_export_logs',
    'admin_export_summaries',
    'starlight_batch_set_balance',
    'admin_warehouse',
    'admin_batch_mark_cards', 'admin_grant_cards'];
  t text;
  f text;
  v_cnt int;
begin
  foreach t in array v_tables loop
    if not exists (select 1 from information_schema.tables
                    where table_schema = 'public' and table_name = t) then
      v_missing := v_missing || ' 表' || t || ';';
    elsif exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                   where n.nspname = 'public' and c.relname = t and c.relrowsecurity = false) then
      v_missing := v_missing || ' 表' || t || '未启用RLS;';
    end if;
  end loop;

  -- 关键字段
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='profiles' and column_name='student_id') then
    v_missing := v_missing || ' profiles.student_id;';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='students' and column_name='user_id') then
    v_missing := v_missing || ' students.user_id;';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='records' and column_name='frozen_until') then
    v_missing := v_missing || ' records.frozen_until;';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='records' and column_name='period_key') then
    v_missing := v_missing || ' records.period_key;';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='rules' and column_name='limit_type') then
    v_missing := v_missing || ' rules.limit_type;';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='records' and column_name='rule_id') then
    v_missing := v_missing || ' records.rule_id;';
  end if;

  foreach f in array v_funcs loop
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = f) then
      v_missing := v_missing || ' 函数' || f || ';';
    end if;
  end loop;

  if v_missing <> '' then
    raise exception 'V2.0 结构自检失败，缺少：%', v_missing;
  end if;
  raise notice 'V2.0 结构自检通过';
end $$;

-- 统计核对（应看到：14 张新表、奖励池 8 条、惩罚池 20 条、规则 37 条、配置 1 行）
select '数据表总数' as 检查项, count(*)::text as 结果
  from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE'
union all
select 'RPC 函数', count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
union all
select 'RLS 策略', count(*)::text from pg_policies where schemaname = 'public'
union all
select '奖励池条目（应为 8）', count(*)::text from public.lottery_items where pool_type = 'reward'
union all
select '惩罚池条目（应为 20）', count(*)::text from public.lottery_items where pool_type = 'penalty'
union all
select '积分规则（应为 37）', count(*)::text from public.rules
union all
select '系统配置行（应为 1）', count(*)::text from public.app_config
union all
select '分隔点数量（>=12）', count(*)::text from public.boundaries
union all
select '未结算的到点分隔点（正常应为 0 或 1）', count(*)::text
  from public.boundaries where settled = false and boundary_at <= now()
union all
select '当前周 / 本月', public.current_week_key() || ' / ' || public.current_month_key();
