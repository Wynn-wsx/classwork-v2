-- ============================================================
-- 班级积分 V2.0 功能更新补丁（2026-10-25）
-- 适用：已执行过 V2.0 数据库脚本的项目（线上/测试项目均可）
-- 幂等：可重复执行
-- 内容：
--   1) profiles.positions 职务标签 + 设置 RPC
--   2) 手动周汇总 / 手动月结算 RPC（同一周期多次汇总以最新覆盖）
--   3) 学生可查看全班积分明细（只读）
--   4) 周结算小组惩罚抽选记录带周标记（便于覆盖重算时精确清理）
-- ============================================================

-- ------------------------------------------------------------
-- 1. 职务标签 + 手动汇总（新增函数）
-- ------------------------------------------------------------

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
  perform public.require_role(array['super_admin','admin'], '只有管理员或班主任可以手动汇总');

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

  v_key   := v_b.period_key;
  v_month := to_char((v_b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'YYYY-MM');

  -- 覆盖：清掉本周期已有结果
  delete from public.weekly_summaries where boundary_id = v_b.id;
  delete from public.lottery_chances
   where chance_type = 'weekly_group'
     and source_week_key = v_key;
  delete from public.lottery_draws
   where source = 'monthly_group_penalty'
     and period_key = v_month
     and note like format('周结算自动抽选（%s）%%', v_key);
  update public.boundaries set settled = false where id = v_b.id;

  v_res   := public.weekly_snapshot(v_b.id);
  v_added := coalesce((v_res->>'reward_chances_added')::int, 0);
  v_draws := coalesce((v_res->>'penalty_draws')::int, 0);

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
  perform public.require_role(array['super_admin','admin'], '只有管理员或班主任可以手动汇总');

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

  v_key := v_b.period_key;

  -- 覆盖：旧结算记录标记为已回滚（保留审计痕迹），清掉该月已生成的次数与自动抽选
  update public.settlements
     set status = 'rolled_back',
         note = coalesce(nullif(note, ''), '') || '（手动重新汇总覆盖）'
   where boundary_id = v_b.id
     and status <> 'rolled_back';

  delete from public.lottery_draws
   where period_key = v_key
     and source in ('auto', 'monthly_group_penalty', 'weekly_group');
  delete from public.lottery_chances where period_key = v_key;
  update public.boundaries set settled = false where id = v_b.id;

  v_res := public.monthly_settle(v_b.id);

  perform public.write_audit('admin_run_monthly_summary', 'boundary', v_b.id::text,
    jsonb_build_object('month_key', v_key));

  return jsonb_build_object('month_key', v_key, 'boundary_id', v_b.id, 'summary', v_res);
end;
$$;
revoke all on function public.admin_run_monthly_summary(uuid) from public, anon, authenticated;
grant execute on function public.admin_run_monthly_summary(uuid) to authenticated;


-- ------------------------------------------------------------
-- 2. 学生可查看全班积分明细（只读；写入仍走 RPC）
-- ------------------------------------------------------------

drop policy if exists records_select on public.records;
drop policy if exists records_insert on public.records;
drop policy if exists records_update on public.records;
drop policy if exists records_delete on public.records;
create policy records_select on public.records
  for select to authenticated using (
    public.is_teacher()
    or (public.caller_role() = 'group_recorder' and public.student_in_my_group(student_id))
    or public.is_supervisor_now()
    -- 学生可查看全班积分变更记录（只读，写入仍需 RPC）：既能看到自己的，也能看到同学的
    or (public.caller_role() = 'student' and coalesce(status, '') <> '已删除')
  );


-- ------------------------------------------------------------
-- 3. 用户列表返回职务标签
-- ------------------------------------------------------------

create or replace function public.list_users(p_status text default null, p_role text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_result jsonb;
begin
  if v_caller not in ('system','super_admin','admin') then
    raise exception '没有权限执行此操作';
  end if;

  -- students 用 left join 直读（security definer，不依赖 students 的 RLS）
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', p.id,
             'username', p.username,
             'name', p.name,
             'role', p.role,
             'group_name', p.group_name,
             'status', p.status,
             'student_id', p.student_id,
             'student_no', s.student_no,
             'created_at', p.created_at,
             'must_change_password', p.must_change_password,
             'positions', to_jsonb(p.positions)
           )
           order by p.created_at desc, p.username
         ), '[]'::jsonb)
    into v_result
    from public.profiles p
    left join public.students s on s.id = p.student_id
   where (p_status is null or btrim(p_status) = '' or p.status = btrim(p_status))
     and (p_role is null or btrim(p_role) = '' or p.role = btrim(p_role))
     and (v_caller <> 'admin' or p.role <> 'super_admin');

  return v_result;
end;
$$;
revoke all on function public.list_users(text,text) from public, anon, authenticated;
grant execute on function public.list_users(text,text) to authenticated;


-- ------------------------------------------------------------
-- 4. 首屏状态返回本人职务标签
-- ------------------------------------------------------------

create or replace function public.get_app_state()
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_p        public.profiles;
  v_cfg      jsonb;
  v_unread   int := 0;
begin
  if auth.uid() is null then
    raise exception '请先登录';
  end if;
  select * into v_p from public.profiles where id = auth.uid();

  v_cfg := public.cfg();
  if not public.is_admin() then
    -- 邀请码与初始密码仅管理员可见
    v_cfg := v_cfg - 'invite_code' - 'default_student_password';
  end if;

  if v_p.id is not null then
    select count(*) into v_unread
      from public.notifications n
     where n.recipient_id = auth.uid() and not n.is_read;
  end if;

  return jsonb_build_object(
    'version', '2.0.0',
    'server_now', now(),
    'me', case when v_p.id is null then null else jsonb_build_object(
      'id', v_p.id,
      'username', v_p.username,
      'name', v_p.name,
      'role', v_p.role,
      'status', v_p.status,
      'group_name', v_p.group_name,
      'student_id', v_p.student_id,
      'must_change_password', v_p.must_change_password,
      'positions', to_jsonb(coalesce(v_p.positions, '{}'::text[])),
      'is_supervisor', public.is_supervisor_now(),
      'is_admin', public.is_admin(),
      'is_teacher', public.is_teacher()
    ) end,
    'config', v_cfg,
    'period', jsonb_build_object(
      'month_key', public.current_month_key(),
      'week_key', public.current_week_key(),
      'next_month_at', public.next_month_boundary_at(),
      'next_week_at', coalesce(
        (select min(b.boundary_at) from public.boundaries b where b.type = 'week' and b.boundary_at > now()),
        now() + interval '7 days'),
      'maintenance', public.is_maintenance(),
      'maintenance_until', public.cfg()->>'maintenance_until'
    ),
    'unread', v_unread
  );
end;
$$;
revoke all on function public.get_app_state() from public, anon, authenticated;
grant execute on function public.get_app_state() to authenticated;


-- ------------------------------------------------------------
-- 5. 周结算函数（小组惩罚抽选记录带周标记）
-- ------------------------------------------------------------

create or replace function public.weekly_snapshot(p_boundary_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b        public.boundaries;
  v_exist    jsonb;
  v_start    timestamptz;
  v_end      timestamptz;
  v_sd       date;
  v_ed       date;
  v_week_key text;
  v_month_key text;
  v_top      int := 3;
  v_bottom   int := 3;
  v_individuals jsonb;
  v_groups   jsonb;
  v_star_ind jsonb;
  v_star_grp jsonb;
  v_group_cnt int := 0;
  v_summary  jsonb;
  v_added    int := 0;
  v_penalty_draws int := 0;
  v_p        record;
  v_p2       record;
  v_item     public.lottery_items;
  v_repr     uuid;
  v_members  jsonb;
  v_draw_id  uuid;
begin
  select * into v_b from public.boundaries where id = p_boundary_id;
  if v_b.id is null then
    raise exception '分隔点不存在';
  end if;
  if v_b.type <> 'week' then
    raise exception '该分隔点不是周分隔点';
  end if;

  select summary into v_exist from public.weekly_summaries where boundary_id = p_boundary_id;
  if v_exist is not null then
    return v_exist;
  end if;

  v_end := v_b.boundary_at;
  v_start := coalesce(
    (select max(b.boundary_at) from public.boundaries b
      where b.type = 'week' and b.boundary_at < v_end),
    v_end - interval '7 days');
  v_sd := (v_start at time zone 'Asia/Shanghai')::date;
  v_ed := (v_end at time zone 'Asia/Shanghai')::date;
  v_week_key := v_b.period_key;
  -- 本周（结算覆盖的那段）所属自然月 → 奖励次数入该月
  v_month_key := to_char((v_end - interval '1 second') at time zone 'Asia/Shanghai', 'YYYY-MM');

  select coalesce((public.cfg()->>'week_reward_top_groups')::int, 3),
         coalesce((public.cfg()->>'week_penalty_bottom_groups')::int, 3)
    into v_top, v_bottom;

  -- 个人周积分
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', p.id, 'name', p.name, 'group_name', p.group_name,
           'total', p.total, 'rank', p.rnk) order by p.rnk, p.name), '[]'::jsonb)
    into v_individuals
    from (
      select s.id, s.name, s.group_name, coalesce(r.total, 0) as total,
             rank() over (order by coalesce(r.total, 0) desc) as rnk
        from public.students s
        left join (
          select rec.student_id, sum(rec.points) as total
            from public.records rec
           where rec.status = '正常'
             and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
             and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
           group by rec.student_id
        ) r on r.student_id = s.id
    ) p;

  -- 小组周积分
  select coalesce(jsonb_agg(jsonb_build_object(
           'group_name', g.group_name, 'total', g.total, 'rank', g.rnk) order by g.rnk), '[]'::jsonb)
    into v_groups
    from (
      select q.group_name, sum(q.total) as total,
             rank() over (order by sum(q.total) desc) as rnk
        from (
          select s.group_name, coalesce(r.total, 0) as total
            from public.students s
            left join (
              select rec.student_id, sum(rec.points) as total
                from public.records rec
               where rec.status = '正常'
                 and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
                 and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
               group by rec.student_id
            ) r on r.student_id = s.id
           where s.group_name is not null and s.group_name <> ''
        ) q
       group by q.group_name
    ) g;
  select jsonb_array_length(v_groups) into v_group_cnt;

  -- 本周星光增减（荣誉标记）
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id', x.student_id, 'name', x.name, 'change', x.change) order by x.change desc), '[]'::jsonb)
    into v_star_ind
    from (
      select l.student_id, s.name, sum(l.change_amount) as change
        from public.starlight_logs l
        join public.students s on s.id = l.student_id
       where l.created_at >= v_start and l.created_at < v_end
       group by l.student_id, s.name
      having sum(l.change_amount) <> 0
    ) x;

  select coalesce(jsonb_agg(jsonb_build_object(
           'group_name', y.group_name, 'change', y.change) order by y.change desc), '[]'::jsonb)
    into v_star_grp
    from (
      select s.group_name, sum(l.change_amount) as change
        from public.starlight_logs l
        join public.students s on s.id = l.student_id
       where l.created_at >= v_start and l.created_at < v_end
       group by s.group_name
      having sum(l.change_amount) <> 0
    ) y;

  v_summary := jsonb_build_object(
    'type', 'week',
    'week_key', v_week_key,
    'range_start', v_start,
    'range_end', v_end,
    'groups', v_groups,
    'individuals', v_individuals,
    'reward_groups', (select coalesce(jsonb_agg(g), '[]'::jsonb)
                        from jsonb_array_elements(v_groups) g
                       where (g->>'rank')::int <= v_top),
    'penalty_groups', (select coalesce(jsonb_agg(g), '[]'::jsonb)
                         from jsonb_array_elements(v_groups) g
                        where v_group_cnt >= v_top + v_bottom
                          and (g->>'rank')::int > v_group_cnt - v_bottom
                          and (g->>'rank')::int > v_top),
    'starlight_individuals', v_star_ind,
    'starlight_groups', v_star_grp,
    'effects_done', false,
    'generated_at', now()
  );
  insert into public.weekly_summaries (period_key, boundary_id, range_start, range_end, summary)
  values (v_week_key, p_boundary_id, v_start, v_end, v_summary);

  -- ① 前 N 组每人 +1 次奖励抽选（入本段所属自然月）
  insert into public.lottery_chances (student_id, period_key, pool_type, chance_type, amount, source_week_key)
  select s.id, v_month_key, 'reward', 'weekly_group', 1, v_week_key
    from public.students s
    join (
      select q.group_name, sum(q.total) as total,
             rank() over (order by sum(q.total) desc) as rnk
        from (
          select s2.group_name, coalesce(r.total, 0) as total
            from public.students s2
            left join (
              select rec.student_id, sum(rec.points) as total
                from public.records rec
               where rec.status = '正常'
                 and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
                 and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
               group by rec.student_id
            ) r on r.student_id = s2.id
           where s2.group_name is not null and s2.group_name <> ''
        ) q
       group by q.group_name
    ) g on g.group_name = s.group_name
   where g.rnk <= v_top
  on conflict (student_id, period_key, chance_type, source_week_key) do nothing;
  get diagnostics v_added = row_count;

  -- 通知获得次数的学生
  for v_p in
    select p.id as profile_id, s.name as student_name, g.group_name, g.rnk
      from public.profiles p
      join public.students s on s.id = p.student_id
      join (
        select q.group_name, sum(q.total) as total,
               rank() over (order by sum(q.total) desc) as rnk
          from (
            select s2.group_name, coalesce(r.total, 0) as total
              from public.students s2
              left join (
                select rec.student_id, sum(rec.points) as total
                  from public.records rec
                 where rec.status = '正常'
                   and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
                   and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
                 group by rec.student_id
              ) r on r.student_id = s2.id
             where s2.group_name is not null and s2.group_name <> ''
          ) q
         group by q.group_name
      ) g on g.group_name = s.group_name
     where g.rnk <= v_top and p.status = 'active'
  loop
    perform public.notify(v_p.profile_id, '本周奖励抽选次数 +1',
      format('你所在的「%s」小组本周积分第 %s 名，全组每人获得 1 次奖励抽选机会（本月内有效）。',
             v_p.group_name, v_p.rnk),
      'lottery', null, null);
  end loop;

  -- ② 后 N 组：每组自动抽 1 条小组级惩罚（全组共担）
  for v_p in
    select g.group_name
      from (
        select q.group_name, sum(q.total) as total,
               rank() over (order by sum(q.total) desc) as rnk
          from (
            select s2.group_name, coalesce(r.total, 0) as total
              from public.students s2
              left join (
                select rec.student_id, sum(rec.points) as total
                  from public.records rec
                 where rec.status = '正常'
                   and rec.record_date >= to_char(v_sd, 'YYYY-MM-DD')
                   and rec.record_date <  to_char(v_ed, 'YYYY-MM-DD')
                 group by rec.student_id
              ) r on r.student_id = s2.id
             where s2.group_name is not null and s2.group_name <> ''
          ) q
         group by q.group_name
      ) g
     where v_group_cnt >= v_top + v_bottom
       and g.rnk > v_group_cnt - v_bottom
       and g.rnk > v_top
  loop
    v_repr := (select s.id from public.students s
                where s.group_name = v_p.group_name
                order by random() limit 1);
    v_members := to_jsonb(public.group_members(v_p.group_name));
    v_item := public._pick_lottery_item('penalty');
    if v_item.id is null then
      insert into public.lottery_draws (student_id, pool_type, item_id, item_snapshot, item_kind,
        period_key, source, group_name, is_group, member_ids, status, note)
      values (v_repr, 'penalty', null, '{}'::jsonb, 'plain_text',
        v_month_key, 'monthly_group_penalty', v_p.group_name, true, v_members, 'void',
        '本期惩罚池为空，未抽中');
    else
      v_draw_id := public._apply_draw(v_repr, 'penalty', v_item.id, v_month_key,
        'monthly_group_penalty', v_p.group_name, v_members, true, format('周结算自动抽选（%s）', v_week_key), null);
      v_penalty_draws := v_penalty_draws + 1;
      -- 通知全组成员
      for v_p2 in
        select p2.id as profile_id from public.profiles p2
          join public.students s2 on s2.id = p2.student_id
         where s2.group_name = v_p.group_name and p2.status = 'active'
      loop
        perform public.notify(v_p2.profile_id, '小组惩罚抽选结果',
          format('你所在的「%s」小组本周积分靠后，抽中惩罚：%s（全组共担执行）。',
                 v_p.group_name, v_item.title),
          'lottery', 'lottery_draw', v_draw_id);
      end loop;
    end if;
  end loop;

  v_summary := v_summary || jsonb_build_object(
    'effects_done', true,
    'reward_chances_added', v_added,
    'penalty_draws', v_penalty_draws);
  update public.weekly_summaries set summary = v_summary where boundary_id = p_boundary_id;
  update public.boundaries set settled = true where id = p_boundary_id;
  perform public.write_audit('weekly_snapshot', 'boundary', p_boundary_id::text,
    jsonb_build_object('week_key', v_week_key, 'reward_chances', v_added, 'penalty_draws', v_penalty_draws));
  return v_summary;
end;
$$;
revoke all on function public.weekly_snapshot(uuid) from public, anon, authenticated;


-- ------------------------------------------------------------
-- 6. 权限收口（新增函数只授权给登录用户；内部函数不授权）
-- ------------------------------------------------------------
revoke all on function public.admin_set_user_positions(uuid, text[]) from public, anon, authenticated;
grant execute on function public.admin_set_user_positions(uuid, text[]) to authenticated;
revoke all on function public.admin_run_weekly_summary(uuid) from public, anon, authenticated;
grant execute on function public.admin_run_weekly_summary(uuid) to authenticated;
revoke all on function public.admin_run_monthly_summary(uuid) from public, anon, authenticated;
grant execute on function public.admin_run_monthly_summary(uuid) to authenticated;

-- 刷新 PostgREST 结构缓存（让新函数立即可被前端调用）
notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- 自检：应返回 3 个函数、positions 列存在、策略已更新
-- ------------------------------------------------------------
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in
      ('admin_set_user_positions','admin_run_weekly_summary','admin_run_monthly_summary')) as 新增函数数,
  (select count(*) from information_schema.columns
    where table_schema='public' and table_name='profiles' and column_name='positions') as 职务列,
  (select count(*) from pg_policies
    where schemaname='public' and tablename='records' and policyname='records_select') as 明细策略;

