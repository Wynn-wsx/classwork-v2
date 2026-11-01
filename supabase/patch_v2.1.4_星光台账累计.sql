-- =====================================================================
-- 班级积分管理系统 V2.1.4 补丁：星光台账预览改为「全部流水累计」
-- ---------------------------------------------------------------------
-- 适用：已部署 V2.0.8 及以上的库（幂等，可重复执行）
-- 内容：starlight_table 支持不传月份（p_month_key 为空）→ 变动按全部流水累计；
--       传 YYYY-MM 时仍按该月统计（向后兼容）
-- =====================================================================

create or replace function public.starlight_table(p_month_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text;
  v_month text;
  v_group text;
  v_out   jsonb;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder'],
    '没有权限查看星光台账'
  );
  v_role  := public.caller_role();
  -- 不传月份 = 统计全部流水（累计变动），表格预览已取消「统计月份」筛选
  v_month := nullif(btrim(coalesce(p_month_key, '')), '');
  if v_month is not null and v_month !~ '^\d{4}-\d{2}$' then
    raise exception '月份格式应为 YYYY-MM';
  end if;
  v_group := case when v_role = 'group_recorder' then public.my_group_name() else null end;

  with base as (
    select s.id, s.name, s.group_name,
           coalesce(a.balance, 0) as balance,
           coalesce(mc.month_change, 0) as month_change,
           coalesce(lc.log_count, 0) as log_count,
           lc.last_at as last_at,
           lc.last_note as last_note
      from public.students s
      left join public.starlight_accounts a on a.student_id = s.id
      left join (
        select l.student_id, sum(l.change_amount)::int as month_change
          from public.starlight_logs l
         where v_month is null or l.period_key = v_month
         group by l.student_id
      ) mc on mc.student_id = s.id
      left join (
        select l.student_id, count(*)::int as log_count,
               max(l.created_at) as last_at,
               (array_agg(l.note order by l.created_at desc))[1] as last_note
          from public.starlight_logs l
         group by l.student_id
      ) lc on lc.student_id = s.id
     where (v_group is null or s.group_name = v_group)
     order by coalesce(a.balance, 0) desc, s.name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id',  id,
           'name',        name,
           'group_name',  group_name,
           'balance',     balance,
           'month_change', month_change,
           'log_count',   log_count,
           'last_at',     last_at,
           'last_note',   last_note
         ) order by balance desc, name), '[]'::jsonb)
    into v_out
    from base;

  return jsonb_build_object(
    'month_key', coalesce(v_month, 'all'),
    'scope',     case when v_group is null then 'all' else 'group' end,
    'items',     v_out
  );
end;
$$;
revoke all on function public.starlight_table(text) from public, anon, authenticated;
grant execute on function public.starlight_table(text) to authenticated;

-- ---------------------------------------------------------------------
-- 自检（两行都应为 ok）
-- ---------------------------------------------------------------------
select 'starlight_table 存在' as item,
       case when count(*)=1 then 'ok' else 'missing' end as r
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='starlight_table'
union all
select '支持全部流水累计（源码含 all）',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                          where n.nspname='public' and p.proname='starlight_table'
                            and p.prosrc like '%all%') then 'ok' else 'missing' end;

-- 刷新 PostgREST 缓存，让新函数立即生效
notify pgrst, 'reload schema';
