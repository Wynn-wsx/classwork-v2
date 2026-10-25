-- ============================================================
-- V2.0.13 修复：我的仓库只看本人
--   1) list_lottery_draws 的 p_scope='self' 优先于调用者角色
--      （学生兼任执行小组/记录员时也只返回本人卡片）
--   2) 未绑定学生档案的账号调用 self 时明确提示
-- 幂等：可重复执行
-- 适用：已部署 V2.0.12 的数据库；全新建库直接执行 schema.sql 即可
-- ============================================================

create or replace function public.list_lottery_draws(
  p_scope      text default null,
  p_status     text default null,
  p_pool       text default null,
  p_limit      int  default 300,
  p_period_key text default null
) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_role  text := public.caller_role();
  v_me    uuid := public.my_student_id();
  v_scope text;
  v_res   jsonb;
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  -- 未显式指定范围时按角色取默认：学生=本人、记录员=本组、其他=全班
  v_scope := coalesce(nullif(btrim(lower(coalesce(p_scope, ''))), ''),
                      case when v_role = 'student' then 'self'
                           when v_role = 'group_recorder' then 'group'
                           else 'all' end);
  if v_scope not in ('self', 'group', 'all') then
    raise exception '查看范围无效：%', p_scope;
  end if;
  -- 显式 self 时一律只看本人（含「学生兼任执行小组/记录员」的情况）
  if v_scope = 'self' and v_me is null then
    raise exception '当前账号没有绑定学生档案，无法查看「我的仓库」';
  end if;
  if v_scope = 'self' then
    select coalesce(jsonb_agg(x order by x->>'drawn_at' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'id', d.id, 'student_id', d.student_id, 'student_name', s.name,
               'group_name', coalesce(d.group_name, s.group_name),
               'pool_type', d.pool_type, 'item_snapshot', d.item_snapshot,
               'item_kind', d.item_kind, 'status', d.status,
               'is_group', d.is_group, 'member_ids', d.member_ids,
               'expire_at', d.expire_at, 'drawn_at', d.drawn_at, 'used_at', d.used_at, 'note', d.note,
               'source', d.source, 'period_key', d.period_key
             ) as x
        from public.lottery_draws d join public.students s on s.id = d.student_id
       where (d.student_id = v_me
              or (d.is_group and d.member_ids ? (v_me::text)))
         and (p_status is null or d.status = p_status)
         and (p_pool is null or d.pool_type = p_pool)
         and (p_period_key is null or d.period_key = p_period_key)
       order by d.drawn_at desc
       limit greatest(coalesce(p_limit, 300), 1)
    ) q;
  elsif v_scope = 'group' then
    select coalesce(jsonb_agg(x order by x->>'drawn_at' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'id', d.id, 'student_id', d.student_id, 'student_name', s.name,
               'group_name', coalesce(d.group_name, s.group_name),
               'pool_type', d.pool_type, 'item_snapshot', d.item_snapshot,
               'item_kind', d.item_kind, 'status', d.status,
               'is_group', d.is_group, 'member_ids', d.member_ids,
               'expire_at', d.expire_at, 'drawn_at', d.drawn_at, 'used_at', d.used_at, 'note', d.note,
               'source', d.source, 'period_key', d.period_key
             ) as x
        from public.lottery_draws d join public.students s on s.id = d.student_id
       where s.group_name = public.my_group_name()
         and (p_status is null or d.status = p_status)
         and (p_pool is null or d.pool_type = p_pool)
         and (p_period_key is null or d.period_key = p_period_key)
       order by d.drawn_at desc
       limit greatest(coalesce(p_limit, 300), 1)
    ) q;
  else
    select coalesce(jsonb_agg(x order by x->>'drawn_at' desc), '[]'::jsonb) into v_res from (
      select jsonb_build_object(
               'id', d.id, 'student_id', d.student_id, 'student_name', s.name,
               'group_name', coalesce(d.group_name, s.group_name),
               'pool_type', d.pool_type, 'item_snapshot', d.item_snapshot,
               'item_kind', d.item_kind, 'status', d.status,
               'is_group', d.is_group, 'member_ids', d.member_ids,
               'expire_at', d.expire_at, 'drawn_at', d.drawn_at, 'used_at', d.used_at, 'note', d.note,
               'source', d.source, 'period_key', d.period_key
             ) as x
        from public.lottery_draws d join public.students s on s.id = d.student_id
       where (p_status is null or d.status = p_status)
         and (p_pool is null or d.pool_type = p_pool)
         and (p_period_key is null or d.period_key = p_period_key)
       order by d.drawn_at desc
       limit greatest(coalesce(p_limit, 300), 1)
    ) q;
  end if;
  return jsonb_build_object('draws', v_res);
end;
$$;
revoke all on function public.list_lottery_draws(text, text, text, int, text) from public, anon, authenticated;
grant execute on function public.list_lottery_draws(text, text, text, int, text) to authenticated;


-- 执行后刷新接口缓存：
-- notify pgrst, 'reload schema';

-- 自检：应为 1 行
select p.proname, pg_get_function_identity_arguments(p.oid) as args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'list_lottery_draws';
