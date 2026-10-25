-- ============================================================================
-- V2.0.12 补丁：小组集体抽选次数支持按周筛选（个人抽选仍按月）
-- 适用：已部署 V2.0.11 的数据库。幂等，可重复执行。
-- 内容：
--   1) list_group_chances 增加 p_week_key 参数，可按周筛选小组抽选次数
--      （小组次数本身来自每周汇总，周键形如 2026-43）
--   2) 返回值新增 week_key，便于前端显示「第几周」
-- 执行后建议：notify pgrst, 'reload schema';
-- ============================================================================

drop function if exists public.list_group_chances(text);
create or replace function public.list_group_chances(p_period_key text default null, p_week_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_me     text := public.my_group_name();
  v_period text := coalesce(nullif(btrim(coalesce(p_period_key, '')), ''), public.current_month_key());
  v_week   text := nullif(btrim(coalesce(p_week_key, '')), '');
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  return jsonb_build_object(
    'period_key', v_period,
    'week_key', coalesce(v_week, public.current_week_key()),
    'scope', case when v_role in ('super_admin','admin','executive') then 'all' else 'group' end,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id,
               'group_name', c.group_name,
               'pool_type', c.pool_type,
               'chance_type', c.chance_type,
               'period_key', c.period_key,
               'source_week_key', c.source_week_key,
               'amount', c.amount,
               'used_count', c.used_count,
               'remaining', greatest(c.amount - c.used_count, 0),
               'note', c.note,
               'members_count', (select count(*) from public.students s where s.group_name = c.group_name)
             ) order by c.created_at, c.id)
        from public.lottery_group_chances c
       where c.period_key = v_period
         and (v_week is null or c.source_week_key = v_week)
         and (v_role in ('super_admin','admin','executive') or c.group_name = v_me)
    ), '[]'::jsonb)
  );
end;
$$;
revoke all on function public.list_group_chances(text, text) from public, anon, authenticated;
grant execute on function public.list_group_chances(text, text) to authenticated;

-- 自检（应返回 1 行，参数为 p_period_key text, p_week_key text）
select p.proname, pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'list_group_chances';
