-- ============================================================
-- 62_ops_v209.sql  V2.0.9 需求批
--   1) 数据管理：积分明细导入（兼容 V1.6）、星光台账替换/补充导入、各类导出
--   2) 仓库管理：按小组 / 按个人查看学生仓库并批量标记卡片
--   3) 星光台账表格像 Excel 一样直接改数值（按差额生成调整流水）
-- 说明：建号强制改密、设置页改密码、执行小组手动汇总 直接改在 54_accounts.sql / 57_admin_ops.sql 内，
--       不在本模块重复定义（check_sql 禁止同一签名多处定义）。
-- 全部函数幂等（create or replace + drop 旧签名），安全定义者 + 固定 search_path。
-- ============================================================

-- ------------------------------------------------------------
-- 6.4 数据管理：积分明细导入（兼容 V1.6）
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 6.5 数据管理：星光台账 替换导入 / 补充导入
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 6.6 数据管理：导出（积分明细 / 星光流水 / 周月汇总）
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 6.7 星光台账表格：像 Excel 一样直接改数值（按差额生成调整流水）
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 6.8 仓库管理：按小组 / 按个人查看并批量标记
-- ------------------------------------------------------------
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
      -- 已使用 / 已过期 / 已即时生效（星光类、文本类）的卡片不能被作废
      if v_status = 'void' and v_draw.status <> 'unused' then
        raise exception '只有「未使用」的卡片可以作废（当前状态：%），已使用/已过期/已生效的卡片不能作废',
          case v_draw.status
            when 'used' then '已使用' when 'expired' then '已过期'
            when 'posted' then '已即时生效' when 'void' then '已作废' else v_draw.status end;
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
        if v_status = 'expired' and v_draw.status not in ('unused','expired') then
          raise exception '只有「未使用」的卡片可以置为已过期（当前状态：%）', v_draw.status;
        end if;
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
