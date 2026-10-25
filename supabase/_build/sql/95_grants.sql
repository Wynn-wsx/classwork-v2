-- ============================================================
-- 9. 最终权限收口
--   原则：anon / authenticated 对业务表“零写权限”，只有 select（且受 RLS 限制）；
--         所有写操作必须走 RPC（security definer）。app_config 连 select 都不给，只走 RPC。
--   本段在全部模块之后执行，可重复执行。
-- ============================================================

do $$
declare
  v_tables text[] := array[
    'profiles','students','records','rules','boundaries','weekly_summaries','settlements',
    'lottery_items','lottery_draws','lottery_chances','starlight_accounts','starlight_logs',
    'starlight_term_snapshots','notifications','lottery_group_chances','supervisor_assignments','audit_logs'
  ];
  t text;
begin
  foreach t in array v_tables loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from anon, authenticated', t);
    execute format('grant select on table public.%I to authenticated', t);
  end loop;

  -- 配置表：完全只读给 RPC，不给前端直读
  execute 'alter table public.app_config enable row level security';
  execute 'revoke all on table public.app_config from anon, authenticated';
end $$;

-- 审计日志主键序列：写入由 definer 函数完成，前端无需 usage
revoke all on sequence public.audit_logs_id_seq from anon, authenticated;

-- 公开函数（登录前可调用）：登录配置 / 自助注册
grant execute on function public.get_login_config() to anon, authenticated;
do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'student_register') then
    execute 'grant execute on function public.student_register(text, text, text, text) to anon, authenticated';
  end if;
end $$;
