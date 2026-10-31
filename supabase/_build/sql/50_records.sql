-- ============================================================
-- 5. 积分记录 RPC（时间限制 / 2 秒冻结 / 规则上限 / 留痕）
--    以及积分规则、学生档案、排行榜
-- ============================================================

-- ------------------------------------------------------------
-- 5.1 内部：规则周期上限校验（add/update 共用，不对前端授权）
--     周期边界 = 最近一个已到点的周分隔点 / 自定义更新点 / 月分隔点
--     统计口径：**按被登记的学生**统计——同一学生在同一规则、同一周期内
--               最多登记 limit_value 次 / limit_value 分（不是全班合计）
-- ------------------------------------------------------------
create or replace function public.check_rule_limit(
  p_rule_id    uuid,
  p_points     numeric,
  p_student_id uuid,
  p_date       date,
  p_exclude    uuid default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  r        public.rules;
  v_w      public.boundaries;
  v_mult   int;
  v_limit  numeric;
  v_used   numeric;
  v_cnt    int;
  v_delta  numeric;
begin
  if p_rule_id is null then
    return;
  end if;
  select * into r from public.rules where id = p_rule_id;
  if r.id is null then
    raise exception '积分规则不存在';
  end if;
  if r.limit_type = 'none' or r.limit_value is null then
    return;
  end if;
  if p_student_id is null then
    raise exception '规则上限需要指定被登记的学生';
  end if;

  -- 周期 = 登记日期所在「周周期」；额度 = 单周期上限 × 规则计分周数
  v_w := public.period_of_date('week', coalesce(p_date, public.bj_today()));
  if v_w.id is null then
    raise exception '登记日期不在任何周周期内，请先在「设置 → 周期定义」补齐周期';
  end if;
  v_mult  := greatest(coalesce(v_w.rule_weeks, 1), 1);
  v_limit := r.limit_value * v_mult;
  v_delta := case when r.score_type = '扣分' then abs(p_points) else p_points end;

  select count(*),
         coalesce(sum(case when r.score_type = '扣分' then abs(rc.points) else rc.points end), 0)
    into v_cnt, v_used
    from public.records rc
   where rc.rule_id = p_rule_id
     and rc.student_id = p_student_id
     and rc.status = '正常'
     and rc.record_date >= to_char(v_w.start_date, 'YYYY-MM-DD')
     and rc.record_date <= to_char(v_w.end_date, 'YYYY-MM-DD')
     and (p_exclude is null or rc.id <> p_exclude);

  if r.limit_type = 'count' then
    if v_cnt + 1 > v_limit then
      raise exception '规则「%」每位学生本周期最多登记 % 次（该生已登记 % 次%s），已达上限',
        r.reason, v_limit::int, v_cnt,
        case when v_mult > 1 then '；本周按 ' || v_mult || ' 个规则计分周' else '' end;
    end if;
  else
    if v_used + v_delta > v_limit then
      raise exception '规则「%」每位学生本周期分值上限 %（该生已用 %，本次 %）%', r.reason, v_limit, v_used, v_delta,
        case when v_mult > 1 then '；本周按 ' || v_mult || ' 个规则计分周' else '' end;
    end if;
  end if;
end;
$$;
revoke all on function public.check_rule_limit(uuid, numeric, uuid, date, uuid) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 5.2 新增记录
-- ------------------------------------------------------------
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
  v_role  text := public.caller_role();
  v_rec   public.records;
  v_week  public.boundaries;
  v_month public.boundaries;
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

  v_week  := public.period_of_date('week', p_record_date);
  v_month := public.period_of_date('month', p_record_date);
  if v_week.id is null or v_month.id is null then
    raise exception '该日期不在任何周期内，请先在「设置 → 周期定义」补齐周期';
  end if;

  perform public.check_rule_limit(p_rule_id, p_points, p_student_id, p_record_date, null);

  insert into public.records (
    student_id, score_type, category, reason, points, recorder_id, recorder_name,
    record_date, status, evidence, rule_id, frozen_until, period_key
  ) values (
    p_student_id, p_score_type, coalesce(p_category,''), coalesce(p_reason,''), p_points, auth.uid(),
    (select p.name from public.profiles p where p.id = auth.uid()),
    p_record_date::text, '正常', p_evidence, p_rule_id,
    now() + interval '2 seconds', v_month.period_key
  ) returning * into v_rec;

  perform public.write_audit('add_record', 'record', v_rec.id::text,
    jsonb_build_object('student_id', p_student_id, 'points', p_points,
                       'reason', p_reason, 'record_date', p_record_date));
  return to_jsonb(v_rec);
end;
$$;
revoke all on function public.add_record(uuid, text, text, text, numeric, date, uuid, text) from public, anon, authenticated;
grant execute on function public.add_record(uuid, text, text, text, numeric, date, uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 5.3 修改记录
-- ------------------------------------------------------------
create or replace function public.update_record(
  p_id          uuid,
  p_reason      text,
  p_points      numeric,
  p_evidence    text default null,
  p_record_date date default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_old   public.records;
  v_new   public.records;
  v_date  date;
  v_week  public.boundaries;
  v_month public.boundaries;
begin
  perform public.require_role(array['super_admin','admin','executive','group_recorder'], '没有权限修改积分记录');
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能修改';
  end if;
  select * into v_old from public.records where id = p_id;
  if v_old.id is null then
    raise exception '记录不存在';
  end if;
  if v_old.status <> '正常' then
    raise exception '该记录已删除，不能修改';
  end if;
  if v_role = 'group_recorder' and not public.student_in_my_group(v_old.student_id) then
    raise exception '记录员只能修改本组记录';
  end if;
  if v_old.frozen_until is not null and now() < v_old.frozen_until then
    raise exception '该记录刚写入，处于 2 秒锁定中，请稍后再改';
  end if;
  if public.is_month_frozen((nullif(v_old.record_date,''))::date) then
    raise exception '该登记月已冻结，不能修改（管理员纠错除外）';
  end if;

  v_date := coalesce(p_record_date, (nullif(v_old.record_date,''))::date);
  if v_date is null then
    v_date := public.bj_today();
  end if;
  if public.is_future_date(v_date) then
    raise exception '不能登记未来日期';
  end if;
  if v_date <> (nullif(v_old.record_date,''))::date and public.is_month_frozen(v_date) then
    raise exception '目标登记月已冻结，不能改到该月';
  end if;

  v_week  := public.period_of_date('week', v_date);
  v_month := public.period_of_date('month', v_date);
  if v_week.id is null or v_month.id is null then
    raise exception '目标日期不在任何周期内，请先在「设置 → 周期定义」补齐周期';
  end if;

  perform public.check_rule_limit(v_old.rule_id, p_points, v_old.student_id, v_date, v_old.id);

  update public.records
     set reason      = coalesce(p_reason, reason),
         points      = p_points,
         evidence    = coalesce(p_evidence, evidence),
         record_date = v_date::text,
         period_key  = v_month.period_key,
         modified_by = auth.uid(),
         modified_by_name = (select p.name from public.profiles p where p.id = auth.uid()),
         modified_at = now(),
         frozen_until = now() + interval '2 seconds'
   where id = p_id
   returning * into v_new;

  perform public.write_audit('update_record', 'record', p_id::text,
    jsonb_build_object('old', jsonb_build_object('points', v_old.points, 'reason', v_old.reason, 'record_date', v_old.record_date),
                       'new', jsonb_build_object('points', p_points, 'reason', p_reason, 'record_date', v_date)));
  return to_jsonb(v_new);
end;
$$;
revoke all on function public.update_record(uuid, text, numeric, text, date) from public, anon, authenticated;
grant execute on function public.update_record(uuid, text, numeric, text, date) to authenticated;

-- ------------------------------------------------------------
-- 5.4 删除记录（软删除，保留流水与审计）
-- ------------------------------------------------------------
create or replace function public.delete_record(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_old  public.records;
  v_new  public.records;
begin
  perform public.require_role(array['super_admin','admin','executive','group_recorder'], '没有权限删除积分记录');
  if public.is_maintenance() then
    raise exception '系统月度结算维护中，暂时不能删除';
  end if;
  select * into v_old from public.records where id = p_id;
  if v_old.id is null then
    raise exception '记录不存在';
  end if;
  if v_old.status <> '正常' then
    raise exception '该记录已删除';
  end if;
  if v_role = 'group_recorder' and not public.student_in_my_group(v_old.student_id) then
    raise exception '记录员只能删除本组记录';
  end if;
  if v_old.frozen_until is not null and now() < v_old.frozen_until then
    raise exception '该记录刚写入，处于 2 秒锁定中，请稍后再删';
  end if;
  if public.is_month_frozen((nullif(v_old.record_date,''))::date) then
    raise exception '该登记月已冻结，不能删除（管理员纠错除外）';
  end if;

  update public.records
     set status = '已删除',
         modified_by = auth.uid(),
         modified_by_name = (select p.name from public.profiles p where p.id = auth.uid()),
         modified_at = now()
   where id = p_id
   returning * into v_new;

  perform public.write_audit('delete_record', 'record', p_id::text,
    jsonb_build_object('student_id', v_old.student_id, 'points', v_old.points,
                       'reason', v_old.reason, 'record_date', v_old.record_date));
  return to_jsonb(v_new);
end;
$$;
revoke all on function public.delete_record(uuid) from public, anon, authenticated;
grant execute on function public.delete_record(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5.5 C4 冻结月纠错（仅 super_admin，强制留痕）
--     p_patch 可含：points / reason / category / record_date / evidence / status('已删除')
-- ------------------------------------------------------------
create or replace function public.admin_fix_frozen_record(p_id uuid, p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_old public.records;
  v_new public.records;
  v_date date;
begin
  perform public.require_super_admin();
  select * into v_old from public.records where id = p_id;
  if v_old.id is null then
    raise exception '记录不存在';
  end if;
  if not public.is_month_frozen((nullif(v_old.record_date,''))::date) then
    raise exception '该记录不在冻结月，请用普通修改/删除';
  end if;

  v_date := coalesce((p_patch->>'record_date')::date, (nullif(v_old.record_date,''))::date);

  update public.records
     set points      = coalesce((p_patch->>'points')::numeric, points),
         reason      = coalesce(p_patch->>'reason', reason),
         category    = coalesce(p_patch->>'category', category),
         evidence    = coalesce(p_patch->>'evidence', evidence),
         record_date = v_date::text,
         period_key  = to_char(v_date, 'YYYY-MM'),
         status      = coalesce(p_patch->>'status', status),
         modified_by = auth.uid(),
         modified_by_name = (select p.name from public.profiles p where p.id = auth.uid()),
         modified_at = now(),
         frozen_until = null
   where id = p_id
   returning * into v_new;

  perform public.write_audit('admin_fix_frozen_record', 'record', p_id::text,
    jsonb_build_object('old', to_jsonb(v_old), 'patch', p_patch));
  return to_jsonb(v_new);
end;
$$;
revoke all on function public.admin_fix_frozen_record(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.admin_fix_frozen_record(uuid, jsonb) to authenticated;

-- ------------------------------------------------------------
-- 5.6 积分规则 CRUD（D4：super_admin/admin/executive）
-- ------------------------------------------------------------
create or replace function public.admin_save_rule(p_rule jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id   uuid;
  v_row  public.rules;
  v_type text := coalesce(p_rule->>'limit_type', 'none');
begin
  perform public.require_teacher();
  if coalesce(p_rule->>'score_type','') not in ('加分','扣分') then
    raise exception '积分类型必须是「加分」或「扣分」';
  end if;
  if coalesce(p_rule->>'category','') = '' or coalesce(p_rule->>'reason','') = '' then
    raise exception '请填写规则分类与说明';
  end if;
  if v_type not in ('none','count','points') then
    raise exception '上限类型不合法';
  end if;
  if v_type = 'none' then
    -- 清空上限
    null;
  elsif coalesce((p_rule->>'limit_value')::numeric, 0) <= 0 then
    raise exception '请填写大于 0 的周期上限值';
  end if;

  v_id := nullif(p_rule->>'id','')::uuid;
  if v_id is null then
    insert into public.rules (score_type, category, reason, points, remark, sort_order,
                              limit_type, limit_value)
    values (p_rule->>'score_type', p_rule->>'category', p_rule->>'reason',
            coalesce((p_rule->>'points')::numeric, 0), coalesce(p_rule->>'remark',''),
            coalesce((p_rule->>'sort_order')::int, 0), v_type,
            case when v_type = 'none' then null else (p_rule->>'limit_value')::numeric end)
    returning * into v_row;
  else
    update public.rules
       set score_type  = p_rule->>'score_type',
           category    = p_rule->>'category',
           reason      = p_rule->>'reason',
           points      = coalesce((p_rule->>'points')::numeric, 0),
           remark      = coalesce(p_rule->>'remark',''),
           sort_order  = coalesce((p_rule->>'sort_order')::int, sort_order),
           limit_type  = v_type,
           limit_value = case when v_type = 'none' then null else (p_rule->>'limit_value')::numeric end
     where id = v_id
     returning * into v_row;
    if v_row.id is null then
      raise exception '规则不存在';
    end if;
  end if;

  perform public.write_audit(
    case when nullif(p_rule->>'id','') is null then 'create_rule' else 'update_rule' end,
    'rule', v_row.id::text, jsonb_build_object('reason', v_row.reason, 'points', v_row.points,
                                               'limit_type', v_row.limit_type, 'limit_value', v_row.limit_value));
  return to_jsonb(v_row);
end;
$$;
revoke all on function public.admin_save_rule(jsonb) from public, anon, authenticated;
grant execute on function public.admin_save_rule(jsonb) to authenticated;

create or replace function public.admin_delete_rule(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_row public.rules;
begin
  perform public.require_teacher();
  select * into v_row from public.rules where id = p_id;
  if v_row.id is null then
    raise exception '规则不存在';
  end if;
  delete from public.rules where id = p_id;
  perform public.write_audit('delete_rule', 'rule', p_id::text,
    jsonb_build_object('reason', v_row.reason, 'points', v_row.points));
end;
$$;
revoke all on function public.admin_delete_rule(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_rule(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5.7 学生档案（D1；C6 删除学生仅 super_admin）
-- ------------------------------------------------------------
create or replace function public.admin_save_student(
  p_name       text,
  p_group_name text,
  p_student_no text default null,
  p_id         uuid default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_row public.students;
begin
  perform public.require_teacher();
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_group_name), '') = '' then
    raise exception '请填写学生姓名与小组';
  end if;
  if coalesce(trim(p_student_no), '') <> ''
     and exists (select 1 from public.students s
                  where s.student_no = trim(p_student_no)
                    and (p_id is null or s.id <> p_id)) then
    raise exception '学号「%」已被其他学生使用', trim(p_student_no);
  end if;

  if p_id is null then
    insert into public.students (name, group_name, student_no)
    values (trim(p_name), trim(p_group_name), nullif(trim(p_student_no), ''))
    returning * into v_row;
  else
    update public.students
       set name = trim(p_name), group_name = trim(p_group_name),
           student_no = nullif(trim(p_student_no), '')
     where id = p_id
     returning * into v_row;
    if v_row.id is null then
      raise exception '学生不存在';
    end if;
  end if;

  perform public.write_audit(
    case when p_id is null then 'create_student' else 'update_student' end,
    'student', v_row.id::text, to_jsonb(v_row));
  return to_jsonb(v_row);
end;
$$;
revoke all on function public.admin_save_student(text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.admin_save_student(text, text, text, uuid) to authenticated;

-- 批量导入/覆盖（前端「导入名单」用）：按学号匹配则更新，否则新增
create or replace function public.admin_import_students(p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_row     jsonb;
  v_id      uuid;
  v_ins     int := 0;
  v_upd     int := 0;
  v_skip    jsonb := '[]'::jsonb;
begin
  perform public.require_teacher();
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception '导入数据格式错误';
  end if;
  for v_row in select * from jsonb_array_elements(p_rows) loop
    if coalesce(trim(v_row->>'name'), '') = '' or coalesce(trim(v_row->>'group_name'), '') = '' then
      v_skip := v_skip || jsonb_build_array(jsonb_build_object('row', v_row, 'reason', '姓名或小组为空'));
      continue;
    end if;
    v_id := null;
    if coalesce(trim(v_row->>'student_no'), '') <> '' then
      select id into v_id from public.students where student_no = trim(v_row->>'student_no') limit 1;
    end if;
    if v_id is null then
      insert into public.students (name, group_name, student_no)
      values (trim(v_row->>'name'), trim(v_row->>'group_name'), nullif(trim(v_row->>'student_no'), ''));
      v_ins := v_ins + 1;
    else
      update public.students
         set name = trim(v_row->>'name'), group_name = trim(v_row->>'group_name')
       where id = v_id;
      v_upd := v_upd + 1;
    end if;
  end loop;
  perform public.write_audit('import_students', 'student', '', jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'skipped', v_skip));
  return jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'skipped', v_skip);
end;
$$;
revoke all on function public.admin_import_students(jsonb) from public, anon, authenticated;
grant execute on function public.admin_import_students(jsonb) to authenticated;

-- C6 删除学生档案（仅 super_admin）：连积分记录一起清，保留审计
create or replace function public.admin_delete_student(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_row public.students;
  v_rec int;
  v_users uuid[];
begin
  perform public.require_super_admin();
  select * into v_row from public.students where id = p_id;
  if v_row.id is null then
    raise exception '学生不存在';
  end if;
  -- 该学生已绑定的账号：连 auth.users 一起删除（profiles 随 auth.users 级联），
  -- 否则残留账号会占用邮箱/用户名，导致同学号无法重新建号（验收时实测踩到）
  select coalesce(array_agg(id), array[]::uuid[]) into v_users
    from public.profiles where student_id = p_id;
  delete from public.records where student_id = p_id;
  get diagnostics v_rec = row_count;
  update public.profiles set student_id = null where student_id = p_id;
  if array_length(v_users, 1) is not null then
    delete from auth.users where id = any(v_users);
  end if;
  delete from public.students where id = p_id;  -- 其余子表（抽选/星光/申诉/监督）随外键级联删除
  perform public.write_audit('delete_student', 'student', p_id::text,
    jsonb_build_object('name', v_row.name, 'group_name', v_row.group_name,
                       'student_no', v_row.student_no, 'deleted_records', v_rec,
                       'deleted_accounts', coalesce(array_length(v_users, 1), 0)));
end;
$$;
revoke all on function public.admin_delete_student(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_student(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5.8 排行榜（按学生信息可见范围裁剪：self_rank/all_open 可看排行榜，self_only 只看自己）
-- ------------------------------------------------------------
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
