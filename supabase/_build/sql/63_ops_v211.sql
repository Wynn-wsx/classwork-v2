-- ============================================================
-- V2.0.11 后端：仓库管理手动发卡
--   仅 super_admin / admin（管理员、班主任）可调用
--   支持「按个人」或「按小组」发放奖励卡 / 惩罚卡
--   每次发放为每名学生各生成一张互相独立的卡片（不合并为小组级记录）
-- ============================================================

create or replace function public.admin_grant_cards(
  p_pool_type   text,
  p_item_id     uuid,
  p_student_ids uuid[] default null,
  p_group_name  text   default null,
  p_note        text   default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_item   public.lottery_items;
  v_ids    uuid[];
  v_sid    uuid;
  v_draw   uuid;
  v_cnt    int := 0;
  v_scope  text;
  v_group  text;
  v_note   text;
  v_period text := public.current_month_key();
begin
  if v_role not in ('system', 'super_admin', 'admin') then
    raise exception '只有管理员或班主任可以手动发放卡片';
  end if;

  if p_pool_type not in ('reward', 'penalty') then
    raise exception '奖池类型无效：%', coalesce(p_pool_type, 'null');
  end if;

  select * into v_item from public.lottery_items where id = p_item_id;
  if v_item.id is null then
    raise exception '卡片不存在';
  end if;
  if v_item.pool_type <> p_pool_type then
    raise exception '卡片「%」不属于所选奖池', coalesce(v_item.title, '');
  end if;
  if not coalesce(v_item.is_active, true) then
    raise exception '卡片「%」已停用，不能发放', coalesce(v_item.title, '');
  end if;

  v_group := nullif(btrim(coalesce(p_group_name, '')), '');
  if v_group is not null then
    v_scope := 'group';
    select array_agg(s.id order by s.name) into v_ids
      from public.students s
     where s.group_name = v_group;
    if v_ids is null then
      raise exception '小组「%」还没有学生', v_group;
    end if;
  else
    v_scope := 'students';
    select array_agg(x order by x) into v_ids
      from (select distinct unnest(coalesce(p_student_ids, array[]::uuid[])) as x) t;
    if v_ids is null then
      raise exception '请选择要发放卡片的学生或小组';
    end if;
  end if;

  v_note := nullif(btrim(coalesce(p_note, '')), '');
  if v_note is null then
    v_note := case when v_scope = 'group' then '手动发放（小组统一发放）' else '手动发放' end;
  end if;

  foreach v_sid in array v_ids loop
    v_draw := public._apply_draw(
      v_sid,
      p_pool_type,
      v_item.id,
      v_period,
      'manual',
      coalesce(v_group, public.student_group(v_sid)),
      '[]'::jsonb,
      false,
      v_note,
      auth.uid(),
      false
    );
    v_cnt := v_cnt + 1;
    perform public.notify(
      (select p.id from public.profiles p where p.student_id = v_sid limit 1),
      '收到一张' || (case when p_pool_type = 'reward' then '奖励卡' else '惩罚卡' end),
      '「' || coalesce(v_item.title, '卡片') || '」已放入你的仓库，可在「我的仓库」查看。' ||
        case when v_scope = 'group' then '（小组统一发放）' else '' end,
      'lottery',
      'lottery_draw',
      v_draw
    );
  end loop;

  perform public.write_audit(
    'grant_cards', 'lottery_draw', null,
    jsonb_build_object(
      'scope', v_scope,
      'group_name', v_group,
      'pool_type', p_pool_type,
      'item_id', v_item.id,
      'item_title', v_item.title,
      'count', v_cnt,
      'note', v_note
    )
  );

  return jsonb_build_object(
    'ok', true,
    'scope', v_scope,
    'group_name', v_group,
    'pool_type', p_pool_type,
    'item_title', coalesce(v_item.title, ''),
    'item_kind', v_item.item_kind,
    'count', v_cnt,
    'period_key', v_period
  );
end;
$$;
revoke all on function public.admin_grant_cards(text, uuid, uuid[], text, text) from public, anon, authenticated;
grant execute on function public.admin_grant_cards(text, uuid, uuid[], text, text) to authenticated;
