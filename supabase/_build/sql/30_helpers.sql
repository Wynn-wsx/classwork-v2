-- ============================================================
-- 3. 辅助函数（角色 / 时间 / 配置 / 通知 / 审计）
--    约定：全部 security definer + 固定 search_path；
--          caller_role() 是唯一的“调用者身份”入口。
-- ============================================================

-- ------------------------------------------------------------
-- 3.1 调用者身份
--   'system'  = SQL Editor / pg_cron / service_role（无登录用户）
--   'anon'    = 未登录
--   'none'    = 已登录但档案缺失 / 待审核 / 已停用
--   其余为五级角色：super_admin / admin / executive / group_recorder / student
-- ------------------------------------------------------------
create or replace function public.caller_role()
returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_req    text := auth.role();
  v_role   text;
  v_status text;
begin
  if v_req is null or v_req = 'service_role' then
    return 'system';
  end if;
  if v_req = 'anon' then
    return 'anon';
  end if;
  select p.role, p.status into v_role, v_status
    from public.profiles p
   where p.id = auth.uid();
  if v_role is null then
    return 'none';
  end if;
  if v_status is not null and v_status <> 'active' then
    return 'none';
  end if;
  return v_role;
end;
$$;

create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.caller_role() = 'super_admin';
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.caller_role() in ('super_admin','admin');
$$;

create or replace function public.is_teacher() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.caller_role() in ('super_admin','admin','executive');
$$;

create or replace function public.is_recorder() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.caller_role() = 'group_recorder';
$$;

create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select public.caller_role() not in ('none','anon');
$$;

create or replace function public.my_profile_id() returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select auth.uid();
$$;

create or replace function public.my_student_id() returns uuid
language sql stable security definer set search_path = public, extensions as $$
  select p.student_id from public.profiles p where p.id = auth.uid();
$$;

create or replace function public.my_group_name() returns text
language sql stable security definer set search_path = public, extensions as $$
  -- 优先用账号上登记的小组；账号未填时按绑定的学生档案取（建号/改角色后可能只在学生档案里有小组）
  select coalesce(nullif(btrim(p.group_name), ''),
                  (select s.group_name from public.students s where s.id = p.student_id))
    from public.profiles p
   where p.id = auth.uid();
$$;

-- 该学生是否属于当前登录账号的小组（记录员看本组用；避免策略里再查 students 触发递归 RLS）
create or replace function public.student_in_my_group(p_student_id uuid)
returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.students s
     where s.id = p_student_id
       and s.group_name is not null
       and s.group_name = public.my_group_name()
  );
$$;

-- 当前登录学生是否为“当前周”监督委员（到期自动失效）
-- 注：写成 plpgsql 而非 sql，是为了避免“函数创建时立即校验引用的函数是否存在”
--     （current_week_key 在文件后面才定义，sql 语言函数会在创建时直接报错）。
create or replace function public.is_supervisor_now()
returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if public.caller_role() <> 'student' then
    return false;
  end if;
  return exists (
    select 1 from public.supervisor_assignments sa
     where sa.student_id = public.my_student_id()
       and sa.period_key = public.current_week_key()
       and sa.revoked_at is null
  );
end;
$$;

-- 权限断言：不满足直接抛异常；system 调用直接放行
create or replace function public.require_role(p_roles text[], p_msg text default '没有权限执行此操作')
returns void
language plpgsql stable security definer set search_path = public, extensions as $$
declare v text := public.caller_role();
begin
  if v = 'system' then return; end if;
  if v = any(p_roles) then return; end if;
  raise exception '%', p_msg;
end;
$$;

create or replace function public.require_admin() returns void
language plpgsql stable security definer set search_path = public, extensions as $$
begin perform public.require_role(array['super_admin','admin']); end;
$$;

create or replace function public.require_super_admin() returns void
language plpgsql stable security definer set search_path = public, extensions as $$
begin perform public.require_role(array['super_admin']); end;
$$;

create or replace function public.require_teacher() returns void
language plpgsql stable security definer set search_path = public, extensions as $$
begin perform public.require_role(array['super_admin','admin','executive']); end;
$$;

-- ------------------------------------------------------------
-- 3.2 时间（业务时区 Asia/Shanghai）
-- ------------------------------------------------------------
create or replace function public.bj_today() returns date
language sql stable security definer set search_path = public, extensions as $$
  select (now() at time zone 'Asia/Shanghai')::date;
$$;

create or replace function public.bj_month_key(p_ts timestamptz default now()) returns text
language sql stable security definer set search_path = public, extensions as $$
  select to_char(p_ts at time zone 'Asia/Shanghai', 'YYYY-MM');
$$;

create or replace function public.bj_week_start(p_date date) returns date
language sql immutable as $$
  select p_date - (extract(isodow from p_date)::int - 1);
$$;

-- ------------------------------------------------------------
-- V2.0.19 周期（区间）解析：周/月存 start_date ~ end_date，进行中的月 end_date 为空
-- period_key = 起始日期（稳定，不随周期关闭而改变）
-- ------------------------------------------------------------
create or replace function public.period_of_date(p_type text, p_date date)
returns public.boundaries
language sql stable security definer set search_path = public, extensions as $$
  select b.* from public.boundaries b
   where b.type = p_type
     and b.deprecated = false
     and b.start_date is not null
     and b.start_date <= p_date
     and coalesce(b.end_date, '9999-12-31'::date) >= p_date
   order by b.start_date desc
   limit 1;
$$;

-- 「当前」周期：优先含今天的；否则最近已开始的；否则最早一条
create or replace function public.current_period(p_type text)
returns public.boundaries
language plpgsql stable security definer set search_path = public, extensions as $$
declare v public.boundaries;
begin
  v := public.period_of_date(p_type, public.bj_today());
  if v.id is not null then return v; end if;
  select b.* into v from public.boundaries b
   where b.type = p_type and b.deprecated = false and b.start_date is not null
     and b.start_date <= public.bj_today()
   order by b.start_date desc limit 1;
  if v.id is not null then return v; end if;
  select b.* into v from public.boundaries b
   where b.type = p_type and b.deprecated = false and b.start_date is not null
   order by b.start_date limit 1;
  return v;
end;
$$;

create or replace function public.boundary_of(p_type text)
returns public.boundaries
language sql stable security definer set search_path = public, extensions as $$
  select public.current_period(p_type);
$$;

create or replace function public.period_key_of(p_type text, p_date date)
returns text
language sql stable security definer set search_path = public, extensions as $$
  select (public.period_of_date(p_type, p_date)).period_key;
$$;

create or replace function public.current_month_key() returns text
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((public.current_period('month')).period_key, public.bj_month_key());
$$;

create or replace function public.current_week_key() returns text
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((public.current_period('week')).period_key, public.bj_week_start(public.bj_today())::text);
$$;

create or replace function public.next_month_boundary_at() returns timestamptz
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
    (select (b.end_date + 1)::timestamp at time zone 'Asia/Shanghai'
       from public.boundaries b
      where b.type = 'month' and b.deprecated = false and b.end_date is not null
        and b.end_date >= public.bj_today()
      order by b.start_date limit 1),
    ((public.bj_week_start(public.bj_today()) + 7)::timestamp at time zone 'Asia/Shanghai')
  );
$$;

create or replace function public.is_future_date(p_date date) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select p_date > public.bj_today();
$$;

-- 该业务日期是否落在「已结算且已结束」的月区间内（冻结）
create or replace function public.is_month_frozen(p_date date) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.boundaries b
     where b.type = 'month' and b.deprecated = false and b.settled = true
       and b.end_date is not null
       and p_date <= b.end_date
  );
$$;

create or replace function public.is_maintenance() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
    (nullif(public.cfg()->>'maintenance_until',''))::timestamptz > now(),
    false
  );
$$;

-- ------------------------------------------------------------
-- 3.3 系统配置（app_config 单行 → jsonb）
-- ------------------------------------------------------------
create or replace function public.cfg() returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(
    (select to_jsonb(c) from public.app_config c where c.id = 1),
    '{}'::jsonb
  );
$$;

-- ------------------------------------------------------------
-- 3.4 业务查询辅助
-- ------------------------------------------------------------
create or replace function public.student_group(p_student_id uuid) returns text
language sql stable security definer set search_path = public, extensions as $$
  select s.group_name from public.students s where s.id = p_student_id;
$$;

create or replace function public.group_members(p_group text) returns uuid[]
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(array_agg(s.id order by s.created_at, s.id), array[]::uuid[])
    from public.students s
   where s.group_name = p_group;
$$;

-- ------------------------------------------------------------
-- 3.5 审计与通知（内部函数：仅允许其他 definer 函数调用，不对前端授权）
-- ------------------------------------------------------------
create or replace function public.write_audit(
  p_action      text,
  p_target_type text,
  p_target_id   text,
  p_detail      jsonb default '{}'::jsonb
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_name text;
begin
  select p.name into v_name from public.profiles p where p.id = auth.uid();
  insert into public.audit_logs (actor_id, actor_name, action, target_type, target_id, detail)
  values (
    auth.uid(),
    coalesce(v_name, case when auth.uid() is null then 'system' else '未知用户' end),
    p_action,
    coalesce(p_target_type, ''),
    coalesce(p_target_id, ''),
    coalesce(p_detail, '{}'::jsonb)
  );
end;
$$;

create or replace function public.notify(
  p_recipient  uuid,
  p_title      text,
  p_body       text,
  p_category   text default 'system',
  p_related_type text default null,
  p_related_id uuid default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_recipient is null then
    return;
  end if;
  insert into public.notifications (recipient_id, title, body, category, related_type, related_id)
  values (p_recipient, coalesce(p_title,'通知'), coalesce(p_body,''), coalesce(p_category,'system'),
          p_related_type, p_related_id);
end;
$$;

create or replace function public.notify_audience(
  p_audience   text,
  p_title      text,
  p_body       text,
  p_category   text default 'system',
  p_related_type text default null,
  p_related_id uuid default null
) returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_count int := 0;
begin
  insert into public.notifications (recipient_id, title, body, category, related_type, related_id)
  select p.id, coalesce(p_title,'通知'), coalesce(p_body,''), coalesce(p_category,'system'),
         p_related_type, p_related_id
    from public.profiles p
   where p.status = 'active'
     and (
       p_audience = 'all'
       or (p_audience = 'students' and p.role = 'student')
       or (p_audience = 'teachers' and p.role in ('super_admin','admin','executive','group_recorder'))
       or (p_audience = 'admins' and p.role in ('super_admin','admin'))
       or (p_audience = 'executive_plus' and p.role in ('super_admin','admin','executive'))
     );
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
