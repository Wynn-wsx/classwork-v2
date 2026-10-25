-- ============================================================
-- 班级积分管理系统 V2.0.9 增量补丁（在 V2.0.8 已部署的库上执行）
--
-- 适用：已经跑过 schema.sql（V2.0.8）或 patch_v2.0.8 的数据库。
-- 内容：
--   1) 账号：创建账号/批量建号支持「是否强制首次改密」；改密校验规则按角色区分
--   2) 周期汇总：执行小组（executive）也可以手动汇总/结算
--   3) 数据管理：积分明细导入、星光台账导入、按日期导出、汇总导出、星光表格批量改值
--   4) 仓库管理：按小组/按个人查看学生卡片，批量标记已使用/作废
--
-- 幂等：可重复执行（create or replace / drop if exists + create）。
-- 执行位置：Supabase 控制台 → SQL Editor，整段粘贴执行。
-- 执行后请在同一个 SQL Editor 里再执行一次：notify pgrst, 'reload schema';
-- ============================================================

-- 0. 清理旧签名（参数个数变化，必须显式 drop，否则会留下重载函数导致调用歧义）
drop function if exists public.admin_create_user(text, text, text, text, text);
drop function if exists public.admin_batch_create_students(text);


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



create or replace function public.admin_import_records(p_rows jsonb, p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role     text := public.caller_role();
  v_row      jsonb;
  v_idx      int := 0;
  v_ok       int := 0;
  v_skip     int := 0;
  v_fail     int := 0;
  v_errors   jsonb := '[]'::jsonb;
  v_no       text;
  v_name     text;
  v_stype    text;
  v_cat      text;
  v_reason   text;
  v_points   numeric;
  v_date     text;
  v_recname  text;
  v_status   text;
  v_stu      public.students;
  v_stu_id   uuid;
  v_recdate  date;
  v_key      text;
begin
  perform public.require_role(array['super_admin','admin'], '只有管理员或班主任可以导入积分明细');
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception '导入数据格式错误：需要数组';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception '单次最多导入 5000 条记录';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_no      := nullif(btrim(coalesce(v_row->>'student_no', v_row->>'学号', '')), '');
      v_name    := nullif(btrim(coalesce(v_row->>'student_name', v_row->>'姓名', v_row->>'学生', '')), '');
      v_stype   := nullif(btrim(coalesce(v_row->>'score_type', v_row->>'类型', '')), '');
      v_cat     := nullif(btrim(coalesce(v_row->>'category', v_row->>'分类', '')), '');
      v_reason  := nullif(btrim(coalesce(v_row->>'reason', v_row->>'原因', '')), '');
      v_recname := nullif(btrim(coalesce(v_row->>'recorder_name', v_row->>'记录人', '')), '');
      v_status  := coalesce(nullif(btrim(coalesce(v_row->>'status', v_row->>'状态', '')), ''), '正常');
      v_date    := nullif(btrim(coalesce(v_row->>'record_date', v_row->>'日期', '')), '');

      begin
        v_points := nullif(btrim(coalesce(v_row->>'points', v_row->>'分值', '')), '')::numeric;
      exception when others then
        raise exception '第 % 行：分值不是数字', v_idx;
      end;

      if v_reason is null then raise exception '第 % 行：缺少原因', v_idx; end if;
      if v_points is null then raise exception '第 % 行：缺少分值', v_idx; end if;
      if v_stype is null then v_stype := case when v_points >= 0 then '加分' else '扣分' end; end if;

      v_stu_id := null;
      if v_no is not null then
        select s.* into v_stu from public.students s
         where lower(btrim(coalesce(s.student_no, ''))) = lower(v_no)
         order by s.created_at, s.id limit 1;
        if found then v_stu_id := v_stu.id; end if;
      end if;
      if v_stu_id is null and v_name is not null then
        select s.* into v_stu from public.students s
         where btrim(s.name) = v_name
         order by s.created_at, s.id limit 1;
        if found then
          if exists (select 1 from public.students s where btrim(s.name) = v_name and s.id <> v_stu.id) then
            raise exception '第 % 行：姓名「%」对应多名学生，请补充学号', v_idx, v_name;
          end if;
          v_stu_id := v_stu.id;
        end if;
      end if;
      if v_stu_id is null then
        raise exception '第 % 行：找不到学生（学号 % / 姓名 %）', v_idx, coalesce(v_no, '空'), coalesce(v_name, '空');
      end if;

      if v_date is null then
        v_recdate := public.bj_today();
      else
        begin
          v_recdate := (replace(replace(btrim(v_date), '/', '-'), '.', '-'))::date;
        exception when others then
          raise exception '第 % 行：日期格式无法识别（%）', v_idx, v_date;
        end;
      end if;
      if v_recdate > public.bj_today() then
        raise exception '第 % 行：日期不能晚于今天（%）', v_idx, v_recdate;
      end if;

      if p_dry_run then
        v_ok := v_ok + 1;
        continue;
      end if;

      v_key := to_char(v_recdate, 'YYYY-MM');
      insert into public.records (
        id, student_id, score_type, category, reason, points,
        recorder_id, record_date, status, evidence,
        period_key, recorder_name, created_at
      ) values (
        gen_random_uuid(), v_stu_id, v_stype, coalesce(v_cat, '导入'), v_reason, v_points,
        null, to_char(v_recdate, 'YYYY-MM-DD'), v_status, null,
        v_key, coalesce(v_recname, '历史导入'), v_recdate::timestamptz + interval '8 hours'
      );
      v_ok := v_ok + 1;
    exception when others then
      v_fail := v_fail + 1;
      if jsonb_array_length(v_errors) < 30 then
        v_errors := v_errors || jsonb_build_object('row', v_idx, 'reason', sqlerrm);
      end if;
    end;
  end loop;

  perform public.write_audit('admin_import_records', 'records', null,
    jsonb_build_object('total', v_idx, 'imported', v_ok, 'failed', v_fail, 'dry_run', p_dry_run));

  return jsonb_build_object('total', v_idx, 'imported', v_ok, 'skipped', v_skip,
                            'failed', v_fail, 'errors', v_errors, 'dry_run', p_dry_run);
end;
$$;

revoke all on function public.admin_import_records(jsonb, boolean) from public, anon, authenticated;
grant execute on function public.admin_import_records(jsonb, boolean) to authenticated;



create or replace function public.starlight_import(p_rows jsonb, p_mode text default 'append')
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_mode    text := lower(btrim(coalesce(p_mode, 'append')));
  v_row     jsonb;
  v_idx     int := 0;
  v_ok      int := 0;
  v_fail    int := 0;
  v_errors  jsonb := '[]'::jsonb;
  v_no      text;
  v_name    text;
  v_amt     int;
  v_note    text;
  v_at      timestamptz;
  v_at_raw  text;
  v_mk      text;
  v_stu     public.students;
  v_stu_id  uuid;
  v_cleared int := 0;
begin
  perform public.require_role(array['super_admin','admin'], '只有管理员或班主任可以导入星光台账');
  if v_mode not in ('replace', 'append') then
    raise exception '导入方式无效：%', v_mode;
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception '导入数据格式错误：需要数组';
  end if;

  if v_mode = 'replace' then
    delete from public.starlight_logs where true;
    get diagnostics v_cleared = row_count;
    update public.starlight_accounts set balance = 0, updated_at = now();
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_no   := nullif(btrim(coalesce(v_row->>'student_no', v_row->>'学号', '')), '');
      v_name := nullif(btrim(coalesce(v_row->>'student_name', v_row->>'姓名', v_row->>'学生', '')), '');
      v_note := nullif(btrim(coalesce(v_row->>'note', v_row->>'说明', '')), '');
      v_at_raw := nullif(btrim(coalesce(v_row->>'created_at', v_row->>'时间', v_row->>'日期', '')), '');

      begin
        v_amt := nullif(btrim(coalesce(v_row->>'change_amount', v_row->>'变动', v_row->>'变化', '')), '')::int;
      exception when others then
        raise exception '第 % 行：变动数量不是整数', v_idx;
      end;
      if v_amt is null or v_amt = 0 then raise exception '第 % 行：变动数量不能为空或 0', v_idx; end if;

      v_stu_id := null;
      if v_no is not null then
        select s.* into v_stu from public.students s
         where lower(btrim(coalesce(s.student_no, ''))) = lower(v_no)
         order by s.created_at, s.id limit 1;
        if found then v_stu_id := v_stu.id; end if;
      end if;
      if v_stu_id is null and v_name is not null then
        select s.* into v_stu from public.students s
         where btrim(s.name) = v_name order by s.created_at, s.id limit 1;
        if found then
          if exists (select 1 from public.students s where btrim(s.name) = v_name and s.id <> v_stu.id) then
            raise exception '第 % 行：姓名「%」对应多名学生，请补充学号', v_idx, v_name;
          end if;
          v_stu_id := v_stu.id;
        end if;
      end if;
      if v_stu_id is null then
        raise exception '第 % 行：找不到学生（学号 % / 姓名 %）', v_idx, coalesce(v_no, '空'), coalesce(v_name, '空');
      end if;

      if v_at_raw is null then
        v_at := now();
      else
        begin
          v_at := replace(replace(btrim(v_at_raw), '/', '-'), '.', '-')::timestamptz;
        exception when others then
          raise exception '第 % 行：时间格式无法识别（%）', v_idx, v_at_raw;
        end;
      end if;

      v_mk := to_char(v_at at time zone 'Asia/Shanghai', 'YYYY-MM');
      insert into public.starlight_logs (student_id, change_amount, source, period_key, note, created_at)
      values (v_stu_id, v_amt, 'manual', v_mk, coalesce(v_note, '导入'), v_at);
      v_ok := v_ok + 1;
    exception when others then
      v_fail := v_fail + 1;
      if jsonb_array_length(v_errors) < 30 then
        v_errors := v_errors || jsonb_build_object('row', v_idx, 'reason', sqlerrm);
      end if;
    end;
  end loop;

  perform public._recalc_starlight(s.id) from public.students s;

  perform public.write_audit('starlight_import', 'starlight_logs', null,
    jsonb_build_object('mode', v_mode, 'total', v_idx, 'imported', v_ok,
                       'failed', v_fail, 'cleared', v_cleared));

  return jsonb_build_object('mode', v_mode, 'total', v_idx, 'imported', v_ok,
                            'failed', v_fail, 'cleared', v_cleared, 'errors', v_errors);
end;
$$;

revoke all on function public.starlight_import(jsonb, text) from public, anon, authenticated;
grant execute on function public.starlight_import(jsonb, text) to authenticated;



create or replace function public.admin_export_records(p_from date default null, p_to date default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_res    jsonb;
begin
  if v_caller not in ('system','super_admin','admin','executive') then
    raise exception '没有权限导出积分明细';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'record_date', r.record_date,
           'student_no', s.student_no,
           'student_name', s.name,
           'group_name', s.group_name,
           'score_type', r.score_type,
           'category', r.category,
           'reason', r.reason,
           'points', r.points,
           'status', r.status,
           'period_key', r.period_key,
           'recorder_name', coalesce(r.recorder_name, rp.name, ''),
           'created_at', r.created_at
         ) order by r.record_date, s.student_no nulls last, r.created_at), '[]'::jsonb)
    into v_res
    from public.records r
    join public.students s on s.id = r.student_id
    left join public.profiles rp on rp.id = r.recorder_id
   where (p_from is null or r.record_date >= to_char(p_from, 'YYYY-MM-DD'))
     and (p_to is null or r.record_date <= to_char(p_to, 'YYYY-MM-DD'));

  return jsonb_build_object('count', jsonb_array_length(v_res),
                            'from', p_from, 'to', p_to, 'rows', v_res);
end;
$$;

revoke all on function public.admin_export_records(date, date) from public, anon, authenticated;
grant execute on function public.admin_export_records(date, date) to authenticated;



create or replace function public.starlight_export_logs(p_from date default null, p_to date default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_res    jsonb;
begin
  if v_caller not in ('system','super_admin','admin','executive') then
    raise exception '没有权限导出星光流水';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'created_at', l.created_at,
           'student_no', s.student_no,
           'student_name', s.name,
           'group_name', s.group_name,
           'change_amount', l.change_amount,
           'source', l.source,
           'period_key', l.period_key,
           'note', coalesce(l.note, '')
         ) order by l.created_at), '[]'::jsonb)
    into v_res
    from public.starlight_logs l
    join public.students s on s.id = l.student_id
   where (p_from is null or (l.created_at at time zone 'Asia/Shanghai')::date >= p_from)
     and (p_to is null or (l.created_at at time zone 'Asia/Shanghai')::date <= p_to);

  return jsonb_build_object('count', jsonb_array_length(v_res),
                            'from', p_from, 'to', p_to, 'rows', v_res);
end;
$$;

revoke all on function public.starlight_export_logs(date, date) from public, anon, authenticated;
grant execute on function public.starlight_export_logs(date, date) to authenticated;



create or replace function public.admin_export_summaries(p_type text default 'week', p_limit int default 60)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_caller text := public.caller_role();
  v_type   text := lower(btrim(coalesce(p_type, 'week')));
  v_res    jsonb;
begin
  if v_caller not in ('system','super_admin','admin','executive','group_recorder') then
    raise exception '没有权限导出汇总';
  end if;
  if v_type = 'week' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'period_key', w.period_key,
             'range_start', w.range_start,
             'range_end', w.range_end,
             'groups', w.summary->'groups',
             'individuals', w.summary->'individuals',
             'reward_groups', w.summary->'reward_groups',
             'penalty_groups', w.summary->'penalty_groups',
             'reward_group_chances', coalesce((w.summary->>'reward_group_chances')::int, 0),
             'penalty_group_chances', coalesce((w.summary->>'penalty_group_chances')::int, 0)
           ) order by w.range_end desc), '[]'::jsonb)
      into v_res
      from (select * from public.weekly_summaries order by range_end desc limit greatest(coalesce(p_limit, 60), 1)) w;
    return jsonb_build_object('type', 'week', 'count', jsonb_array_length(v_res), 'rows', v_res);
  elsif v_type = 'month' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'period_key', st.period_key,
             'status', st.status,
             'finished_at', st.finished_at,
             'auto_draw_count', st.auto_draw_count,
             'second_class', st.second_class,
             'reward_rows', st.summary->'reward'->'rows',
             'penalty_rows', st.summary->'penalty'->'rows'
           ) order by st.period_key desc), '[]'::jsonb)
      into v_res
      from (select * from public.settlements
             where status <> 'rolled_back'
             order by period_key desc limit greatest(coalesce(p_limit, 60), 1)) st;
    return jsonb_build_object('type', 'month', 'count', jsonb_array_length(v_res), 'rows', v_res);
  else
    raise exception '汇总类型无效：%', v_type;
  end if;
end;
$$;

revoke all on function public.admin_export_summaries(text, int) from public, anon, authenticated;
grant execute on function public.admin_export_summaries(text, int) to authenticated;



create or replace function public.starlight_batch_set_balance(p_rows jsonb, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role    text := public.caller_role();
  v_row     jsonb;
  v_idx     int := 0;
  v_changed int := 0;
  v_skip    int := 0;
  v_errors  jsonb := '[]'::jsonb;
  v_stu_id  uuid;
  v_new     int;
  v_cur     int;
  v_diff    int;
  v_mk      text := public.current_month_key();
begin
  perform public.require_role(array['super_admin','admin','executive'], '只有执行小组及以上可以修改星光');
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception '数据格式错误：需要数组';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_idx := v_idx + 1;
    begin
      v_stu_id := nullif(btrim(coalesce(v_row->>'student_id', '')), '')::uuid;
      if v_stu_id is null then
        raise exception '第 % 行：缺少学生', v_idx;
      end if;
      v_new := nullif(btrim(coalesce(v_row->>'balance', v_row->>'new_balance', '')), '')::int;
      if v_new is null then
        v_skip := v_skip + 1;
        continue;
      end if;
      if v_new < 0 then
        raise exception '第 % 行：星光值不能为负数', v_idx;
      end if;

      select coalesce(sum(change_amount), 0)::int into v_cur
        from public.starlight_logs where student_id = v_stu_id;
      v_diff := v_new - coalesce(v_cur, 0);
      if v_diff = 0 then
        v_skip := v_skip + 1;
        continue;
      end if;

      insert into public.starlight_logs (student_id, change_amount, source, period_key, note, created_at)
      values (v_stu_id, v_diff, 'manual', v_mk,
              coalesce(nullif(btrim(coalesce(p_note, '')), ''), '表格批量调整'), now());
      perform public._recalc_starlight(v_stu_id);
      v_changed := v_changed + 1;
    exception when others then
      if jsonb_array_length(v_errors) < 30 then
        v_errors := v_errors || jsonb_build_object('row', v_idx, 'reason', sqlerrm);
      end if;
    end;
  end loop;

  perform public.write_audit('starlight_batch_set_balance', 'starlight_logs', null,
    jsonb_build_object('rows', v_idx, 'changed', v_changed, 'note', coalesce(p_note, '')));

  return jsonb_build_object('rows', v_idx, 'changed', v_changed, 'skipped', v_skip, 'errors', v_errors);
end;
$$;

revoke all on function public.starlight_batch_set_balance(jsonb, text) from public, anon, authenticated;
grant execute on function public.starlight_batch_set_balance(jsonb, text) to authenticated;



create or replace function public.admin_warehouse(
  p_scope      text default 'group',
  p_group      text default null,
  p_student_id uuid default null,
  p_status     text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_scope  text := lower(btrim(coalesce(p_scope, 'group')));
  v_stmt   text;
  v_result jsonb;
begin
  if v_role not in ('system','super_admin','admin','executive') then
    raise exception '只有执行小组及以上可以管理仓库';
  end if;
  if v_scope not in ('group','student') then
    raise exception '查看方式无效：%', v_scope;
  end if;

  v_stmt := $q$
    select coalesce(jsonb_agg(row_data order by grp, stu_name), '[]'::jsonb)
      from (
        select s.group_name as grp,
               s.name as stu_name,
               s.id as student_id,
               jsonb_build_object(
                 'student_id', s.id,
                 'student_no', s.student_no,
                 'name', s.name,
                 'group_name', s.group_name,
                 'cards', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'id', d.id,
                            'drawn_at', d.drawn_at,
                            'pool_type', d.pool_type,
                            'item_title', coalesce(d.item_snapshot->>'title', ''),
                            'status', d.status,
                            'expire_at', d.expire_at,
                            'source', d.source,
                            'note', coalesce(d.note, ''),
                            'is_group', d.is_group
                          ) order by d.drawn_at desc)
                     from public.lottery_draws d
                    where d.student_id = s.id
                      and ($4 is null or d.status = $4)
                 ), '[]'::jsonb)
               ) as row_data
          from public.students s
         where ($2 is null or s.group_name = $2)
           and ($3 is null or s.id = $3)
      ) t
  $q$;

  execute v_stmt into v_result using p_scope, p_group, p_student_id, p_status;

  return jsonb_build_object('scope', v_scope, 'students', v_result,
                            'total_students', jsonb_array_length(v_result));
end;
$$;

revoke all on function public.admin_warehouse(text, text, uuid, text) from public, anon, authenticated;
grant execute on function public.admin_warehouse(text, text, uuid, text) to authenticated;



create or replace function public.admin_batch_mark_cards(
  p_draw_ids uuid[],
  p_status   text default 'used',
  p_note     text default null,
  p_used_at  timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role     text := public.caller_role();
  v_status   text := lower(btrim(coalesce(p_status, 'used')));
  v_id       uuid;
  v_draw     public.lottery_draws;
  v_ok       int := 0;
  v_skip     int := 0;
  v_errors   jsonb := '[]'::jsonb;
  v_used     timestamptz := coalesce(p_used_at, now());
begin
  if v_role not in ('system','super_admin','admin','executive') then
    raise exception '只有执行小组及以上可以标记仓库卡片';
  end if;
  if v_status not in ('used','void','expired') then
    raise exception '标记状态无效：%', v_status;
  end if;
  if p_draw_ids is null or array_length(p_draw_ids, 1) is null then
    raise exception '请先选择要标记的卡片';
  end if;

  foreach v_id in array p_draw_ids loop
    begin
      select * into v_draw from public.lottery_draws where id = v_id for update;
      if not found then
        v_skip := v_skip + 1;
        v_errors := v_errors || jsonb_build_object('id', v_id, 'reason', '卡片不存在');
        continue;
      end if;
      if v_status = 'void' and v_role not in ('system','super_admin','admin') then
        raise exception '只有管理员或班主任可以作废卡片';
      end if;
      if v_draw.status = v_status then
        v_skip := v_skip + 1;
        continue;
      end if;
      if v_status = 'used' then
        if v_draw.status not in ('unused','expired') then
          raise exception '该卡片当前状态为「%」，不能标记已使用', v_draw.status;
        end if;
        if v_draw.expire_at is not null and v_used > v_draw.expire_at then
          raise exception '使用时间超出卡片有效期（有效期至 %）', to_char(v_draw.expire_at at time zone 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI');
        end if;
        update public.lottery_draws
           set status = 'used', used_by = auth.uid(), used_at = v_used,
               note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note)
         where id = v_id;
      else
        update public.lottery_draws
           set status = v_status,
               note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note)
         where id = v_id;
      end if;
      v_ok := v_ok + 1;
    exception when others then
      v_skip := v_skip + 1;
      if jsonb_array_length(v_errors) < 30 then
        v_errors := v_errors || jsonb_build_object('id', v_id, 'reason', sqlerrm);
      end if;
    end;
  end loop;

  perform public.write_audit('admin_batch_mark_cards', 'lottery_draws', null,
    jsonb_build_object('status', v_status, 'ok', v_ok, 'skip', v_skip));

  return jsonb_build_object('status', v_status, 'ok', v_ok, 'skipped', v_skip, 'errors', v_errors);
end;
$$;

revoke all on function public.admin_batch_mark_cards(uuid[], text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.admin_batch_mark_cards(uuid[], text, text, timestamptz) to authenticated;


-- 自检（应全部返回 true / 数量与期望一致）
select
  exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'admin_import_records')            as has_import_records,
  exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'starlight_import')                as has_starlight_import,
  exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'admin_warehouse')                 as has_warehouse,
  exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'admin_batch_mark_cards')          as has_batch_mark,
  exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'starlight_batch_set_balance')     as has_starlight_batch,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'admin_create_user')                    as create_user_overloads,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'admin_batch_create_students')          as batch_create_overloads;
