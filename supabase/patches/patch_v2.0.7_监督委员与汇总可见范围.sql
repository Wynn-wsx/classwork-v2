-- ============================================================
-- V2.0.7 增量补丁（幂等，可在 Supabase SQL Editor 直接执行）
-- 适用：已经部署过 V2.0.0–V2.0.6 的项目
--
-- 本补丁做五件事：
--   1) 允许「本周监督委员」登记积分（教师端同样可看班级明细）
--   2) 汇总可见范围改为四项多选（app_config.summary_visibility）：
--      个人月汇总排名 / 所在小组周汇总排名 / 全部个人月汇总排名 / 全部小组周汇总排名
--   3) student_rankings 返回 permissions 与月/周排名，学生按管理员授权裁剪
--   4) 个人可代表自己所在的小组抽选；同一组同一轮以最早一次写入为准（并发加锁）
--   5) my_group_name() 在 profiles.group_name 为空时回退 students.group_name
--
-- 执行完请再执行：notify pgrst, 'reload schema';
-- ============================================================


-- ---------- 1. 汇总可见范围配置列 ----------
alter table public.app_config add column if not exists summary_visibility jsonb not null
  default '{"self_month": true, "own_group_week": true, "all_month": false, "all_group_week": false}'::jsonb;

-- 旧字段 student_visibility 含义收窄为「积分明细可见范围」，保持兼容
update public.app_config
   set student_visibility = coalesce(nullif(student_visibility, ''), 'self_rank')
 where id = 1;


-- ---------- 2. 学生表读取策略：监督委员可读全班 ----------
drop policy if exists students_select on public.students;
create policy students_select on public.students
  for select to authenticated using (
    public.is_teacher()
    or (public.caller_role() = 'group_recorder' and group_name = public.my_group_name())
    -- 当周监督委员需要看全班学生（抽查与受理申诉）
    or public.is_supervisor_now()
    or id = public.my_student_id()
  );


-- ---------- 3. 函数 ----------
-- 3.1 我的小组名（profiles.group_name 为空时回退学生档案）
create or replace function public.my_group_name() returns text
language sql stable security definer set search_path = public, extensions as $$
  -- 优先用账号上登记的小组；账号未填时按绑定的学生档案取（建号/改角色后可能只在学生档案里有小组）
  select coalesce(nullif(btrim(p.group_name), ''),
                  (select s.group_name from public.students s where s.id = p.student_id))
    from public.profiles p
   where p.id = auth.uid();
$$;

-- 3.2 登记积分：放行本周监督委员
create or replace function public.add_record(
  p_student_id  uuid,
  p_score_type  text,
  p_category    text,
  p_reason      text,
  p_points      numeric,
  p_record_date date,
  p_rule_id     uuid default null,
  p_evidence    text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_rec  public.records;
begin
  -- 监督委员（学生，当周临时授权）可以登记积分；其余角色按原权限
  if v_role not in ('system','super_admin','admin','executive','group_recorder') then
    if not public.is_supervisor_now() then
      raise exception '没有权限登记积分';
    end if;
  end if;
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能登记';
  end if;
  if p_student_id is null then
    raise exception '请选择学生';
  end if;
  if not exists (select 1 from public.students where id = p_student_id) then
    raise exception '学生不存在';
  end if;
  if v_role = 'group_recorder' and not public.student_in_my_group(p_student_id) then
    raise exception '记录员只能登记本组学生';
  end if;
  if p_score_type not in ('加分','扣分') then
    raise exception '积分类型必须是「加分」或「扣分」';
  end if;
  if coalesce(p_points, 0) = 0 then
    raise exception '分值不能为 0';
  end if;
  if p_score_type = '加分' and p_points < 0 then
    raise exception '加分记录的分值必须为正数';
  end if;
  if p_score_type = '扣分' and p_points > 0 then
    raise exception '扣分记录的分值必须为负数';
  end if;
  if p_record_date is null then
    raise exception '请选择登记日期';
  end if;
  if public.is_future_date(p_record_date) then
    raise exception '不能登记未来日期';
  end if;
  if public.is_month_frozen(p_record_date) then
    raise exception '该登记月已冻结，不能新增记录（如需纠错请让管理员处理）';
  end if;

  perform public.check_rule_limit(p_rule_id, p_points, null);

  insert into public.records (
    student_id, score_type, category, reason, points, recorder_id, recorder_name,
    record_date, status, evidence, rule_id, frozen_until, period_key
  ) values (
    p_student_id, p_score_type, coalesce(p_category,''), coalesce(p_reason,''), p_points, auth.uid(),
    (select p.name from public.profiles p where p.id = auth.uid()),
    p_record_date::text, '正常', p_evidence, p_rule_id,
    now() + interval '2 seconds', to_char(p_record_date, 'YYYY-MM')
  ) returning * into v_rec;

  perform public.write_audit('add_record', 'record', v_rec.id::text,
    jsonb_build_object('student_id', p_student_id, 'points', p_points,
                       'reason', p_reason, 'record_date', p_record_date));
  return to_jsonb(v_rec);
end;
$$;
revoke all on function public.add_record(uuid, text, text, text, numeric, date, uuid, text) from public, anon, authenticated;
grant execute on function public.add_record(uuid, text, text, text, numeric, date, uuid, text) to authenticated;

-- 3.3 排行：返回 permissions 与月/周排名，按授权裁剪
create or replace function public.student_rankings(p_scope text default 'all')
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text := public.caller_role();
  v_cfg   jsonb := public.cfg();
  v_vis   text := coalesce(v_cfg->>'student_visibility', 'self_rank');
  v_sum   jsonb := coalesce(v_cfg->'summary_visibility', '{}'::jsonb);
  v_month text := public.current_month_key();
  v_week  text := public.current_week_key();
  v_week_start date;
  v_me    uuid := public.my_student_id();
  v_my_group text := public.my_group_name();
  v_ind   jsonb;
  v_grp   jsonb;
  v_perm  jsonb;
begin
  if v_role in ('none','anon') then
    raise exception '请先登录';
  end if;

  select (b.boundary_at at time zone 'Asia/Shanghai')::date into v_week_start
    from public.boundaries b
   where b.type = 'week' and b.boundary_at <= now()
   order by b.boundary_at desc limit 1;
  if v_week_start is null then
    v_week_start := (now() at time zone 'Asia/Shanghai')::date - 6;
  end if;

  -- 个人榜（含总积分、本月、本周，及对应名次）
  select coalesce(jsonb_agg(x order by (x->>'month_rank')::int, x->>'name'), '[]'::jsonb) into v_ind
    from (
      select jsonb_build_object(
               'student_id', t.student_id, 'name', t.name, 'group_name', t.group_name,
               'total', t.total, 'month_total', t.month_total, 'week_total', t.week_total,
               'rank', dense_rank() over (order by t.total desc),
               'month_rank', dense_rank() over (order by t.month_total desc),
               'week_rank', dense_rank() over (order by t.week_total desc)
             ) as x
        from (
          select s.id as student_id, s.name, s.group_name,
                 coalesce(sum(case when r.status = '正常' then r.points else 0 end), 0) as total,
                 coalesce(sum(case when r.status = '正常' and left(r.record_date, 7) = v_month then r.points else 0 end), 0) as month_total,
                 coalesce(sum(case when r.status = '正常' and (nullif(r.record_date,''))::date >= v_week_start then r.points else 0 end), 0) as week_total
            from public.students s
            left join public.records r on r.student_id = s.id
           group by s.id, s.name, s.group_name
        ) t
    ) q;

  -- 小组榜（总积分、本月、本周）
  select coalesce(jsonb_agg(x order by (x->>'week_rank')::int, x->>'group_name'), '[]'::jsonb) into v_grp
    from (
      select jsonb_build_object(
               'group_name', g.group_name, 'total', g.total, 'month_total', g.month_total,
               'week_total', g.week_total,
               'rank', dense_rank() over (order by g.total desc),
               'month_rank', dense_rank() over (order by g.month_total desc),
               'week_rank', dense_rank() over (order by g.week_total desc),
               'members', g.members
             ) as x
        from (
          select s.group_name,
                 coalesce(sum(case when r.status = '正常' then r.points else 0 end), 0) as total,
                 coalesce(sum(case when r.status = '正常' and left(r.record_date, 7) = v_month then r.points else 0 end), 0) as month_total,
                 coalesce(sum(case when r.status = '正常' and (nullif(r.record_date,''))::date >= v_week_start then r.points else 0 end), 0) as week_total,
                 count(distinct s.id) as members
            from public.students s
            left join public.records r on r.student_id = s.id
           group by s.group_name
        ) g
    ) q2;

  if v_role = 'student' then
    -- 管理员配置的四项汇总可见性（旧配置兼容：self_only→全部关闭，all_open→全部开放）
    v_perm := jsonb_build_object(
      'self_month',       coalesce((v_sum->>'self_month')::boolean,       v_vis <> 'self_only'),
      'own_group_week',   coalesce((v_sum->>'own_group_week')::boolean,   v_vis <> 'self_only'),
      'all_month',        coalesce((v_sum->>'all_month')::boolean,        v_vis = 'all_open'),
      'all_group_week',   coalesce((v_sum->>'all_group_week')::boolean,   v_vis = 'all_open')
    );
    -- 个人榜：全部 或 只看自己 或 空
    if not coalesce((v_perm->>'all_month')::boolean, false) then
      if coalesce((v_perm->>'self_month')::boolean, false) then
        v_ind := coalesce((select jsonb_agg(i) from jsonb_array_elements(v_ind) i
                            where (i->>'student_id') = v_me::text), '[]'::jsonb);
      else
        v_ind := '[]'::jsonb;
      end if;
    end if;
    -- 小组榜：全部 或 只看本组 或 空
    if not coalesce((v_perm->>'all_group_week')::boolean, false) then
      if coalesce((v_perm->>'own_group_week')::boolean, false) then
        v_grp := coalesce((select jsonb_agg(g) from jsonb_array_elements(v_grp) g
                            where (g->>'group_name') = v_my_group), '[]'::jsonb);
      else
        v_grp := '[]'::jsonb;
      end if;
    end if;
  else
    v_perm := jsonb_build_object('self_month', true, 'own_group_week', true, 'all_month', true, 'all_group_week', true);
  end if;

  return jsonb_build_object(
    'period_key', v_month,
    'week_key', v_week,
    'week_start', v_week_start,
    'visibility', v_vis,
    'permissions', v_perm,
    'my_group', v_my_group,
    'individuals', v_ind,
    'groups', v_grp
  );
end;
$$;
revoke all on function public.student_rankings(text) from public, anon, authenticated;
grant execute on function public.student_rankings(text) to authenticated;

-- 3.4 配置：支持 summary_visibility 四项
create or replace function public.admin_set_config(p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_vis      text;
  v_star_vis text;
  v_policy   text;
  v_new_pwd  text;
  v_sum      jsonb;
  v_key      text;
begin
  perform public.require_super_admin();
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception '配置内容格式错误';
  end if;

  if p_patch ? 'student_visibility' then
    v_vis := p_patch->>'student_visibility';
    if v_vis not in ('self_rank','all_open','self_only') then
      raise exception '学生信息可见范围不合法';
    end if;
  end if;
  if p_patch ? 'starlight_visibility' then
    v_star_vis := p_patch->>'starlight_visibility';
    if v_star_vis not in ('public','self_only') then
      raise exception '星光公示范围不合法';
    end if;
  end if;
  if p_patch ? 'register_policy' then
    v_policy := p_patch->>'register_policy';
    if v_policy not in ('review','auto') then
      raise exception '注册审核策略不合法';
    end if;
  end if;
  if p_patch ? 'default_student_password' then
    v_new_pwd := p_patch->>'default_student_password';
    if length(coalesce(v_new_pwd,'')) < 6 then
      raise exception '初始密码至少 6 位';
    end if;
  end if;
  if p_patch ? 'max_supervisors' and coalesce((p_patch->>'max_supervisors')::int, 0) < 1 then
    raise exception '监督委员人数至少 1 人';
  end if;

  if p_patch ? 'summary_visibility' then
    if jsonb_typeof(p_patch->'summary_visibility') <> 'object' then
      raise exception '汇总可见范围格式错误';
    end if;
    v_sum := '{}'::jsonb;
    foreach v_key in array array['self_month','own_group_week','all_month','all_group_week'] loop
      if p_patch->'summary_visibility' ? v_key then
        v_sum := v_sum || jsonb_build_object(v_key,
          coalesce((p_patch->'summary_visibility'->>v_key)::boolean, false));
      end if;
    end loop;
    if v_sum = '{}'::jsonb then
      raise exception '汇总可见范围没有可识别的选项';
    end if;
  end if;

  update public.app_config set
    student_visibility      = coalesce(p_patch->>'student_visibility', student_visibility),
    starlight_visibility    = coalesce(p_patch->>'starlight_visibility', starlight_visibility),
    invite_code             = coalesce(p_patch->>'invite_code', invite_code),
    invite_enabled          = coalesce((p_patch->>'invite_enabled')::boolean, invite_enabled),
    register_policy         = coalesce(p_patch->>'register_policy', register_policy),
    allow_frozen_appeal     = coalesce((p_patch->>'allow_frozen_appeal')::boolean, allow_frozen_appeal),
    summary_visibility      = coalesce(summary_visibility || v_sum, summary_visibility),
    default_student_password = coalesce(p_patch->>'default_student_password', default_student_password),
    reward_threshold        = coalesce((p_patch->>'reward_threshold')::numeric, reward_threshold),
    penalty_threshold       = coalesce((p_patch->>'penalty_threshold')::numeric, penalty_threshold),
    second_class_count      = coalesce((p_patch->>'second_class_count')::int, second_class_count),
    term_name               = coalesce(p_patch->>'term_name', term_name),
    maintenance_minutes     = coalesce((p_patch->>'maintenance_minutes')::int, maintenance_minutes),
    week_reward_top_groups  = coalesce((p_patch->>'week_reward_top_groups')::int, week_reward_top_groups),
    week_penalty_bottom_groups = coalesce((p_patch->>'week_penalty_bottom_groups')::int, week_penalty_bottom_groups),
    month_reward_top_n      = coalesce((p_patch->>'month_reward_top_n')::int, month_reward_top_n),
    max_supervisors         = coalesce((p_patch->>'max_supervisors')::int, max_supervisors),
    reward_card_count       = coalesce((p_patch->>'reward_card_count')::int, reward_card_count),
    updated_at              = now(),
    updated_by              = auth.uid()
  where id = 1;

  perform public.write_audit('set_config', 'app_config', '1', p_patch);
  return public.cfg();
end;
$$;
revoke all on function public.admin_set_config(jsonb) from public, anon, authenticated;
grant execute on function public.admin_set_config(jsonb) to authenticated;

-- 3.5 小组集体抽选：个人可代表本组，同一轮以最早一次写入为准
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


-- ---------- 4. 自检 ----------
select
  (select count(*) from information_schema.columns
     where table_schema = 'public' and table_name = 'app_config' and column_name = 'summary_visibility') as summary_visibility_col,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('my_group_name','add_record','student_rankings','admin_set_config','draw_group_lottery')) as funcs,
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'students' and policyname = 'students_select') as students_policy;
-- 期望：summary_visibility_col=1, funcs=5, students_policy=1
