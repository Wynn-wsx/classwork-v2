-- ============================================================
-- 5.5 通知 / 申诉 / 监督委员 / 星光台账 RPC
--     约定：全部 security definer + search_path = public, extensions；
--           权限判断只用 public.caller_role() / public.require_role()；
--           写操作留痕 public.write_audit()，通知用 public.notify() /
--           public.notify_audience()。
-- ============================================================

-- ------------------------------------------------------------
-- 5.5.1 通知信箱
-- ------------------------------------------------------------

-- 标记单条通知已读：只能操作 recipient_id = 自己 的行
create or replace function public.mark_notification_read(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_n int := 0;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder','student'],
    '没有权限执行此操作'
  );
  if p_id is null then
    raise exception '通知编号不能为空';
  end if;
  update public.notifications
     set is_read = true,
         read_at = coalesce(read_at, now())
   where id = p_id
     and recipient_id = auth.uid();
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception '通知不存在或无权操作';
  end if;
end;
$$;
revoke all on function public.mark_notification_read(uuid) from public, anon, authenticated;
grant execute on function public.mark_notification_read(uuid) to authenticated;

-- 一键全部已读：返回本次置为已读的条数
create or replace function public.mark_all_notifications_read()
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_n int := 0;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder','student'],
    '没有权限执行此操作'
  );
  update public.notifications
     set is_read = true,
         read_at = now()
   where recipient_id = auth.uid()
     and is_read = false;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function public.mark_all_notifications_read() from public, anon, authenticated;
grant execute on function public.mark_all_notifications_read() to authenticated;

-- D8 发布班级广播（super_admin/admin）：发给全部 active 账号
create or replace function public.admin_publish_broadcast(
  p_title    text,
  p_body     text,
  p_category text default 'broadcast'
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_sent int := 0;
  v_cat  text;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  if p_title is null or btrim(p_title) = '' then
    raise exception '请填写广播标题';
  end if;
  v_cat := coalesce(nullif(btrim(coalesce(p_category,'')), ''), 'broadcast');
  v_sent := public.notify_audience('all', btrim(p_title), coalesce(p_body,''), v_cat);
  perform public.write_audit(
    '发布班级广播',
    'notification',
    '',
    jsonb_build_object('title', p_title, 'category', v_cat, 'sent', v_sent)
  );
  return jsonb_build_object('sent', v_sent);
end;
$$;
revoke all on function public.admin_publish_broadcast(text, text, text) from public, anon, authenticated;
grant execute on function public.admin_publish_broadcast(text, text, text) to authenticated;

-- D9 删除（撤回）通知（super_admin/admin）：物理删除
create or replace function public.admin_delete_notification(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_title text;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  if p_id is null then
    raise exception '通知编号不能为空';
  end if;
  delete from public.notifications
   where id = p_id
  returning title into v_title;
  if not found then
    raise exception '通知不存在或已被删除';
  end if;
  perform public.write_audit(
    '删除通知',
    'notification',
    p_id::text,
    jsonb_build_object('title', v_title)
  );
end;
$$;
revoke all on function public.admin_delete_notification(uuid) from public, anon, authenticated;
grant execute on function public.admin_delete_notification(uuid) to authenticated;

-- ------------------------------------------------------------
-- 5.5.2 监督委员当周指派（D15）
-- ------------------------------------------------------------

-- 指派当周监督委员：每周最多 2 名（只统计未撤销的指派）
create or replace function public.admin_assign_supervisor(p_period_key text, p_student_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_period   text;
  v_ids      uuid[];
  v_existing int := 0;
  v_total    int := 0;
  v_found    int := 0;
  v_names    text;
  v_max      int;
  v_p        record;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  v_period := coalesce(
    nullif(btrim(coalesce(p_period_key, '')), ''),
    public.current_week_key()
  );
  if p_student_ids is null or cardinality(p_student_ids) = 0 then
    raise exception '请至少选择一名学生';
  end if;
  select array_agg(distinct x) into v_ids
    from unnest(p_student_ids) as x
   where x is not null;
  if v_ids is null or cardinality(v_ids) = 0 then
    raise exception '请至少选择一名学生';
  end if;
  select count(*) into v_found from public.students where id = any(v_ids);
  if v_found <> cardinality(v_ids) then
    raise exception '部分学生不存在，请刷新名单后重试';
  end if;
  -- 本周已指派且不在本次名单中的未撤销人数
  select count(*) into v_existing
    from public.supervisor_assignments sa
   where sa.period_key = v_period
     and sa.revoked_at is null
     and not (sa.student_id = any(v_ids));
  v_total := v_existing + cardinality(v_ids);
  v_max := greatest(coalesce((public.cfg()->>'max_supervisors')::int, 2), 1);
  if v_total > v_max then
    raise exception '每周最多指派 % 名监督委员（本周已有 % 名未被撤销）', v_max, v_existing;
  end if;

  insert into public.supervisor_assignments (period_key, student_id, assigned_by)
  select v_period, x, auth.uid()
    from unnest(v_ids) as x
  on conflict (period_key, student_id) do update
     set revoked_at  = null,
         assigned_by = excluded.assigned_by;

  select string_agg(s.name, '、' order by s.name) into v_names
    from public.students s
   where s.id = any(v_ids);

  -- 通知被指派的学生本人
  for v_p in
    select p.id
      from public.profiles p
     where p.student_id = any(v_ids)
       and p.status = 'active'
  loop
    perform public.notify(
      v_p.id,
      '监督委员任命',
      format('你已被指派为 %s 周的监督委员，请协助受理本周积分申诉。', v_period),
      'system',
      'supervisor_assignment',
      null
    );
  end loop;
  -- 全班公示
  perform public.notify_audience(
    'all',
    '本周监督委员名单',
    format('本周（%s）监督委员：%s。', v_period, coalesce(v_names, '')),
    'broadcast',
    'supervisor_assignment',
    null
  );

  perform public.write_audit(
    '指派监督委员',
    'supervisor_assignment',
    v_period,
    jsonb_build_object(
      'period_key', v_period,
      'student_ids', to_jsonb(v_ids),
      'names', v_names,
      'active_count', v_total
    )
  );
  return jsonb_build_object(
    'period_key',   v_period,
    'assigned',     cardinality(v_ids),
    'active_count', v_total,
    'student_ids',  to_jsonb(v_ids)
  );
end;
$$;
revoke all on function public.admin_assign_supervisor(text, uuid[]) from public, anon, authenticated;
grant execute on function public.admin_assign_supervisor(text, uuid[]) to authenticated;

-- 撤销一条监督委员指派（置 revoked_at）
create or replace function public.admin_revoke_supervisor(p_id uuid)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_student uuid;
begin
  perform public.require_role(array['super_admin','admin'], '没有权限执行此操作');
  if p_id is null then
    raise exception '指派记录编号不能为空';
  end if;
  update public.supervisor_assignments
     set revoked_at = now()
   where id = p_id
     and revoked_at is null
  returning student_id into v_student;
  if not found then
    raise exception '指派记录不存在或已撤销';
  end if;
  perform public.write_audit(
    '撤销监督委员',
    'supervisor_assignment',
    p_id::text,
    jsonb_build_object('student_id', v_student)
  );
end;
$$;
revoke all on function public.admin_revoke_supervisor(uuid) from public, anon, authenticated;
grant execute on function public.admin_revoke_supervisor(uuid) to authenticated;

-- 监督委员名单（所有已激活账号可读；默认当前周）
create or replace function public.list_supervisors(p_period_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_period text;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder','student'],
    '没有权限执行此操作'
  );
  v_period := coalesce(
    nullif(btrim(coalesce(p_period_key, '')), ''),
    public.current_week_key()
  );
  return coalesce((
    select jsonb_agg(
             jsonb_build_object(
               'id',           sa.id,
               'student_id',   sa.student_id,
               'student_name', s.name,
               'group_name',   s.group_name,
               'period_key',   sa.period_key,
               'assigned_at',  sa.created_at,
               'revoked_at',   sa.revoked_at
             )
             order by sa.created_at, s.name
           )
      from public.supervisor_assignments sa
      left join public.students s on s.id = sa.student_id
     where sa.period_key = v_period
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.list_supervisors(text) from public, anon, authenticated;
grant execute on function public.list_supervisors(text) to authenticated;

-- ------------------------------------------------------------
-- 5.5.3 星光值台账（D12 / D13 / D14，3.9）
-- ------------------------------------------------------------

-- 星光台账查询（公示范围按 app_config.starlight_visibility 裁剪）
--   public    ：全部已激活账号可看全班
--   self_only ：学生只看自己，老师看全班；记录员始终只看本组
create or replace function public.starlight_list(p_scope text default 'all', p_limit int default 200)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text;
  v_vis   text;
  v_scope text;
  v_limit int;
  v_me    uuid;
  v_group text;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder','student'],
    '没有权限执行此操作'
  );
  v_role  := public.caller_role();
  v_vis   := coalesce(public.cfg()->>'starlight_visibility', 'public');
  v_scope := lower(btrim(coalesce(p_scope, 'all')));
  if v_scope not in ('all','me','group') then
    raise exception '查询范围参数无效';
  end if;
  v_limit := greatest(1, least(coalesce(p_limit, 200), 1000));
  v_me    := public.my_student_id();
  v_group := coalesce(public.student_group(v_me), public.my_group_name());

  if v_role = 'student' then
    if v_vis = 'self_only' then
      v_scope := 'me';
    end if;
  elsif v_role = 'group_recorder' then
    v_scope := 'group';
  elsif v_role in ('super_admin','admin','executive') then
    if v_scope <> 'me' then
      v_scope := 'all';
    end if;
  end if;

  return (
    with base as (
      select s.id as student_id,
             s.name,
             s.group_name,
             coalesce(a.balance, 0) as balance,
             rank() over (order by coalesce(a.balance, 0) desc, s.name) as rnk
        from public.students s
        left join public.starlight_accounts a on a.student_id = s.id
    ),
    acc as (
      select b.* from base b
       where (v_scope = 'all')
          or (v_scope = 'me' and b.student_id = v_me)
          or (v_scope = 'group' and v_group is not null and b.group_name = v_group)
    ),
    lg as (
      select l.change_amount,
             l.source,
             l.note,
             l.created_at,
             l.period_key,
             s.name as student_name
        from public.starlight_logs l
        join public.students s on s.id = l.student_id
       where (v_scope = 'all')
          or (v_scope = 'me' and l.student_id = v_me)
          or (v_scope = 'group' and v_group is not null and s.group_name = v_group)
       order by l.created_at desc, l.id desc
       limit v_limit
    )
    select jsonb_build_object(
      'accounts', coalesce((
        select jsonb_agg(
                 jsonb_build_object(
                   'student_id', a.student_id,
                   'name',       a.name,
                   'group_name', a.group_name,
                   'balance',    a.balance,
                   'rank',       case when v_scope = 'all' then a.rnk else null end
                 )
                 order by a.balance desc, a.name
               )
          from acc a
      ), '[]'::jsonb),
      'logs', coalesce((
        select jsonb_agg(
                 jsonb_build_object(
                   'student_name',  g.student_name,
                   'change_amount', g.change_amount,
                   'source',        g.source,
                   'note',          g.note,
                   'created_at',    g.created_at,
                   'period_key',    g.period_key
                 )
                 order by g.created_at desc
               )
          from lg g
      ), '[]'::jsonb)
    )
  );
end;
$$;
revoke all on function public.starlight_list(text, int) from public, anon, authenticated;
grant execute on function public.starlight_list(text, int) to authenticated;

-- D13 人工调整星光值（super_admin/admin/executive），强制留痕
create or replace function public.starlight_adjust(p_student_id uuid, p_amount int, p_note text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_note    text;
  v_balance int;
begin
  perform public.require_role(array['super_admin','admin','executive'], '没有权限执行此操作');
  if p_student_id is null then
    raise exception '请选择学生';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception '调整数量不能为 0';
  end if;
  v_note := btrim(coalesce(p_note, ''));
  if v_note = '' then
    raise exception '请填写调整说明';
  end if;
  if not exists (select 1 from public.students s where s.id = p_student_id) then
    raise exception '学生不存在';
  end if;

  insert into public.starlight_accounts (student_id, balance, updated_at)
  values (p_student_id, p_amount, now())
  on conflict (student_id) do update
     set balance    = starlight_accounts.balance + excluded.balance,
         updated_at = now()
  returning balance into v_balance;

  insert into public.starlight_logs
    (student_id, change_amount, source, period_key, note, operator_id)
  values
    (p_student_id, p_amount, 'manual', public.current_month_key(), v_note, auth.uid());

  perform public.write_audit(
    '调整星光值',
    'starlight_account',
    p_student_id::text,
    jsonb_build_object(
      'change_amount', p_amount,
      'note',          v_note,
      'balance',       v_balance
    )
  );
  return jsonb_build_object(
    'student_id',    p_student_id,
    'change_amount', p_amount,
    'balance',       v_balance
  );
end;
$$;
revoke all on function public.starlight_adjust(uuid, int, text) from public, anon, authenticated;
grant execute on function public.starlight_adjust(uuid, int, text) to authenticated;

-- D14 学期星光清零（仅 super_admin）：先快照、再写清零流水、最后清零
--   注意：本系统不设学期分隔点，清零为纯手动操作，不产生周期边界。
create or replace function public.term_reset_starlight(p_term_name text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_term       text;
  v_summary    jsonb;
  v_snapshot   uuid;
  v_reset      int := 0;
  v_cfg_rows   int := 0;
begin
  perform public.require_role(array['super_admin'], '没有权限执行此操作');
  v_term := coalesce(
    nullif(btrim(coalesce(p_term_name, '')), ''),
    nullif(public.cfg()->>'term_name', ''),
    '本学期'
  );

  -- 1) 先写学期快照：每人余额 + 流水合计
  select jsonb_build_object(
           'term_name', v_term,
           'accounts', coalesce((
             select jsonb_agg(
                      jsonb_build_object(
                        'student_id',   s.id,
                        'student_name', s.name,
                        'group_name',   s.group_name,
                        'balance',      coalesce(a.balance, 0)
                      )
                      order by s.name
                    )
               from public.students s
               left join public.starlight_accounts a on a.student_id = s.id
           ), '[]'::jsonb),
           'total_balance',  coalesce((select sum(balance) from public.starlight_accounts), 0),
           'total_positive', coalesce((select sum(change_amount) from public.starlight_logs where change_amount > 0), 0),
           'total_negative', coalesce((select sum(change_amount) from public.starlight_logs where change_amount < 0), 0),
           'log_count',      (select count(*) from public.starlight_logs)
         )
    into v_summary;
  insert into public.starlight_term_snapshots (term_name, operator_id, summary)
  values (v_term, auth.uid(), v_summary)
  returning id into v_snapshot;

  -- 2) 对非零余额写 term_reset 负数流水
  insert into public.starlight_logs
    (student_id, change_amount, source, period_key, note, operator_id)
  select a.student_id,
         -a.balance,
         'term_reset',
         public.current_month_key(),
         '学期星光清零（' || v_term || '）',
         auth.uid()
    from public.starlight_accounts a
   where a.balance <> 0;
  get diagnostics v_reset = row_count;

  -- 3) 清零余额
  update public.starlight_accounts
     set balance = 0,
         updated_at = now()
   where balance <> 0;

  -- 4) 记录学期名（单行配置保留 id = 1）
  update public.app_config
     set term_name  = v_term,
         updated_at = now(),
         updated_by = auth.uid()
   where id = 1;
  get diagnostics v_cfg_rows = row_count;
  if v_cfg_rows = 0 then
    insert into public.app_config (id, term_name, updated_at, updated_by)
    values (1, v_term, now(), auth.uid());
  end if;

  perform public.write_audit(
    '学期星光清零',
    'starlight_term_snapshot',
    v_snapshot::text,
    jsonb_build_object(
      'term_name',   v_term,
      'reset_count', v_reset,
      'snapshot_id', v_snapshot
    )
  );
  return jsonb_build_object(
    'term_name',   v_term,
    'reset_count', v_reset,
    'snapshot_id', v_snapshot
  );
end;
$$;
revoke all on function public.term_reset_starlight(text) from public, anon, authenticated;
grant execute on function public.term_reset_starlight(text) to authenticated;
