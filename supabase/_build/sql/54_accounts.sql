-- ============================================================
-- 54. 账号 RPC（五级角色 / 批量建号 / 自助注册 / 审核 / 状态 / 角色 / 改密 / 日志）
--   依赖：10_extensions(pgcrypto)、20_tables、30_helpers
--   约定：全部 security definer + 固定 search_path；
--         权限只走 public.require_role() / public.caller_role()
--         （SQL Editor / pg_cron 的 system 调用由 require_role 自动放行）；
--         每个函数末尾统一 revoke public/anon/authenticated，再按需 grant authenticated
--         （student_register 额外 grant 给 anon）。
--   分区：
--     54.1 账号创建 / 删除 / 批量建号
--     54.2 学生自助注册与审核
--     54.3 账号状态 / 角色 / 密码重置
--     54.4 自助改密 / 账号列表 / 登录日志
-- ============================================================

-- ============================================================
-- 54.1 账号创建 / 删除 / 批量建号
-- ============================================================

-- 创建用户（保留 V1.6 五参数签名）
--   A1/A8：super_admin 可创建任意五级角色；admin 只能创建 student；
--   system（SQL Editor / 种子数据）放行；
--   用户名已存在返回 null（保留 V1 幂等语义，供 schema 重复执行）。
create or replace function public.admin_create_user(
  p_username text,
  p_password text,
  p_name     text,
  p_role     text,
  p_group    text,
  p_force_change boolean default true
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller     text := public.caller_role();
  v_username   text := lower(btrim(coalesce(p_username, '')));
  v_name       text := btrim(coalesce(p_name, ''));
  v_group      text := nullif(btrim(coalesce(p_group, '')), '');
  v_email      text;
  v_id         uuid;
  v_student    public.students;
  v_student_id uuid;
  v_force      boolean := coalesce(p_force_change, true);
begin
  perform public.require_role(array['super_admin','admin']);

  if v_username = '' or p_password is null or btrim(p_password) = '' or v_name = '' then
    raise exception '请填写完整信息';
  end if;
  if char_length(p_password) < 6 then
    raise exception '密码长度至少 6 位';
  end if;
  if p_role is null or p_role not in ('super_admin','admin','executive','group_recorder','student') then
    raise exception '角色无效：%', coalesce(p_role, '');
  end if;
  -- A1/A8：老师与管理员账号只能由 super_admin 创建；admin 只能建学生账号
  if v_caller = 'admin' and p_role <> 'student' then
    raise exception '班主任只能创建学生账号';
  end if;

  -- 幂等：用户名已存在直接返回 null
  if exists (select 1 from public.profiles p where lower(p.username) = v_username) then
    return null;
  end if;

  if position('@' in v_username) > 0 then
    v_email := v_username;
  else
    v_email := v_username || '@banji.local';
  end if;
  if exists (select 1 from auth.users u where lower(u.email) = v_email) then
    raise exception '该邮箱已被占用，请更换用户名';
  end if;

  if p_role = 'student' then
    -- 学生角色必须绑定学生档案（用户名=学号）
    if position('@' in v_username) > 0 then
      raise exception '学生账号用户名必须为学号';
    end if;
    select s.* into v_student
      from public.students s
     where lower(btrim(coalesce(s.student_no, ''))) = v_username
     order by s.created_at, s.id
     limit 1;
    if not found then
      raise exception '该学号没有对应的学生档案，请先导入学生名单或使用批量建号';
    end if;
    if v_student.user_id is not null then
      raise exception '该学生已绑定登录账号';
    end if;
    if exists (select 1 from public.profiles p where p.student_id = v_student.id) then
      raise exception '该学生已绑定登录账号';
    end if;
    v_student_id := v_student.id;
    v_group := v_student.group_name;
  else
    v_student_id := null;
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    is_sso_user, is_anonymous
  ) values (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(), 'authenticated', 'authenticated', v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('provider','email','providers', jsonb_build_array('email'),
                       'role', p_role, 'group_name', coalesce(v_group,''), 'name', v_name),
    jsonb_build_object('name', v_name, 'role', p_role, 'group_name', coalesce(v_group,'')),
    '', '', '', '',
    false, false
  ) returning id into v_id;

  insert into public.profiles (id, username, name, role, group_name, student_id, status, must_change_password)
  values (v_id, v_username, v_name, p_role, v_group, v_student_id, 'active', v_force);

  if v_student_id is not null then
    update public.students set user_id = v_id where id = v_student_id;
  end if;

  perform public.write_audit('admin_create_user', 'profile', v_id::text,
    jsonb_build_object('username', v_username, 'role', p_role,
                       'group_name', coalesce(v_group, ''), 'student_id', v_student_id,
                       'force_change', v_force));

  return jsonb_build_object(
    'id', v_id,
    'username', v_username,
    'name', v_name,
    'role', p_role,
    'group_name', coalesce(v_group, ''),
    'student_id', v_student_id,
    'must_change_password', v_force
  );
end;
$$;
revoke all on function public.admin_create_user(text,text,text,text,text,boolean) from public, anon, authenticated;
grant execute on function public.admin_create_user(text,text,text,text,text,boolean) to authenticated;

-- 修改用户密码（保留 V1.6 签名；V2 仅 super_admin，A2）
create or replace function public.admin_set_password(p_id uuid, p_password text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_username text;
begin
  perform public.require_role(array['super_admin']);

  if p_id is null then
    raise exception '请选择用户';
  end if;
  if p_password is null or btrim(p_password) = '' then
    raise exception '请输入新密码';
  end if;
  if char_length(p_password) < 6 then
    raise exception '密码长度至少 6 位';
  end if;

  select p.username into v_username from public.profiles p where p.id = p_id;
  if not found then
    raise exception '用户不存在';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = p_id;

  update public.profiles
     set updated_at = now()
   where id = p_id;

  perform public.write_audit('admin_set_password', 'profile', p_id::text,
    jsonb_build_object('username', v_username));
end;
$$;
revoke all on function public.admin_set_password(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_set_password(uuid,text) to authenticated;

-- 删除用户（A1，仅 super_admin；不能删除自己；保留学生档案）
create or replace function public.admin_delete_user(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_username text;
  v_role     text;
begin
  perform public.require_role(array['super_admin']);

  if p_id is null then
    raise exception '请选择用户';
  end if;
  if auth.uid() is not null and p_id = auth.uid() then
    raise exception '不能删除当前登录用户';
  end if;

  -- 用户不存在则直接返回（幂等）
  if not exists (select 1 from auth.users u where u.id = p_id) then
    return;
  end if;

  select p.username, p.role into v_username, v_role
    from public.profiles p where p.id = p_id;

  -- 删除前解除学生绑定，学生档案保留
  update public.students set user_id = null where user_id = p_id;

  perform public.write_audit('admin_delete_user', 'profile', p_id::text,
    jsonb_build_object('username', v_username, 'role', v_role));

  delete from auth.users where id = p_id;
end;
$$;
revoke all on function public.admin_delete_user(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- 批量创建学生账号（A3：super_admin / admin）
--   为 user_id 为空且有学号的学生建号：用户名=学号，初始密码=参数或配置默认值；
--   双向绑定 profiles.student_id / students.user_id，must_change_password=true。
create or replace function public.admin_batch_create_students(
  p_password     text default null,
  p_force_change boolean default true
)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg      jsonb;
  v_pwd      text;
  v_force    boolean := coalesce(p_force_change, true);
  v_created  int := 0;
  v_skipped  jsonb := '[]'::jsonb;
  v_failed   jsonb := '[]'::jsonb;
  v_dup_nos  text[];
  v_id       uuid;
  v_no       text;
  v_email    text;
  r          record;
begin
  perform public.require_role(array['super_admin','admin']);

  v_cfg := public.cfg();
  if p_password is not null and btrim(p_password) <> '' then
    v_pwd := p_password;
  else
    v_pwd := coalesce(
      nullif(btrim(coalesce(v_cfg->>'default_student_password', '')), ''),
      '123456'
    );
  end if;
  if char_length(v_pwd) < 6 then
    raise exception '密码长度至少 6 位';
  end if;

  -- 预统计“未绑定学生中的重复学号”（重复学号一律跳过，避免绑错人）
  select coalesce(array_agg(t.no), array[]::text[])
    into v_dup_nos
    from (
      select lower(btrim(s.student_no)) as no
        from public.students s
       where s.user_id is null
         and btrim(coalesce(s.student_no, '')) <> ''
       group by 1
      having count(*) > 1
    ) t;

  for r in
    select s.id, s.name, s.student_no, s.group_name
      from public.students s
     where s.user_id is null
     order by s.student_no nulls last, s.created_at, s.id
  loop
    v_no := lower(btrim(coalesce(r.student_no, '')));

    if v_no = '' then
      v_skipped := v_skipped || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', '无学号');
      continue;
    end if;

    if v_no = any(v_dup_nos) then
      v_skipped := v_skipped || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', '学号重复');
      continue;
    end if;

    if exists (select 1 from public.profiles p where lower(p.username) = v_no) then
      v_skipped := v_skipped || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', '已存在账号');
      continue;
    end if;

    if exists (select 1 from public.profiles p where p.student_id = r.id) then
      v_skipped := v_skipped || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', '已存在账号');
      continue;
    end if;

    v_email := v_no || '@banji.local';
    if exists (select 1 from auth.users u where lower(u.email) = v_email) then
      v_skipped := v_skipped || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', '邮箱冲突');
      continue;
    end if;

    begin
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, created_at, updated_at,
        raw_app_meta_data, raw_user_meta_data,
        confirmation_token, recovery_token, email_change_token_new, email_change,
        is_sso_user, is_anonymous
      ) values (
        '00000000-0000-0000-0000-000000000000',
        gen_random_uuid(), 'authenticated', 'authenticated', v_email,
        extensions.crypt(v_pwd, extensions.gen_salt('bf')),
        now(), now(), now(),
        jsonb_build_object('provider','email','providers', jsonb_build_array('email'),
                           'role', 'student', 'group_name', coalesce(r.group_name,''), 'name', r.name),
        jsonb_build_object('name', r.name, 'role', 'student', 'group_name', coalesce(r.group_name,'')),
        '', '', '', '',
        false, false
      ) returning id into v_id;

      insert into public.profiles (id, username, name, role, group_name, student_id, status, must_change_password)
      values (v_id, v_no, r.name, 'student', r.group_name, r.id, 'active', v_force);

      update public.students set user_id = v_id where id = r.id;

      v_created := v_created + 1;
    exception when others then
      v_id := null;
      v_failed := v_failed || jsonb_build_object(
        'student_id', r.id, 'student_no', r.student_no, 'name', r.name, 'reason', sqlerrm);
    end;
  end loop;

  perform public.write_audit('admin_batch_create_students', 'profile', '',
    jsonb_build_object('created', v_created,
                       'skipped', jsonb_array_length(v_skipped),
                       'failed', jsonb_array_length(v_failed),
                       'force_change', v_force));

  perform public.notify_audience('admins', '学生批量建号完成',
    format('本次新建 %s 个学生账号，跳过 %s 个，失败 %s 个。初始密码已按配置设置，%s。',
           v_created, jsonb_array_length(v_skipped), jsonb_array_length(v_failed),
           case when v_force then '首次登录需修改密码' else '不强制修改密码' end));

  return jsonb_build_object(
    'created', v_created,
    'skipped', v_skipped,
    'failed', v_failed,
    'default_password', v_pwd,
    'must_change_password', v_force
  );
end;
$$;
revoke all on function public.admin_batch_create_students(text,boolean) from public, anon, authenticated;
grant execute on function public.admin_batch_create_students(text,boolean) to authenticated;

-- ============================================================
-- 54.2 学生自助注册与审核
-- ============================================================

-- 学生自助注册（公开可调，无需登录；仅校验邀请码）
--   与名单匹配：按 register_policy 直接激活 / 待审核，并双向绑定；
--   与名单不匹配：置 pending、student_id 空，等待 A4 审核。
create or replace function public.student_register(
  p_code     text,
  p_no       text,
  p_name     text,
  p_password text
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg        jsonb;
  v_enabled    boolean;
  v_invite     text;
  v_code       text := lower(btrim(coalesce(p_code, '')));
  v_no         text := btrim(coalesce(p_no, ''));
  v_name       text := btrim(coalesce(p_name, ''));
  v_pwd        text := coalesce(p_password, '');
  v_username   text;
  v_email      text;
  v_status     text;
  v_msg        text;
  v_id         uuid;
  v_student_id    uuid;
  v_student_group text;
  v_bound_user    uuid;
begin
  v_cfg := public.cfg();

  -- 注册开关与邀请码（去空格、不区分大小写）
  v_enabled := coalesce((v_cfg->>'invite_enabled')::boolean, false);
  if not v_enabled then
    raise exception '自助注册已关闭，请联系老师';
  end if;
  v_invite := lower(btrim(coalesce(v_cfg->>'invite_code', '')));
  if v_invite = '' then
    raise exception '邀请码未设置，暂无法自助注册';
  end if;
  if v_code = '' or v_code <> v_invite then
    raise exception '邀请码错误';
  end if;

  if char_length(v_pwd) < 6 then
    raise exception '密码长度至少 6 位';
  end if;
  if v_no = '' then
    raise exception '请填写学号';
  end if;
  if v_name = '' then
    raise exception '请填写姓名';
  end if;

  v_username := lower(v_no);

  -- 名单匹配：学号 + 姓名（均去空格后完全匹配）
  select s.id, s.group_name, s.user_id
    into v_student_id, v_student_group, v_bound_user
    from public.students s
   where lower(btrim(coalesce(s.student_no, ''))) = lower(v_no)
     and btrim(s.name) = v_name
   order by s.created_at, s.id
   limit 1;

  if found then
    if v_bound_user is not null then
      raise exception '该学号已注册';
    end if;
    if exists (select 1 from public.profiles p where p.student_id = v_student_id) then
      raise exception '该学号已注册';
    end if;
  else
    -- 名单外：等待审核
    v_student_id := null;
    v_student_group := null;
  end if;

  if exists (select 1 from public.profiles p where lower(p.username) = v_username) then
    raise exception '该学号已注册';
  end if;

  v_email := v_username || '@banji.local';
  if exists (select 1 from auth.users u where lower(u.email) = v_email) then
    raise exception '该学号已注册';
  end if;

  -- 匹配到名单且策略为 auto 才直接激活，否则待审核
  if v_student_id is not null
     and coalesce(v_cfg->>'register_policy', 'review') = 'auto' then
    v_status := 'active';
    v_msg := '注册成功，请使用学号和新密码登录';
  else
    v_status := 'pending';
    v_msg := '注册已提交，请等待老师审核';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    is_sso_user, is_anonymous
  ) values (
    '00000000-0000-0000-0000-000000000000',
    gen_random_uuid(), 'authenticated', 'authenticated', v_email,
    extensions.crypt(v_pwd, extensions.gen_salt('bf')),
    now(), now(), now(),
    jsonb_build_object('provider','email','providers', jsonb_build_array('email'),
                       'role', 'student', 'group_name', coalesce(v_student_group,''), 'name', v_name),
    jsonb_build_object('name', v_name, 'role', 'student', 'group_name', coalesce(v_student_group,'')),
    '', '', '', '',
    false, false
  ) returning id into v_id;

  insert into public.profiles (id, username, name, role, group_name, student_id, status, must_change_password)
  values (v_id, v_username, v_name, 'student',
          case when v_student_id is not null then v_student_group else null end,
          v_student_id, v_status, false);

  if v_student_id is not null then
    update public.students set user_id = v_id where id = v_student_id;
  end if;

  if v_status = 'pending' then
    perform public.notify_audience('admins', '有新的学生注册待审核',
      format('学生 %s（学号 %s）提交了注册申请，请及时审核。', v_name, v_no),
      'system', 'profile', v_id);
  end if;

  perform public.write_audit('student_register', 'profile', v_id::text,
    jsonb_build_object('username', v_username, 'name', v_name, 'student_no', v_no,
                       'status', v_status, 'matched', v_student_id is not null));

  return jsonb_build_object('status', v_status, 'message', v_msg);
end;
$$;
revoke all on function public.student_register(text,text,text,text) from public, anon, authenticated;
grant execute on function public.student_register(text,text,text,text) to anon;
grant execute on function public.student_register(text,text,text,text) to authenticated;

-- 学生注册审核（A4：super_admin / admin）
--   approve：pending → active，profile.student_id 为空时按 username=学号尝试绑定；
--   reject ：pending → disabled，并解除学生绑定。
create or replace function public.admin_review_student(p_id uuid, p_approve boolean)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_profile    public.profiles;
  v_student    public.students;
  v_sid        uuid;
  v_bind_group text;
  v_new_status text;
  v_msg        text;
begin
  perform public.require_role(array['super_admin','admin']);

  if p_id is null then
    raise exception '请选择待审核账号';
  end if;
  if p_approve is null then
    raise exception '请指定审核结果';
  end if;

  select p.* into v_profile from public.profiles p where p.id = p_id;
  if not found then
    raise exception '用户不存在';
  end if;
  if v_profile.role <> 'student' then
    raise exception '该账号不是学生账号';
  end if;
  if v_profile.status <> 'pending' then
    raise exception '该账号当前不是待审核状态';
  end if;

  if p_approve then
    v_sid := v_profile.student_id;
    if v_sid is null then
      -- 按 username=学号 尝试匹配名单
      select s.* into v_student
        from public.students s
       where lower(btrim(coalesce(s.student_no, ''))) = lower(v_profile.username)
       order by s.created_at, s.id
       limit 1;
      if found then
        if v_student.user_id is not null and v_student.user_id <> p_id then
          raise exception '该学号已绑定其他账号，无法通过审核';
        end if;
        if exists (select 1 from public.profiles p
                    where p.student_id = v_student.id and p.id <> p_id) then
          raise exception '该学生已绑定其他账号，无法通过审核';
        end if;
        v_sid := v_student.id;
        v_bind_group := v_student.group_name;
        update public.students set user_id = p_id where id = v_sid;
      end if;
    end if;

    update public.profiles
       set status = 'active', student_id = v_sid,
           group_name = coalesce(v_bind_group, group_name),
           updated_at = now()
     where id = p_id;

    v_new_status := 'active';
    v_msg := '已通过注册审核';
    perform public.notify(p_id, '注册审核通过', '您的账号已通过审核，现在可以登录使用了。');
  else
    update public.profiles
       set status = 'disabled', student_id = null, group_name = null, updated_at = now()
     where id = p_id;
    update public.students set user_id = null where user_id = p_id;

    v_new_status := 'disabled';
    v_msg := '已驳回注册申请';
    perform public.notify(p_id, '注册申请被驳回', '您的注册申请未通过审核，如有疑问请联系老师。');
  end if;

  perform public.write_audit('admin_review_student', 'profile', p_id::text,
    jsonb_build_object('username', v_profile.username, 'approve', p_approve,
                       'status', v_new_status, 'student_id', v_sid));

  return jsonb_build_object('id', p_id, 'status', v_new_status, 'message', v_msg);
end;
$$;
revoke all on function public.admin_review_student(uuid,boolean) from public, anon, authenticated;
grant execute on function public.admin_review_student(uuid,boolean) to authenticated;

-- ============================================================
-- 54.3 账号状态 / 角色 / 密码重置
-- ============================================================

-- 停用/启用/锁定账号（A5：super_admin / admin；脚注¹ 班主任不能操作管理员）
create or replace function public.admin_set_user_status(p_id uuid, p_status text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_target public.profiles;
  v_from   text;
begin
  perform public.require_role(array['super_admin','admin']);

  if p_id is null then
    raise exception '请选择用户';
  end if;
  p_status := btrim(coalesce(p_status, ''));
  if p_status not in ('active','pending','disabled') then
    raise exception '账号状态值无效，仅支持 active / pending / disabled';
  end if;

  select p.* into v_target from public.profiles p where p.id = p_id;
  if not found then
    raise exception '用户不存在';
  end if;

  if auth.uid() is not null and p_id = auth.uid() and p_status <> 'active' then
    raise exception '不能停用当前登录账号';
  end if;

  -- 脚注¹：班主任不能停用/启用 super_admin、admin
  if v_caller = 'admin' and v_target.role in ('super_admin','admin') then
    raise exception '班主任不能停用或启用管理员账号';
  end if;

  v_from := v_target.status;
  if v_from = p_status then
    return;
  end if;

  update public.profiles
     set status = p_status, updated_at = now()
   where id = p_id;

  perform public.write_audit('admin_set_user_status', 'profile', p_id::text,
    jsonb_build_object('username', v_target.username, 'from', v_from, 'to', p_status));

  if p_status = 'disabled' then
    perform public.notify(p_id, '账号已停用', '您的账号已被停用，如有疑问请联系老师。');
  else
    perform public.notify(p_id, '账号状态变更',
      format('您的账号状态已变更为 %s。', p_status));
  end if;
end;
$$;
revoke all on function public.admin_set_user_status(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_set_user_status(uuid,text) to authenticated;

-- 变更用户角色（A6：super_admin / admin；脚注¹ 班主任不能授予/撤销管理员角色，也不能改管理员）
create or replace function public.admin_change_user_role(p_id uuid, p_role text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_target public.profiles;
  v_from   text;
begin
  perform public.require_role(array['super_admin','admin']);

  if p_id is null then
    raise exception '请选择用户';
  end if;
  p_role := btrim(coalesce(p_role, ''));
  if p_role not in ('super_admin','admin','executive','group_recorder','student') then
    raise exception '角色无效：%', p_role;
  end if;

  select p.* into v_target from public.profiles p where p.id = p_id;
  if not found then
    raise exception '用户不存在';
  end if;

  if auth.uid() is not null and p_id = auth.uid() then
    raise exception '不能修改当前登录账号的角色';
  end if;

  -- 脚注¹：防越权
  if v_caller = 'admin' then
    if v_target.role in ('super_admin','admin') then
      raise exception '班主任不能修改管理员账号的角色';
    end if;
    if p_role in ('super_admin','admin') then
      raise exception '班主任不能授予管理员角色';
    end if;
  end if;

  v_from := v_target.role;
  if v_from = p_role then
    return;
  end if;

  update public.profiles
     set role = p_role, updated_at = now()
   where id = p_id;

  -- 同步 auth.users.raw_app_meta_data.role（jsonb_set 保留其他键）
  update auth.users
     set raw_app_meta_data = jsonb_set(
           coalesce(raw_app_meta_data, '{}'::jsonb),
           '{role}', to_jsonb(p_role), true),
         updated_at = now()
   where id = p_id;

  perform public.write_audit('admin_change_user_role', 'profile', p_id::text,
    jsonb_build_object('username', v_target.username, 'from', v_from, 'to', p_role));

  perform public.notify(p_id, '账号角色变更',
    format('您的账号角色已由 %s 调整为 %s。', v_from, p_role));
end;
$$;
revoke all on function public.admin_change_user_role(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_change_user_role(uuid,text) to authenticated;

-- 重置用户密码（A2：仅 super_admin；未传新密码时用默认密码，置强制改密）
create or replace function public.admin_reset_password(p_id uuid, p_new_password text default null)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_target public.profiles;
  v_pwd    text;
begin
  perform public.require_role(array['super_admin']);

  if p_id is null then
    raise exception '请选择用户';
  end if;

  select p.* into v_target from public.profiles p where p.id = p_id;
  if not found then
    raise exception '用户不存在';
  end if;

  if p_new_password is not null and btrim(p_new_password) <> '' then
    v_pwd := p_new_password;
  elsif v_target.role = 'student' then
    v_pwd := coalesce(
      nullif(btrim(coalesce(public.cfg()->>'default_student_password', '')), ''),
      '123456'
    );
  else
    v_pwd := '123456';
  end if;

  if char_length(v_pwd) < 6 then
    raise exception '密码长度至少 6 位';
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(v_pwd, extensions.gen_salt('bf')),
         updated_at = now()
   where id = p_id;

  update public.profiles
     set must_change_password = true, updated_at = now()
   where id = p_id;

  perform public.write_audit('admin_reset_password', 'profile', p_id::text,
    jsonb_build_object('username', v_target.username, 'role', v_target.role));

  perform public.notify(p_id, '密码已重置',
    '管理员重置了您的登录密码，请使用新密码登录，并尽快修改为自己的密码。');
end;
$$;
revoke all on function public.admin_reset_password(uuid,text) from public, anon, authenticated;
grant execute on function public.admin_reset_password(uuid,text) to authenticated;

-- ============================================================
-- 54.4 自助改密 / 账号列表 / 登录日志
-- ============================================================

-- 已登录用户自助改密（caller_role 不为 none/anon）
create or replace function public.change_my_password(p_old text, p_new text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid  uuid := auth.uid();
  v_role text := public.caller_role();
  v_ok   boolean;
begin
  if v_uid is null then
    raise exception '请先登录';
  end if;
  if v_role in ('none','anon') then
    raise exception '账号未激活或已停用，无法修改密码';
  end if;
  if p_new is null or char_length(p_new) < 6 then
    raise exception '密码长度至少 6 位';
  end if;

  -- 管理员（管理员/班主任）可直接修改自己的密码；其他角色必须验证旧密码
  if v_role not in ('super_admin','admin') then
    if p_old is null or p_old = '' then
      raise exception '请输入原密码';
    end if;
    select (u.encrypted_password = extensions.crypt(p_old, u.encrypted_password))
      into v_ok
      from auth.users u
     where u.id = v_uid;
    if not coalesce(v_ok, false) then
      raise exception '原密码不正确';
    end if;
  elsif p_old is not null and p_old <> '' then
    select (u.encrypted_password = extensions.crypt(p_old, u.encrypted_password))
      into v_ok
      from auth.users u
     where u.id = v_uid;
    if not coalesce(v_ok, false) then
      raise exception '原密码不正确';
    end if;
  end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_new, extensions.gen_salt('bf')),
         updated_at = now()
   where id = v_uid;

  update public.profiles
     set must_change_password = false, updated_at = now()
   where id = v_uid;

  perform public.write_audit('change_my_password', 'profile', v_uid::text, '{}'::jsonb);
end;
$$;
revoke all on function public.change_my_password(text,text) from public, anon, authenticated;
grant execute on function public.change_my_password(text,text) to authenticated;

-- 账号管理列表（system/super_admin 看全部；admin 看不到 super_admin；其他角色无权限）
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

-- 登录日志（任意已登录用户；不抛错）
create or replace function public.log_login()
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_uid   uuid := auth.uid();
  v_role  text;
  v_group text;
begin
  if v_uid is null then
    return;
  end if;

  select p.role, p.group_name into v_role, v_group
    from public.profiles p
   where p.id = v_uid;
  if v_role is null then
    return;
  end if;

  perform public.write_audit('login', 'auth', v_uid::text,
    jsonb_build_object('role', v_role, 'group_name', coalesce(v_group, '')));
exception when others then
  return; -- 登录日志失败不影响登录
end;
$$;
revoke all on function public.log_login() from public, anon, authenticated;
grant execute on function public.log_login() to authenticated;
