-- ============================================================
-- V2.0.9 热修复：小组集体抽选的星光重复入账
-- 现象：小组集体抽到「3 星光卡」，组内 7 人每人被入账 7×3=21 星光（共 49 条流水）。
-- 原因：draw_group_lottery 逐成员各写一条抽选记录，而 _apply_draw 在 is_group 时会
--       再给全组每人入账一次，形成 N×N 重复。
-- 修复：_apply_draw 增加 p_credit_all_members 参数（默认 true 保持旧行为）；
--       draw_group_lottery 生成成员卡片时传 false，星光只入账给卡片所属成员，
--       每人的卡片仍各自独立（可分别标记使用）。
-- 影响：只改函数，不动数据；已重复入账的历史数据需按备份/手工修正。
-- 幂等：可重复执行。
-- ============================================================

drop function if exists public._apply_draw(uuid, text, uuid, text, text, text, jsonb, boolean, text, uuid);
create or replace function public._apply_draw(
  p_student_id uuid,
  p_pool_type  text,
  p_item_id    uuid,
  p_period_key text,
  p_source     text,
  p_group_name text    default null,
  p_member_ids jsonb   default '[]'::jsonb,
  p_is_group   boolean default false,
  p_note       text    default null,
  p_drawn_by   uuid    default null,
  p_credit_all_members boolean default true
) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_item      public.lottery_items;
  v_draw_id   uuid;
  v_expire    timestamptz;
  v_status    text;
  v_note      text;
  v_member    jsonb;
  v_mid       uuid;
begin
  select * into v_item from public.lottery_items where id = p_item_id;
  if v_item.id is null then
    raise exception '抽选条目不存在';
  end if;

  v_expire := case v_item.validity_type
    when 'month_boundary' then public.next_month_boundary_at()
    when 'days' then now() + make_interval(days => coalesce(v_item.validity_days, 0))
    when 'fixed' then v_item.valid_until
    else null
  end;

  v_status := case when v_item.item_kind = 'func_card' then 'unused' else 'posted' end;
  v_note := coalesce(p_note, '');

  insert into public.lottery_draws (
    student_id, pool_type, item_id, item_snapshot, item_kind, starlight_amount,
    period_key, source, group_name, is_group, member_ids, drawn_by, drawn_at,
    expire_at, status, note
  ) values (
    p_student_id, p_pool_type, v_item.id, to_jsonb(v_item), v_item.item_kind, v_item.starlight_amount,
    p_period_key, p_source, p_group_name, p_is_group,
    coalesce(p_member_ids, '[]'::jsonb), p_drawn_by, now(),
    v_expire, v_status, v_note
  ) returning id into v_draw_id;

  -- 星光类条目：即时入账（星光卡 +N / 扣星光 -N）
  if v_item.item_kind in ('starlight', 'starlight_penalty') then
    if p_credit_all_members and p_is_group and jsonb_typeof(coalesce(p_member_ids,'[]'::jsonb)) = 'array'
       and jsonb_array_length(p_member_ids) > 0 then
      for v_member in select * from jsonb_array_elements(p_member_ids) loop
        v_mid := (v_member #>> '{}')::uuid;
        insert into public.starlight_accounts (student_id, balance, updated_at)
        values (v_mid, v_item.starlight_amount, now())
        on conflict (student_id) do update
          set balance = public.starlight_accounts.balance + excluded.balance,
              updated_at = now();
        insert into public.starlight_logs (student_id, change_amount, source, related_draw_id,
                                           period_key, note, operator_id)
        values (v_mid, v_item.starlight_amount,
                case when v_item.item_kind = 'starlight' then 'starlight_card' else 'penalty' end,
                v_draw_id, p_period_key, '小组共担：' || v_item.title, p_drawn_by);
      end loop;
    else
      insert into public.starlight_accounts (student_id, balance, updated_at)
      values (p_student_id, v_item.starlight_amount, now())
      on conflict (student_id) do update
        set balance = public.starlight_accounts.balance + excluded.balance,
            updated_at = now();
      insert into public.starlight_logs (student_id, change_amount, source, related_draw_id,
                                         period_key, note, operator_id)
      values (p_student_id, v_item.starlight_amount,
              case when v_item.item_kind = 'starlight' then 'starlight_card' else 'penalty' end,
              v_draw_id, p_period_key, v_item.title, p_drawn_by);
    end if;
  end if;

  return v_draw_id;
end;
$$;
revoke all on function public._apply_draw(uuid, text, uuid, text, text, text, jsonb, boolean, text, uuid, boolean) from public, anon, authenticated;

create or replace function public.draw_group_lottery(
  p_group_name text,
  p_pool_type  text default 'reward',
  p_chance_id  uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role    text := public.caller_role();
  v_group   text := nullif(btrim(coalesce(p_group_name, '')), '');
  v_chance  public.lottery_group_chances;
  v_item    public.lottery_items;
  v_members jsonb;
  v_ids     uuid[] := '{}';
  v_draw_id uuid;
  v_prof    uuid;
  v_cnt     int := 0;
  v_period  text;
begin
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能抽选';
  end if;
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  if v_group is null then
    raise exception '请选择小组';
  end if;
  if p_pool_type not in ('reward','penalty') then
    raise exception '奖池类型不合法';
  end if;

  -- 权限：老师/执行小组可代任意组；本组成员（含学生本人、记录员）可代表本组抽选
  if v_role in ('system','super_admin','admin','executive') then
    null;
  elsif v_role in ('group_recorder','student') then
    if v_group is distinct from public.my_group_name() then
      raise exception '只能代表自己所在的小组抽选';
    end if;
  else
    raise exception '没有权限进行小组抽选';
  end if;

  -- 同一小组同一奖池同一周期串行执行：多人同时点，只有最早一次写入生效
  perform pg_advisory_xact_lock(hashtext('group_draw:' || v_group || ':' || p_pool_type || ':' || public.current_month_key()));

  select * into v_chance
    from public.lottery_group_chances c
   where (p_chance_id is null or c.id = p_chance_id)
     and c.group_name = v_group
     and c.pool_type = p_pool_type
     and c.used_count < c.amount
     and c.period_key = public.current_month_key()
   order by c.created_at, c.id
   limit 1
   for update;
  if v_chance.id is null then
    -- 已经抽过（或被别的成员抢先写完）时，按最早一次为准给出明确提示
    declare
      v_earliest record;
    begin
      select d.drawn_at, coalesce(pr.name, '其他成员') as who
        into v_earliest
        from public.lottery_draws d
        left join public.profiles pr on pr.id = d.drawn_by
       where d.group_name = v_group and d.is_group
         and d.source = 'weekly_group_' || p_pool_type
         and d.period_key = public.current_month_key()
       order by d.drawn_at
       limit 1;
      if v_earliest.drawn_at is not null then
        raise exception '「%」小组本轮%抽选已由 % 于 % 完成，以最早一次写入为准',
          v_group,
          case when p_pool_type = 'reward' then '奖励' else '惩罚' end,
          v_earliest.who,
          to_char(v_earliest.drawn_at at time zone 'Asia/Shanghai', 'MM-DD HH24:MI');
      end if;
    end;
    raise exception '「%s」小组本周没有可用的%s抽选次数', v_group,
      case when p_pool_type = 'reward' then '奖励' else '惩罚' end;
  end if;

  v_period  := v_chance.period_key;
  v_members := to_jsonb(public.group_members(v_group));
  v_item    := public._pick_lottery_item(p_pool_type);

  if v_item.id is null then
    insert into public.lottery_draws (student_id, pool_type, item_id, item_snapshot, item_kind,
      period_key, source, group_name, is_group, member_ids, status, note)
    values (null, p_pool_type, null, '{}'::jsonb, 'plain_text',
      v_period, 'weekly_group_' || p_pool_type, v_group, true, v_members, 'void',
      '本期奖池为空，未抽中');
    update public.lottery_group_chances set used_count = used_count + 1 where id = v_chance.id;
    return jsonb_build_object('ok', true, 'group_name', v_group, 'empty', true, 'draws', '[]'::jsonb);
  end if;

  -- 全组每人各得一份
  for v_prof in
    select s.id from public.students s where s.group_name = v_group order by s.created_at, s.id
  loop
    v_draw_id := public._apply_draw(v_prof, p_pool_type, v_item.id, v_period,
      'weekly_group_' || p_pool_type, v_group, v_members, true,
      format('小组集体抽选（%s）', v_chance.source_week_key), auth.uid(), false);
    v_ids := v_ids || v_draw_id;
    v_cnt := v_cnt + 1;
  end loop;

  update public.lottery_group_chances
     set used_count = used_count + 1
   where id = v_chance.id;

  -- 通知全组成员
  for v_prof in
    select p.id from public.profiles p
      join public.students s on s.id = p.student_id
     where s.group_name = v_group and p.status = 'active'
  loop
    perform public.notify(v_prof, '小组集体抽选结果',
      format('你所在的「%s」小组抽中：%s', v_group, v_item.title),
      'lottery', 'lottery_draw', v_ids[1]);
  end loop;

  perform public.write_audit('draw_group_lottery', 'lottery_draw', v_ids[1]::text,
    jsonb_build_object('group_name', v_group, 'pool', p_pool_type,
      'members', v_cnt, 'item', v_item.title, 'source_week', v_chance.source_week_key));

  return jsonb_build_object(
    'ok', true,
    'group_name', v_group,
    'pool_type', p_pool_type,
    'item', to_jsonb(v_item),
    'members', v_cnt,
    'draws', (select coalesce(jsonb_agg(to_jsonb(d) order by d.drawn_at), '[]'::jsonb)
                from public.lottery_draws d where d.id = any(v_ids))
  );
end;
$$;
revoke all on function public.draw_group_lottery(text, text, uuid) from public, anon, authenticated;
grant execute on function public.draw_group_lottery(text, text, uuid) to authenticated;

-- 自检：确认 _apply_draw 新签名存在、且小组抽选函数已更新
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='_apply_draw') as apply_draw_overloads,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='draw_group_lottery') as draw_group_overloads;
