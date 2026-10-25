-- ============================================================
-- V2.0.4 增量补丁（幂等，可在 Supabase SQL Editor 直接执行）
-- 适用：已经部署过 V2.0.0–V2.0.3 的项目
--
-- 本补丁做四件事：
--   1) 下线申诉：删除 submit_appeal / list_appeals / handle_appeal 与 appeals 表
--   2) 周汇总改为「小组集体抽选」：新增 lottery_group_chances 表 + list_group_chances /
--      draw_group_lottery 两个 RPC，weekly_snapshot 改为按小组排名发集体抽选次数
--   3) 用户职务标签：profiles.positions + admin_set_user_positions
--   4) 手动周期汇总：admin_run_weekly_summary / admin_run_monthly_summary
--   5) 学生可查看全班积分明细（只读）
--
-- 执行完请再执行：notify pgrst, 'reload schema';
-- ============================================================


-- ---------- 1. 表结构 ----------
create table if not exists public.lottery_group_chances (
  id              uuid primary key default gen_random_uuid(),
  group_name      text not null,
  period_key      text not null,
  pool_type       text not null default 'reward',
  chance_type     text not null default 'weekly_group_reward',
  source_week_key text not null default '',
  amount          int  not null default 1,
  used_count      int  not null default 0,
  note            text,
  created_at      timestamptz not null default now(),
  unique (group_name, period_key, chance_type, source_week_key)
);
alter table public.lottery_group_chances drop constraint if exists lottery_group_chances_pool_check;
alter table public.lottery_group_chances add constraint lottery_group_chances_pool_check
  check (pool_type in ('reward','penalty'));
alter table public.lottery_group_chances drop constraint if exists lottery_group_chances_type_check;
alter table public.lottery_group_chances add constraint lottery_group_chances_type_check
  check (chance_type in ('weekly_group_reward','weekly_group_penalty'));
alter table public.lottery_group_chances drop constraint if exists lottery_group_chances_amount_check;
alter table public.lottery_group_chances add constraint lottery_group_chances_amount_check
  check (amount between 1 and 99 and used_count >= 0);
create index if not exists group_chances_group_idx on public.lottery_group_chances(group_name, period_key);

alter table public.lottery_draws drop constraint if exists lottery_draws_source_check;
alter table public.lottery_draws add constraint lottery_draws_source_check
  check (source in ('manual','auto','weekly_group','weekly_group_reward','weekly_group_penalty','monthly_group_penalty'));

-- ---------- 2. RLS 策略 ----------
drop policy if exists lottery_group_chances_select on public.lottery_group_chances;
create policy lottery_group_chances_select on public.lottery_group_chances
  for select to authenticated using (
    public.is_teacher() or (public.is_active_user() and group_name = public.my_group_name())
  );

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

-- ---------- 3. 公开表权限收口 ----------
alter table public.lottery_group_chances enable row level security;
revoke all on table public.lottery_group_chances from anon, authenticated;
grant select on table public.lottery_group_chances to authenticated;

-- ---------- 4. 小组集体抽选函数 ----------
create or replace function public.list_group_chances(p_period_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_me     text := public.my_group_name();
  v_period text := coalesce(nullif(btrim(coalesce(p_period_key, '')), ''), public.current_month_key());
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  return jsonb_build_object(
    'period_key', v_period,
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
         and (v_role in ('super_admin','admin','executive') or c.group_name = v_me)
    ), '[]'::jsonb)
  );
end;
$$;
revoke all on function public.list_group_chances(text) from public, anon, authenticated;
grant execute on function public.list_group_chances(text) to authenticated;

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

  -- 权限：老师/执行小组任意组；记录员仅本组；学生不能代小组抽选
  if v_role in ('system','super_admin','admin','executive') then
    null;
  elsif v_role = 'group_recorder' then
    if v_group <> public.my_group_name() then
      raise exception '记录员只能代表本组抽选';
    end if;
  else
    raise exception '小组抽选由小组记录员或班干部代表全组进行';
  end if;

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
      format('小组集体抽选（%s）', v_chance.source_week_key), auth.uid());
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

-- ---------- 5. 周汇总 / 月结算（改为小组集体抽选） ----------
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
  v_reward_chances int := 0;
  v_penalty_chances int := 0;
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
           'group_name', g.group_name, 'total', g.total, 'rank', g.rnk, 'pos', g.pos) order by g.pos), '[]'::jsonb)
    into v_groups
    from (
      select q.group_name, sum(q.total) as total,
             rank() over (order by sum(q.total) desc) as rnk,
             row_number() over (order by sum(q.total) desc, q.group_name) as pos
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
                       where (g->>'pos')::int <= v_top),
    'penalty_groups', (select coalesce(jsonb_agg(g), '[]'::jsonb)
                         from jsonb_array_elements(v_groups) g
                        where v_group_cnt >= v_top + v_bottom
                          and (g->>'pos')::int > greatest(v_top, v_group_cnt - v_bottom)),
    'starlight_individuals', v_star_ind,
    'starlight_groups', v_star_grp,
    'effects_done', false,
    'generated_at', now()
  );
  insert into public.weekly_summaries (period_key, boundary_id, range_start, range_end, summary)
  values (v_week_key, p_boundary_id, v_start, v_end, v_summary);

  -- ① 前 N 组：每组获得 1 次集体奖励抽选机会（按 pos 取，避免并列把名额放大）
  insert into public.lottery_group_chances
    (group_name, period_key, pool_type, chance_type, source_week_key, amount, note)
  select g->>'group_name', v_month_key, 'reward', 'weekly_group_reward', v_week_key, 1,
         format('%s 周小组积分第 %s 名', v_week_key, g->>'pos')
    from jsonb_array_elements(v_groups) g
   where (g->>'pos')::int <= v_top
  on conflict (group_name, period_key, chance_type, source_week_key) do nothing;
  get diagnostics v_reward_chances = row_count;

  -- 通知前 N 组全体成员
  for v_p in
    select p.id as profile_id, s.group_name, (g->>'pos') as pos
      from jsonb_array_elements(v_groups) g
      join public.students s on s.group_name = g->>'group_name'
      join public.profiles p on p.student_id = s.id
     where (g->>'pos')::int <= v_top and p.status = 'active'
  loop
    perform public.notify(v_p.profile_id, '本周小组集体奖励抽选机会',
      format('你所在的「%s」小组本周积分第 %s 名，获得 1 次集体奖励抽选机会，由小组记录员代表全组抽选。',
             v_p.group_name, v_p.pos),
      'lottery', null, null);
  end loop;

  -- ② 后 N 组：每组获得 1 次小组惩罚抽选机会（代表抽选，全组共担执行）
  insert into public.lottery_group_chances
    (group_name, period_key, pool_type, chance_type, source_week_key, amount, note)
  select g->>'group_name', v_month_key, 'penalty', 'weekly_group_penalty', v_week_key, 1,
         format('%s 周小组积分第 %s 名', v_week_key, g->>'pos')
    from jsonb_array_elements(v_groups) g
   where v_group_cnt >= v_top + v_bottom
     and (g->>'pos')::int > greatest(v_top, v_group_cnt - v_bottom)
  on conflict (group_name, period_key, chance_type, source_week_key) do nothing;
  get diagnostics v_penalty_chances = row_count;

  -- 通知后 N 组全体成员
  for v_p in
    select p.id as profile_id, s.group_name, (g->>'pos') as pos
      from jsonb_array_elements(v_groups) g
      join public.students s on s.group_name = g->>'group_name'
      join public.profiles p on p.student_id = s.id
     where v_group_cnt >= v_top + v_bottom
       and (g->>'pos')::int > greatest(v_top, v_group_cnt - v_bottom)
       and p.status = 'active'
  loop
    perform public.notify(v_p.profile_id, '本周小组惩罚抽选机会',
      format('你所在的「%s」小组本周积分第 %s 名，需进行 1 次小组惩罚抽选，由小组记录员代表全组抽选，结果全组共担。',
             v_p.group_name, v_p.pos),
      'lottery', null, null);
  end loop;

  v_summary := v_summary || jsonb_build_object(
    'effects_done', true,
    'reward_chances_added', 0,
    'penalty_draws', v_penalty_draws,
    'reward_group_chances', v_reward_chances,
    'penalty_group_chances', v_penalty_chances);
  update public.weekly_summaries set summary = v_summary where boundary_id = p_boundary_id;
  update public.boundaries set settled = true where id = p_boundary_id;
  perform public.write_audit('weekly_snapshot', 'boundary', p_boundary_id::text,
    jsonb_build_object('week_key', v_week_key,
      'reward_group_chances', v_reward_chances,
      'penalty_group_chances', v_penalty_chances));
  return v_summary;
end;
$$;
revoke all on function public.weekly_snapshot(uuid) from public, anon, authenticated;

create or replace function public.admin_resettle(p_boundary_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b  public.boundaries;
  v_st public.settlements;
  v_month_key text;
begin
  perform public.require_super_admin();
  select * into v_b from public.boundaries where id = p_boundary_id;
  if v_b.id is null then
    raise exception '分隔点不存在';
  end if;
  if v_b.type <> 'month' then
    raise exception '仅支持重跑月结算；周汇总重算请等待后续版本或联系维护';
  end if;
  select * into v_st from public.settlements
   where boundary_id = p_boundary_id and status <> 'rolled_back';
  if v_st.id is not null and v_st.status = 'done' then
    raise exception '该月已结算完成，不能自动重算（历史快照与抽选结果不可追改）';
  end if;

  v_month_key := to_char((v_b.boundary_at - interval '1 second') at time zone 'Asia/Shanghai', 'YYYY-MM');

  -- 清理上次失败的半成品（只清理本结算点产生的自动数据与次数）
  delete from public.lottery_draws
   where period_key = v_month_key and source in ('auto','monthly_group_penalty','weekly_group','weekly_group_reward','weekly_group_penalty');
  delete from public.lottery_chances where period_key = v_month_key;
  if v_st.id is not null then
    update public.settlements set status = 'rolled_back', note = '管理员重跑'
     where id = v_st.id;
  end if;

  perform public.write_audit('resettle', 'boundary', p_boundary_id::text,
    jsonb_build_object('month_key', v_month_key, 'previous_status', v_st.status));
  return public.monthly_settle(p_boundary_id);
end;
$$;
revoke all on function public.admin_resettle(uuid) from public, anon, authenticated;
grant execute on function public.admin_resettle(uuid) to authenticated;

-- ---------- 6. 职务标签 + 手动汇总函数 ----------
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

-- ---------- 7. 下申诉：删除函数与表 ----------
-- ============================================================
-- 7.5 废弃功能清理（V2.0.4：申诉功能取消）
--   幂等：重复执行无副作用
-- ============================================================

drop function if exists public.submit_appeal(uuid, text) cascade;
drop function if exists public.list_appeals(text) cascade;
drop function if exists public.handle_appeal(uuid, boolean, text) cascade;
drop table if exists public.appeals cascade;

-- 周惩罚组数默认由 3 改为 2（只纠正旧默认值，管理员手工改过的保持原值）
update public.app_config
   set week_penalty_bottom_groups = 2
 where id = 1
   and week_penalty_bottom_groups = 3;


-- ---------- 8. 自检 ----------
select 'V2.0.4 补丁已应用' as 结果,
       (select count(*) from information_schema.tables
         where table_schema = 'public' and table_name = 'lottery_group_chances') as 小组次数表,
       (select count(*) from information_schema.tables
         where table_schema = 'public' and table_name = 'appeals') as 申诉表_应为0,
       (select count(*) from information_schema.columns
         where table_schema = 'public' and table_name = 'profiles' and column_name = 'positions') as 职务列,
       (select count(*) from information_schema.routines
         where routine_schema = 'public'
           and routine_name in ('list_group_chances','draw_group_lottery',
                                'admin_run_weekly_summary','admin_run_monthly_summary',
                                'admin_set_user_positions')) as 新函数_应为5;
