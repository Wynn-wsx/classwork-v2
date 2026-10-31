-- ============================================================
-- 5.1 应用状态 / 时间分隔点 / 系统配置（B1/B2/B3/B8）
-- ============================================================

-- ------------------------------------------------------------
-- 登录配置（登录页用，未登录可调用，不含任何敏感值）
-- ------------------------------------------------------------
create or replace function public.get_login_config()
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select jsonb_build_object(
    'version', '2.0.0',
    'invite_enabled', coalesce((public.cfg()->>'invite_enabled')::boolean, true),
    'register_policy', coalesce(public.cfg()->>'register_policy', 'review'),
    'maintenance', public.is_maintenance()
  );
$$;
revoke all on function public.get_login_config() from public, anon, authenticated;
grant execute on function public.get_login_config() to anon, authenticated;

-- ------------------------------------------------------------
-- 应用状态（登录后首屏：身份 / 可见配置 / 周期 / 未读数）
--   待审核或停用账号也会返回（me.status 供前端提示），不抛错
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
-- 周期状态（前端倒计时 / 只读提示 / 日期选择禁用范围）
-- ------------------------------------------------------------
create or replace function public.get_period_state()
returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_month public.boundaries;
begin
  if not public.is_active_user() then
    raise exception '请先登录';
  end if;
  v_month := public.boundary_of('month');
  return jsonb_build_object(
    'server_now', now(),
    'month_key', public.current_month_key(),
    'week_key', public.current_week_key(),
    'next_month_at', public.next_month_boundary_at(),
    'next_week_at', coalesce(
      (select min(b.boundary_at) from public.boundaries b where b.type = 'week' and b.boundary_at > now()),
      now() + interval '7 days'),
    'month_boundary_at', v_month.boundary_at,
    'locked_before_date', case when v_month.id is null then null
      else (v_month.boundary_at at time zone 'Asia/Shanghai')::date end,
    'maintenance', public.is_maintenance(),
    'maintenance_until', nullif(public.cfg()->>'maintenance_until','')::timestamptz
  );
end;
$$;
revoke all on function public.get_period_state() from public, anon, authenticated;
grant execute on function public.get_period_state() to authenticated;

-- ------------------------------------------------------------
-- 内部：按配置预生成周/月分隔点（幂等，已存在则跳过）
-- ------------------------------------------------------------
-- ------------------------------------------------------------
-- V2.0.19：不再按规则批量铺底；只保证「当前周」与「当前月（进行中）」各一条作为起点
-- ------------------------------------------------------------
create or replace function public.ensure_boundaries(
  p_months_back    int default 6,
  p_months_forward int default 12
) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_today date := public.bj_today();
  v_ws    date := public.bj_week_start(public.bj_today());
  v_n     int := 0;
begin
  if not exists (select 1 from public.boundaries where type = 'week' and start_date = v_ws) then
    insert into public.boundaries (type, period_key, start_date, end_date, rule_weeks, boundary_at, label, is_manual, settled)
    values ('week', to_char(v_ws, 'YYYY-MM-DD'), v_ws, v_ws + 6, 1,
            ((v_ws + 7)::timestamp at time zone 'Asia/Shanghai'),
            to_char(v_ws, 'YYYY-MM-DD') || ' ~ ' || to_char(v_ws + 6, 'YYYY-MM-DD'), false,
            ((v_ws + 7)::timestamp at time zone 'Asia/Shanghai') <= now() - interval '1 day')
    on conflict do nothing;
    v_n := v_n + 1;
  end if;

  if not exists (select 1 from public.boundaries b
                  where b.type = 'month' and b.start_date <= v_today
                    and coalesce(b.end_date, '9999-12-31'::date) >= v_today) then
    insert into public.boundaries (type, period_key, start_date, end_date, rule_weeks, boundary_at, label, is_manual, settled)
    values ('month', to_char(v_ws, 'YYYY-MM-DD'), v_ws, null, 1, null,
            to_char(v_ws, 'YYYY-MM-DD') || ' ~ （进行中）', false, false)
    on conflict do nothing;
    v_n := v_n + 1;
  end if;

  return v_n;
end;
$$;
revoke all on function public.ensure_boundaries(int, int) from public, anon, authenticated;

-- ------------------------------------------------------------
-- B1 修改周/月分隔规则（仅 super_admin）→ 重算未来分隔点
--   p_week  : {"dow":1,"hour":0,"minute":0}   dow 1=周一 … 7=周日
--   p_month : {"dom":1,"hour":0,"minute":0}   dom 1..28
-- ------------------------------------------------------------
create or replace function public.admin_save_separator_rules(
  p_week      jsonb default null,
  p_month     jsonb default null,
  p_maintenance_minutes int default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_week jsonb := coalesce(p_week, (select week_rule from public.app_config where id = 1), '{"dow":1,"hour":0,"minute":0}'::jsonb);
  v_month jsonb := coalesce(p_month, (select month_rule from public.app_config where id = 1), '{"dom":1,"hour":0,"minute":0}'::jsonb);
  v_auto boolean;
begin
  perform public.require_super_admin();
  v_auto := coalesce((select auto_boundaries from public.app_config where id = 1), true);
  if coalesce((v_week->>'dow')::int, 0) not between 1 and 7 then
    raise exception '周分隔点星期必须为 1-7（1=周一）';
  end if;
  if coalesce((v_week->>'hour')::int, -1) not between 0 and 23
     or coalesce((v_week->>'minute')::int, -1) not between 0 and 59 then
    raise exception '周分隔点时间不合法';
  end if;
  if coalesce((v_month->>'dom')::int, 0) not between 1 and 28 then
    raise exception '月分隔点日期必须为 1-28（避免月末不存在）';
  end if;
  if coalesce((v_month->>'hour')::int, -1) not between 0 and 23
     or coalesce((v_month->>'minute')::int, -1) not between 0 and 59 then
    raise exception '月分隔点时间不合法';
  end if;
  if p_maintenance_minutes is not null and p_maintenance_minutes not between 0 and 240 then
    raise exception '维护时长应在 0-240 分钟';
  end if;

  -- 旧的未来自动分隔点作废（已结算/手工点保留）；自动生成关闭时保留现有点，只更新规则
  if v_auto then
    delete from public.boundaries
     where type in ('week','month')
       and boundary_at > now()
       and not is_manual
       and not settled;
  end if;

  update public.app_config
     set week_rule = v_week,
         month_rule = v_month,
         maintenance_minutes = coalesce(p_maintenance_minutes, maintenance_minutes),
         updated_at = now(),
         updated_by = auth.uid()
   where id = 1;

  if v_auto then
    perform public.ensure_boundaries(6, 12);
  end if;
  perform public.write_audit('save_separator_rules', 'app_config', '1',
    jsonb_build_object('week_rule', v_week, 'month_rule', v_month,
                       'maintenance_minutes', p_maintenance_minutes, 'auto_boundaries', v_auto));
  return public.cfg();
end;
$$;
revoke all on function public.admin_save_separator_rules(jsonb, jsonb, int) from public, anon, authenticated;
grant execute on function public.admin_save_separator_rules(jsonb, jsonb, int) to authenticated;

-- ------------------------------------------------------------
-- V2.0.6：开启/关闭「按规则自动生成未来分隔点」
--   关闭后：cron/规则保存不再预生成未来分隔点，只能手动新增；已有分隔点与周期作业不受影响
-- ------------------------------------------------------------
create or replace function public.admin_set_auto_boundaries(p_on boolean)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_on boolean := coalesce(p_on, true);
begin
  perform public.require_super_admin();
  update public.app_config
     set auto_boundaries = v_on, updated_at = now(), updated_by = auth.uid()
   where id = 1;
  if v_on then
    perform public.ensure_boundaries(6, 12);
  end if;
  perform public.write_audit('set_auto_boundaries', 'app_config', '1',
    jsonb_build_object('auto_boundaries', v_on));
  return public.cfg();
end;
$$;
revoke all on function public.admin_set_auto_boundaries(boolean) from public, anon, authenticated;
grant execute on function public.admin_set_auto_boundaries(boolean) to authenticated;

-- ------------------------------------------------------------
-- B2 手动增/删分隔点（仅 super_admin）与重算
-- ------------------------------------------------------------
create or replace function public.admin_add_boundary(
  p_type        text,
  p_boundary_at timestamptz,
  p_label       text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_row public.boundaries;
begin
  perform public.require_super_admin();
  if p_type not in ('week','month','rule_update') then
    raise exception '分隔点类型不合法';
  end if;
  if p_boundary_at is null then
    raise exception '请填写分隔点时间';
  end if;
  insert into public.boundaries (type, period_key, boundary_at, label, is_manual, created_by)
  values (
    p_type,
    to_char(p_boundary_at at time zone 'Asia/Shanghai', case p_type when 'month' then 'YYYY-MM' else 'IYYY-IW' end),
    p_boundary_at,
    coalesce(p_label, '手动分隔点'),
    true,
    auth.uid()
  )
  on conflict (type, boundary_at) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from public.boundaries where type = p_type and boundary_at = p_boundary_at;
  else
    perform public.write_audit('add_boundary', 'boundary', v_row.id::text, to_jsonb(v_row));
  end if;

  -- 月分隔点新增后立即补齐对应的周分隔点：保证“本周跨过月分隔”时周/月两级都有分隔点
  perform public.ensure_boundaries();

  return to_jsonb(v_row) || jsonb_build_object(
    'auto_week_boundaries', case when p_type = 'month' then true else false end,
    'hint', case when p_type = 'month'
                 then '已在月分隔点前后自动补齐周分隔点，避免跨月周缺少周汇总节点'
                 else null end);
end;
$$;
revoke all on function public.admin_add_boundary(text, timestamptz, text) from public, anon, authenticated;
grant execute on function public.admin_add_boundary(text, timestamptz, text) to authenticated;

create or replace function public.admin_delete_boundary(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_row public.boundaries;
begin
  perform public.require_super_admin();
  select * into v_row from public.boundaries where id = p_id;
  if v_row.id is null then
    raise exception '分隔点不存在';
  end if;
  if v_row.boundary_at <= now() then
    raise exception '已到点的分隔点不能删除（会影响历史冻结与汇总判定）';
  end if;
  if v_row.settled then
    raise exception '该分隔点已结算，不能删除';
  end if;
  delete from public.boundaries where id = p_id;
  perform public.write_audit('delete_boundary', 'boundary', p_id::text, to_jsonb(v_row));
end;
$$;
revoke all on function public.admin_delete_boundary(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_boundary(uuid) to authenticated;

create or replace function public.admin_regenerate_boundaries()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_before int;
begin
  perform public.require_super_admin();
  select count(*) into v_before from public.boundaries;
  perform public.ensure_boundaries(6, 12);
  perform public.write_audit('regenerate_boundaries', 'boundary', '',
    jsonb_build_object('before', v_before, 'after', (select count(*) from public.boundaries)));
  return jsonb_build_object('before', v_before, 'after', (select count(*) from public.boundaries));
end;
$$;
revoke all on function public.admin_regenerate_boundaries() from public, anon, authenticated;
grant execute on function public.admin_regenerate_boundaries() to authenticated;

-- ------------------------------------------------------------
-- B3 修改系统配置（仅 super_admin，字段白名单 + 取值校验）
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- B8 维护模式开关（仅 super_admin；月度结算会自动开启）
--   V2.0.6：支持直接指定结束时间 p_until（优先于 p_minutes），可单独设置维护时间
-- ------------------------------------------------------------
drop function if exists public.admin_toggle_maintenance(boolean, int);
create or replace function public.admin_toggle_maintenance(
  p_on      boolean,
  p_minutes int default null,
  p_until   timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_until timestamptz;
begin
  perform public.require_super_admin();
  if coalesce(p_on, false) then
    if p_until is not null then
      if p_until <= now() then
        raise exception '维护结束时间必须晚于当前时间';
      end if;
      if p_until > now() + interval '7 days' then
        raise exception '维护结束时间不能超过 7 天';
      end if;
      v_until := p_until;
    else
      v_until := now() + make_interval(mins => coalesce(p_minutes,
        (select maintenance_minutes from public.app_config where id = 1), 30));
    end if;
  else
    v_until := null;
  end if;
  update public.app_config set maintenance_until = v_until, updated_at = now(), updated_by = auth.uid()
   where id = 1;
  perform public.notify_audience('all',
    case when v_until is null then '系统已恢复' else '系统维护中' end,
    case when v_until is null then '维护已结束，所有功能恢复可用。'
         else format('系统正在结算维护，预计到 %s 恢复，期间只读。',
                     to_char(v_until at time zone 'Asia/Shanghai', 'MM-DD HH24:MI')) end,
    'system');
  perform public.write_audit('toggle_maintenance', 'app_config', '1',
    jsonb_build_object('on', coalesce(p_on,false), 'until', v_until));
  return jsonb_build_object('maintenance', v_until is not null and v_until > now(), 'until', v_until);
end;
$$;
revoke all on function public.admin_toggle_maintenance(boolean, int, timestamptz) from public, anon, authenticated;
grant execute on function public.admin_toggle_maintenance(boolean, int, timestamptz) to authenticated;
