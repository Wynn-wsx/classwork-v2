-- ============================================================
-- V2.0.18 补丁：规则周期上限改为「按被登记的学生」统计
-- 适用：已部署 V2.0.x（含 V2.0.17）的库，幂等，可重复执行
-- 执行后请运行：select pg_notify('pgrst', 'reload schema');
-- ============================================================

-- 1) 删除旧的三参数版本（否则 add_record 可能命中旧签名）
drop function if exists public.check_rule_limit(uuid, numeric, uuid);

-- 2) 新的按学生统计的 check_rule_limit
create or replace function public.check_rule_limit(
  p_rule_id   uuid,
  p_points    numeric,
  p_student_id uuid,
  p_exclude   uuid default null
) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  r        public.rules;
  v_start  timestamptz;
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

  select coalesce(max(b.boundary_at), now() - interval '30 days')
    into v_start
    from public.boundaries b
   where b.boundary_at <= now()
     and b.type in ('week', 'rule_update', 'month');

  if p_student_id is null then
    raise exception '规则上限需要指定被登记的学生';
  end if;

  v_delta := case when r.score_type = '扣分' then abs(p_points) else p_points end;

  select count(*),
         coalesce(sum(case when r.score_type = '扣分' then abs(rc.points) else rc.points end), 0)
    into v_cnt, v_used
    from public.records rc
   where rc.rule_id = p_rule_id
     and rc.student_id = p_student_id
     and rc.status = '正常'
     and rc.created_at >= v_start
     and (p_exclude is null or rc.id <> p_exclude);

  if r.limit_type = 'count' then
    if v_cnt + 1 > r.limit_value then
      raise exception '规则「%」每位学生本周期最多登记 % 次（该生已登记 % 次），已达上限', r.reason, r.limit_value::int, v_cnt;
    end if;
  else
    if v_used + v_delta > r.limit_value then
      raise exception '规则「%」每位学生本周期分值上限 %（该生已用 %，本次 %），将超限', r.reason, r.limit_value, v_used, v_delta;
    end if;
  end if;
end;
$$;

-- 3) 重建调用方（传入学生 id）
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

  perform public.check_rule_limit(p_rule_id, p_points, p_student_id, null);

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
  v_old  public.records;
  v_new  public.records;
  v_date date;
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

  perform public.check_rule_limit(v_old.rule_id, p_points, v_old.student_id, v_old.id);

  update public.records
     set reason      = coalesce(p_reason, reason),
         points      = p_points,
         evidence    = coalesce(p_evidence, evidence),
         record_date = v_date::text,
         period_key  = to_char(v_date, 'YYYY-MM'),
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

-- 4) 授权：内部函数不对前端开放，仅由 security definer 函数调用
revoke all on function public.check_rule_limit(uuid, numeric, uuid, uuid) from public, anon, authenticated;

-- 5) 自检
select 'patch_v2.0.18_check' as check,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='check_rule_limit') as overloads,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='check_rule_limit'
           and pg_get_function_arguments(p.oid) like '%p_student_id%') as has_student_arg;
