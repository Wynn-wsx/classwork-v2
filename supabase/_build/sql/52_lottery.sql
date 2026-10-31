-- ============================================================
-- 5.2 奖惩抽选（两池独立 / 周月双触发 / 仓库 / 星光即时入账）
-- ============================================================

-- ------------------------------------------------------------
-- 内部：加权随机抽一条池子条目
-- ------------------------------------------------------------
create or replace function public._pick_lottery_item(p_pool text)
returns public.lottery_items
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_item public.lottery_items;
begin
  select li.* into v_item
    from (
      select i.*, sum(i.weight) over (order by i.sort_order, i.id) as cum
        from public.lottery_items i
       where i.pool_type = p_pool and i.is_active and i.weight > 0
    ) li,
    (select sum(i.weight) as total
       from public.lottery_items i
      where i.pool_type = p_pool and i.is_active and i.weight > 0) t
   where li.cum >= random() * t.total
   order by li.cum
   limit 1;
  return v_item;
end;
$$;
revoke all on function public._pick_lottery_item(text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 内部：生成一条抽选记录并立即生效（星光卡/扣星光即时入账）
--   p_is_group=true 时 member_ids 为全组成员：文本惩罚由全组共担执行，
--   星光类效果对全组成员逐一计入（共担）。
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 内部：把某人某池剩余次数全部自动抽掉（月末/结算用），返回抽了几次
-- ------------------------------------------------------------
create or replace function public.auto_draw_chances(
  p_student_id uuid,
  p_pool_type  text,
  p_period_key text,
  p_source     text default 'auto'
) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_chance  public.lottery_chances;
  v_item    public.lottery_items;
  v_left    int;
  v_done    int := 0;
  v_is_group boolean;
  v_members  jsonb;
  v_group    text;
begin
  for v_chance in
    select * from public.lottery_chances
     where student_id = p_student_id and pool_type = p_pool_type
       and period_key = p_period_key and used_count < amount
     order by created_at, id
  loop
    v_left := v_chance.amount - v_chance.used_count;
    v_is_group := v_chance.chance_type = 'group_penalty';
    v_group := public.student_group(p_student_id);
    v_members := case when v_is_group
      then to_jsonb(public.group_members(v_group))
      else '[]'::jsonb end;
    while v_left > 0 loop
      v_item := public._pick_lottery_item(p_pool_type);
      if v_item.id is null then
        -- 池子为空：落"未抽中"记录，不补抽
        insert into public.lottery_draws (student_id, pool_type, item_id, item_snapshot, item_kind,
          period_key, source, group_name, is_group, member_ids, drawn_by, status, note)
        values (p_student_id, p_pool_type, null, '{}'::jsonb, 'plain_text',
          p_period_key, p_source, case when v_is_group then v_group end, v_is_group,
          v_members, null, 'void', '本期奖池为空，未抽中');
        exit;
      end if;
      perform public._apply_draw(p_student_id, p_pool_type, v_item.id, p_period_key, p_source,
                                 case when v_is_group then v_group end, v_members, v_is_group,
                                 '自动抽选', null);
      v_left := v_left - 1;
      v_done := v_done + 1;
    end loop;
    update public.lottery_chances set used_count = amount where id = v_chance.id;
  end loop;
  return v_done;
end;
$$;
revoke all on function public.auto_draw_chances(uuid, text, text, text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 抽选（学生本人；老师/执行小组可代抽）
--   小组周惩罚：由该组代表抽 1 次，全组共担（p_group_name 指定）
-- ------------------------------------------------------------
create or replace function public.draw_lottery(
  p_pool_type   text,
  p_student_id  uuid default null,
  p_group_name  text default null,
  p_count       int  default 1
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role     text := public.caller_role();
  v_target   uuid;
  v_group    text;
  v_members  jsonb;
  v_is_group boolean := false;
  v_period   text := public.current_month_key();
  v_chance   public.lottery_chances;
  v_item     public.lottery_items;
  v_left     int;
  v_ids      uuid[] := '{}';
  v_draw_id  uuid;
  v_need     int;
  v_profile  uuid;
begin
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能抽选';
  end if;
  if p_pool_type not in ('reward','penalty') then
    raise exception '奖池类型不合法';
  end if;
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;

  -- 小组周惩罚：必须有代抽权（老师/执行小组）或本组代表
  if p_group_name is not null then
    v_is_group := true;
    v_group := p_group_name;
    v_members := to_jsonb(public.group_members(v_group));
    if v_role in ('super_admin','admin','executive') then
      v_target := coalesce(p_student_id,
        (select s.id from public.students s where s.group_name = v_group order by s.created_at, s.id limit 1));
    else
      -- 周结算已由系统自动抽选；小组惩罚补抽只允许老师/执行小组
      raise exception '小组惩罚已由系统在周结算时自动抽选，如需补抽请联系老师';
    end if;
  else
    v_target := coalesce(p_student_id, public.my_student_id());
    if v_target is null then
      raise exception '请选择学生';
    end if;
    if v_role = 'student' then
      if v_target <> public.my_student_id() then
        raise exception '只能给自己抽选';
      end if;
    elsif v_role = 'group_recorder' then
      raise exception '个人抽选已收回记录员代抽权限，请学生本人抽选，或由执行小组及以上代抽';
    elsif v_role not in ('super_admin','admin','executive') then
      raise exception '没有权限抽选';
    end if;
  end if;

  v_need := greatest(coalesce(p_count, 1), 1);

  -- 小组周惩罚不需要次数（由结算触发或代表点击一次）
  if v_is_group then
    for i in 1..v_need loop
      v_item := public._pick_lottery_item('penalty');
      if v_item.id is null then
        raise exception '惩罚池暂无可抽条目';
      end if;
      v_draw_id := public._apply_draw(v_target, 'penalty', v_item.id, v_period,
        'monthly_group_penalty', v_group, v_members, true, '小组代表抽选', auth.uid());
      v_ids := v_ids || v_draw_id;
      perform public.notify_audience('all',
        '小组惩罚抽选结果',
        format('%s 抽中：%s（全组共担执行）', v_group, v_item.title),
        'lottery', 'lottery_draw', v_draw_id);
    end loop;
    perform public.write_audit('draw_group_penalty', 'lottery_draw', v_ids[1]::text,
      jsonb_build_object('group_name', v_group, 'count', v_need));
    return jsonb_build_object(
      'ok', true,
      'draws', (select coalesce(jsonb_agg(to_jsonb(d) order by d.drawn_at), '[]'::jsonb)
                  from public.lottery_draws d where d.id = any(v_ids)));
  end if;

  -- 个人抽选：消耗 lottery_chances
  v_left := v_need;
  for v_chance in
    select * from public.lottery_chances
     where student_id = v_target and pool_type = p_pool_type
       and period_key = v_period and used_count < amount
     order by created_at, id
  loop
    exit when v_left <= 0;
    while v_left > 0 and v_chance.used_count + 1 <= v_chance.amount loop
      v_item := public._pick_lottery_item(p_pool_type);
      if v_item.id is null then
        raise exception '本期奖池为空，无法抽选';
      end if;
      v_draw_id := public._apply_draw(v_target, p_pool_type, v_item.id, v_period,
        'manual', public.student_group(v_target), '[]'::jsonb, false, null, auth.uid());
      v_ids := v_ids || v_draw_id;
      v_chance.used_count := v_chance.used_count + 1;
      update public.lottery_chances set used_count = v_chance.used_count where id = v_chance.id;
      v_left := v_left - 1;
      -- 通知收件人必须是 profiles.id（notifications.recipient_id 外键指向 profiles）
      v_profile := (select p.id from public.profiles p where p.student_id = v_target limit 1);
      if v_profile is not null then
        perform public.notify(v_profile, '抽选结果',
          format('你抽中了：%s', v_item.title), 'lottery', 'lottery_draw', v_draw_id);
      end if;
    end loop;
    exit when v_left <= 0;
  end loop;

  if v_left > 0 then
    raise exception '抽选次数不足（还差 % 次）', v_left;
  end if;

  perform public.write_audit('draw_lottery', 'lottery_draw', v_ids[1]::text,
    jsonb_build_object('student_id', v_target, 'pool', p_pool_type, 'count', v_need));
  return jsonb_build_object(
    'ok', true,
    'draws', (select coalesce(jsonb_agg(to_jsonb(d) order by d.drawn_at), '[]'::jsonb)
                from public.lottery_draws d where d.id = any(v_ids)));
end;
$$;
revoke all on function public.draw_lottery(text, uuid, text, int) from public, anon, authenticated;
grant execute on function public.draw_lottery(text, uuid, text, int) to authenticated;

-- ------------------------------------------------------------
-- 次数总览（本月应得 / 已抽 / 剩余）
-- ------------------------------------------------------------
create or replace function public.list_lottery_chances(p_period_key text default null)
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_period text := coalesce(nullif(p_period_key,''), public.current_month_key());
  v_target uuid;
  v_list   jsonb;
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  if v_role in ('super_admin','admin','executive') then
    v_target := null;  -- 全班
  elsif v_role = 'group_recorder' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'student_id', c.student_id, 'student_name', s.name, 'group_name', s.group_name,
             'pool_type', c.pool_type, 'chance_type', c.chance_type,
             'amount', c.amount, 'used_count', c.used_count, 'remaining', c.amount - c.used_count,
             'source_week_key', c.source_week_key) order by s.name), '[]'::jsonb)
      into v_list
      from public.lottery_chances c
      join public.students s on s.id = c.student_id
     where c.period_key = v_period and s.group_name = public.my_group_name();
    return jsonb_build_object('period_key', v_period, 'scope', 'group', 'chances', v_list);
  else
    v_target := public.my_student_id();
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', c.student_id, 'student_name', s.name, 'group_name', s.group_name,
           'pool_type', c.pool_type, 'chance_type', c.chance_type,
           'amount', c.amount, 'used_count', c.used_count, 'remaining', c.amount - c.used_count,
           'source_week_key', c.source_week_key) order by s.name, c.pool_type), '[]'::jsonb)
    into v_list
    from public.lottery_chances c
    join public.students s on s.id = c.student_id
   where c.period_key = v_period
     and (v_target is null or c.student_id = v_target);

  return jsonb_build_object('period_key', v_period, 'scope', case when v_target is null then 'all' else 'self' end, 'chances', v_list);
end;
$$;
revoke all on function public.list_lottery_chances(text) from public, anon, authenticated;
grant execute on function public.list_lottery_chances(text) to authenticated;

-- ------------------------------------------------------------
-- 抽选结果仓库
--   p_scope: self(默认) / group / all
--   p_period_key: 周/月周期键（2026-43 或 2026-10），为空表示全部周期
-- ------------------------------------------------------------
drop function if exists public.list_lottery_draws(text, text, text, int);
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

-- ------------------------------------------------------------
-- 卡片使用/回收登记（D11：执行小组及以上；学生不能自己标记）
--   万能卡可指定兑换卡种 p_exchange_item_id → 生成新卡
-- ------------------------------------------------------------
create or replace function public.mark_draw_used(
  p_draw_id           uuid,
  p_related_record_id uuid default null,
  p_note              text default null,
  p_exchange_item_id  uuid default null,
  p_used_at           timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_draw public.lottery_draws;
  v_ex   public.lottery_items;
  v_new  uuid;
  v_role text := public.caller_role();
  v_used timestamptz := coalesce(p_used_at, now());
begin
  perform public.require_teacher();
  select * into v_draw from public.lottery_draws where id = p_draw_id;
  if v_draw.id is null then
    raise exception '抽选记录不存在';
  end if;
  if v_draw.item_kind <> 'func_card' then
    raise exception '只有功能卡需要登记使用';
  end if;
  if v_draw.status not in ('unused', 'expired') then
    raise exception '该卡片当前状态为「%」，不能登记使用', v_draw.status;
  end if;

  -- ★ 使用时间：执行小组及以上可以指定（补登记已过期但实际在有效期内使用的卡）
  if p_used_at is not null then
    if v_role not in ('system', 'super_admin', 'admin', 'executive') then
      raise exception '只有执行小组及以上权限可以指定使用时间';
    end if;
    if v_draw.drawn_at is not null and v_used < v_draw.drawn_at then
      raise exception '使用时间不能早于抽中时间（%），请重新填写', to_char(v_draw.drawn_at at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI');
    end if;
    if v_draw.expire_at is not null and v_used > v_draw.expire_at then
      raise exception '使用时间需在该卡有效期内（有效期至 %），请重新填写',
        to_char(v_draw.expire_at at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI');
    end if;
    if v_draw.expire_at is not null and v_draw.expire_at < now() and v_used <= v_draw.expire_at then
      -- 过期补登记：使用时间在有效期内，允许把 expired 恢复为 used
      update public.lottery_draws set status = 'unused' where id = p_draw_id and status = 'expired';
    end if;
  else
    if v_draw.expire_at is not null and v_draw.expire_at < now() then
      raise exception '该卡片已过期；若实际在有效期内已使用，请由执行小组及以上权限填写「使用时间」补登记';
    end if;
  end if;

  update public.lottery_draws
     set status = 'used', used_by = auth.uid(), used_at = v_used,
         related_record_id = coalesce(p_related_record_id, related_record_id),
         note = coalesce(p_note, note)
   where id = p_draw_id;

  -- 万能卡兑换：登记原卡已用 + 生成换代卡（有效期到当前月分隔点后）
  if p_exchange_item_id is not null then
    select * into v_ex from public.lottery_items where id = p_exchange_item_id;
    if v_ex.id is null then
      raise exception '兑换卡种不存在';
    end if;
    if v_ex.item_kind <> 'func_card' then
      raise exception '只能兑换为功能卡';
    end if;
    v_new := public._apply_draw(v_draw.student_id, 'reward', v_ex.id, v_draw.period_key,
      'manual', v_draw.group_name, '[]'::jsonb, false,
      '万能卡兑换自：' || coalesce(v_draw.item_snapshot->>'title',''), auth.uid());
    update public.lottery_draws set note = '已兑换为「' || v_ex.title || '」' where id = p_draw_id;
  end if;

  perform public.notify((select p.id from public.profiles p where p.student_id = v_draw.student_id limit 1),
    '卡片使用登记', format('你的「%s」已被登记为已使用。', coalesce(v_draw.item_snapshot->>'title','卡片')),
    'lottery', 'lottery_draw', p_draw_id);
  perform public.write_audit('mark_draw_used', 'lottery_draw', p_draw_id::text,
    jsonb_build_object('exchange_item_id', p_exchange_item_id, 'new_draw_id', v_new, 'note', p_note,
                       'used_at', v_used, 'backdated', (p_used_at is not null)));

  return jsonb_build_object(
    'ok', true,
    'draw_id', p_draw_id,
    'new_draw_id', v_new,
    'draw', (select to_jsonb(d) from public.lottery_draws d where d.id = p_draw_id)
  );
end;
$$;
revoke all on function public.mark_draw_used(uuid, uuid, text, uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.mark_draw_used(uuid, uuid, text, uuid, timestamptz) to authenticated;

-- ------------------------------------------------------------
-- 撤销抽选（仅未使用的功能卡；已入账星光请走星光人工调整）
-- ------------------------------------------------------------
create or replace function public.admin_void_draw(p_draw_id uuid, p_note text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_draw public.lottery_draws;
begin
  perform public.require_admin();
  select * into v_draw from public.lottery_draws where id = p_draw_id;
  if v_draw.id is null then
    raise exception '抽选记录不存在';
  end if;
  if v_draw.status <> 'unused' then
    raise exception '只有未使用的功能卡可以作废（星光类已即时入账，请用星光人工调整）';
  end if;
  update public.lottery_draws set status = 'void', note = coalesce(p_note, note) where id = p_draw_id;
  perform public.notify((select p.id from public.profiles p where p.student_id = v_draw.student_id limit 1),
    '抽选结果作废', '你的一条未使用卡片已被管理员作废。', 'lottery', 'lottery_draw', p_draw_id);
  perform public.write_audit('void_draw', 'lottery_draw', p_draw_id::text,
    jsonb_build_object('student_id', v_draw.student_id, 'title', v_draw.item_snapshot->>'title', 'note', p_note));
end;
$$;
revoke all on function public.admin_void_draw(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_void_draw(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 池子条目管理（仅 super_admin）
-- ------------------------------------------------------------
create or replace function public.admin_save_lottery_item(p_item jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id   uuid := nullif(p_item->>'id','')::uuid;
  v_row  public.lottery_items;
  v_kind text := coalesce(p_item->>'item_kind', 'plain_text');
begin
  perform public.require_super_admin();
  if coalesce(p_item->>'pool_type','') not in ('reward','penalty') then
    raise exception '奖池类型不合法';
  end if;
  if v_kind not in ('func_card','starlight','starlight_penalty','plain_text') then
    raise exception '条目类型不合法';
  end if;
  if coalesce(trim(p_item->>'title'),'') = '' then
    raise exception '请填写条目名称';
  end if;
  if coalesce((p_item->>'weight')::numeric, 1) < 0 then
    raise exception '权重不能为负';
  end if;
  if v_kind in ('starlight','starlight_penalty')
     and coalesce((p_item->>'starlight_amount')::int, 0) = 0 then
    raise exception '请填写星光数量（星光卡为正、扣星光为负）';
  end if;

  if v_id is null then
    insert into public.lottery_items (pool_type, item_kind, starlight_amount, title, description,
      weight, is_active, validity_type, validity_days, valid_until, sort_order)
    values (p_item->>'pool_type', v_kind,
      coalesce((p_item->>'starlight_amount')::int, 0), trim(p_item->>'title'),
      coalesce(p_item->>'description',''), coalesce((p_item->>'weight')::numeric, 1),
      coalesce((p_item->>'is_active')::boolean, true),
      coalesce(p_item->>'validity_type','month_boundary'),
      nullif(p_item->>'validity_days','')::int,
      nullif(p_item->>'valid_until','')::timestamptz,
      coalesce((p_item->>'sort_order')::int, 0))
    returning * into v_row;
  else
    update public.lottery_items
       set pool_type = p_item->>'pool_type',
           item_kind = v_kind,
           starlight_amount = coalesce((p_item->>'starlight_amount')::int, 0),
           title = trim(p_item->>'title'),
           description = coalesce(p_item->>'description', description),
           weight = coalesce((p_item->>'weight')::numeric, weight),
           is_active = coalesce((p_item->>'is_active')::boolean, is_active),
           validity_type = coalesce(p_item->>'validity_type', validity_type),
           validity_days = nullif(p_item->>'validity_days','')::int,
           valid_until = nullif(p_item->>'valid_until','')::timestamptz,
           sort_order = coalesce((p_item->>'sort_order')::int, sort_order)
     where id = v_id
     returning * into v_row;
    if v_row.id is null then
      raise exception '条目不存在';
    end if;
  end if;
  perform public.write_audit(case when v_id is null then 'create_lottery_item' else 'update_lottery_item' end,
    'lottery_item', v_row.id::text, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;
revoke all on function public.admin_save_lottery_item(jsonb) from public, anon, authenticated;
grant execute on function public.admin_save_lottery_item(jsonb) to authenticated;

create or replace function public.admin_delete_lottery_item(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_row public.lottery_items;
begin
  perform public.require_super_admin();
  select * into v_row from public.lottery_items where id = p_id;
  if v_row.id is null then
    raise exception '条目不存在';
  end if;
  delete from public.lottery_items where id = p_id;
  perform public.write_audit('delete_lottery_item', 'lottery_item', p_id::text, to_jsonb(v_row));
end;
$$;
revoke all on function public.admin_delete_lottery_item(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_lottery_item(uuid) to authenticated;

-- ------------------------------------------------------------
-- 过期功能卡置为已过期（结算与轮询调用）
-- ------------------------------------------------------------
create or replace function public.expire_function_cards()
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare v_count int;
begin
  update public.lottery_draws
     set status = 'expired'
   where status = 'unused' and item_kind = 'func_card'
     and expire_at is not null and expire_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function public.expire_function_cards() from public, anon, authenticated;


-- ------------------------------------------------------------
-- 5.2.9 小组集体抽选次数（V2.0.4）
--   周汇总：前 N 组各 1 次集体奖励抽选、后 N 组各 1 次小组惩罚抽选
--   抽选人：小组记录员（本组）/ 班主任、管理员、执行小组（任意组）
--   奖励抽中后全组每人各得一份；惩罚抽中后全组共担执行
-- ------------------------------------------------------------
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

  -- V2.0.14：小组抽奖收回小组记录员/学生的代抽权限，统一由执行小组及以上操作
  if v_role not in ('system','super_admin','admin','executive') then
    raise exception '小组抽奖仅限执行小组及以上操作，请在「奖惩抽选」里选择小组由班干部抽取';
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
