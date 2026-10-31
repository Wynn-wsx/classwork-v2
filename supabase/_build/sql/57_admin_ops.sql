-- ============================================================
-- 7. 管理员运维：用户职务标签 / 手动汇总（覆盖重算）
-- ============================================================

-- ------------------------------------------------------------
-- 7.1 用户职务标签
-- 说明：除班主任外，执行管理/记录员等角色往往是学生兼任（团支书、班长、纪律委员……），
--       用 positions 文本数组记录这些标识，仅作展示与筛选，不参与权限判断。
-- ------------------------------------------------------------
alter table public.profiles add column if not exists positions text[] not null default '{}';

create or replace function public.admin_set_user_positions(p_id uuid, p_positions text[])
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text;
  v_arr   text[] := '{}';
  v_x     text;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  if p_id is null then
    raise exception '请选择用户';
  end if;
  select p.role into v_role from public.profiles p where p.id = p_id;
  if v_role is null then
    raise exception '用户不存在';
  end if;

  if p_positions is not null then
    foreach v_x in array p_positions loop
      v_x := btrim(coalesce(v_x, ''));
      if v_x <> '' and char_length(v_x) <= 20 and not (v_x = any(v_arr)) then
        v_arr := array_append(v_arr, v_x);
      end if;
      exit when array_length(v_arr, 1) >= 8;
    end loop;
  end if;

  update public.profiles
     set positions = v_arr,
         updated_at = now()
   where id = p_id;

  perform public.write_audit('admin_set_user_positions', 'profile', p_id::text,
    jsonb_build_object('username', (select p.username from public.profiles p where p.id = p_id),
                       'positions', to_jsonb(v_arr)));
end;
$$;
revoke all on function public.admin_set_user_positions(uuid, text[]) from public, anon, authenticated;
grant execute on function public.admin_set_user_positions(uuid, text[]) to authenticated;

-- ------------------------------------------------------------
-- 7.2 手动周汇总（覆盖重算）
-- 同一周期多次汇总：先清掉该周期已有结果，再按最新数据重新生成，保证“最新覆盖旧结果”。
-- ------------------------------------------------------------
create or replace function public.admin_run_weekly_summary(p_boundary_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b      public.boundaries;
  v_key    text;
  v_month  text;
  v_res    jsonb;
  v_added  int := 0;
  v_draws  int := 0;
begin
  perform public.require_role(array['super_admin','admin','executive'], '只有管理员、班主任或执行小组可以手动汇总');

  if p_boundary_id is null then
    select * into v_b from public.boundaries
     where type = 'week' and boundary_at <= now()
     order by boundary_at desc limit 1;
  else
    select * into v_b from public.boundaries where id = p_boundary_id;
  end if;

  if v_b.id is null then
    raise exception '没有找到可汇总的周分隔点';
  end if;
  if v_b.type <> 'week' then
    raise exception '该分隔点不是周分隔点';
  end if;
  if v_b.boundary_at > now() then
    raise exception '该周尚未结束，不能汇总';
  end if;

  -- 周分隔点关闭的是「上一周」，周期键必须按关闭的那一周推导（不能用分隔点自身所在周）
  v_key   := v_b.period_key;
  v_month := coalesce(public.period_key_of('month', v_b.end_date), public.current_month_key());

  -- 覆盖：清掉本周期已有结果
  delete from public.weekly_summaries where boundary_id = v_b.id;
  delete from public.lottery_chances
   where chance_type = 'weekly_group'
     and source_week_key = v_key;
  delete from public.lottery_group_chances where source_week_key = v_key;
  delete from public.lottery_draws
   where source in ('monthly_group_penalty', 'weekly_group_penalty', 'weekly_group_reward')
     and period_key = v_month;
  update public.boundaries set settled = false where id = v_b.id;

  v_res   := public.weekly_snapshot(v_b.id);
  v_added := coalesce((v_res->>'reward_group_chances')::int, 0);
  v_draws := coalesce((v_res->>'penalty_group_chances')::int, 0);

  perform public.write_audit('admin_run_weekly_summary', 'boundary', v_b.id::text,
    jsonb_build_object('week_key', v_key, 'reward_chances', v_added, 'penalty_draws', v_draws));

  return jsonb_build_object(
    'week_key', v_key, 'boundary_id', v_b.id,
    'reward_chances', v_added, 'penalty_draws', v_draws, 'summary', v_res);
end;
$$;
revoke all on function public.admin_run_weekly_summary(uuid) from public, anon, authenticated;
grant execute on function public.admin_run_weekly_summary(uuid) to authenticated;

-- ------------------------------------------------------------
-- 7.3 手动月汇总（覆盖重算）
-- ------------------------------------------------------------
create or replace function public.admin_run_monthly_summary(p_boundary_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b   public.boundaries;
  v_key text;
  v_res jsonb;
begin
  perform public.require_role(array['super_admin','admin','executive'], '只有管理员、班主任或执行小组可以手动汇总');

  if p_boundary_id is null then
    select * into v_b from public.boundaries
     where type = 'month' and boundary_at <= now()
     order by boundary_at desc limit 1;
  else
    select * into v_b from public.boundaries where id = p_boundary_id;
  end if;

  if v_b.id is null then
    raise exception '没有找到可汇总的月分隔点';
  end if;
  if v_b.type <> 'month' then
    raise exception '该分隔点不是月分隔点';
  end if;
  if v_b.boundary_at > now() then
    raise exception '该月尚未结束，不能汇总';
  end if;

  -- 月分隔点关闭的是「上一个月」，周期键按被结算的月份推导（settlements.period_key 用的是这个）
  v_key := v_b.period_key;

  -- 覆盖：旧结算记录标记为已回滚（保留审计痕迹），清掉该月已生成的次数与自动抽选
  update public.settlements
     set status = 'rolled_back',
         note = coalesce(nullif(note, ''), '') || '（手动重新汇总覆盖）'
   where boundary_id = v_b.id
     and status <> 'rolled_back';

  delete from public.lottery_draws
   where period_key = v_key
     and source in ('auto', 'monthly_group_penalty', 'weekly_group', 'weekly_group_reward', 'weekly_group_penalty');
  delete from public.lottery_chances where period_key = v_key;
  delete from public.lottery_group_chances where period_key = v_key;
  update public.boundaries set settled = false where id = v_b.id;

  v_res := public.monthly_settle(v_b.id);

  perform public.write_audit('admin_run_monthly_summary', 'boundary', v_b.id::text,
    jsonb_build_object('month_key', v_key));

  return jsonb_build_object('month_key', v_key, 'boundary_id', v_b.id, 'summary', v_res);
end;
$$;
revoke all on function public.admin_run_monthly_summary(uuid) from public, anon, authenticated;
grant execute on function public.admin_run_monthly_summary(uuid) to authenticated;
