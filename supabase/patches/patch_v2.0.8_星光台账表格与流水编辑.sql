-- ============================================================
-- V2.0.8 增量补丁（幂等，可在 Supabase SQL Editor 直接执行）
-- 适用：已经部署过 V2.0.0–V2.0.7 的项目
--
-- 本补丁做一件事：星光台账增加「表格预览」与「历史流水快速编辑」能力
--   1) starlight_table       表格预览：每人当前星光 / 所选月份变动 / 流水条数 / 最近一次变动
--   2) starlight_logs        某学生的历史星光流水（含是否可编辑）
--   3) starlight_insert_log  补录一条历史星光流水（可指定过去时间，用于补录漏记）
--   4) starlight_edit_log    修改历史流水的金额 / 说明 / 时间，自动重算余额
--   5) starlight_delete_log  删除误录流水，自动重算余额
--   6) _recalc_starlight     内部函数：按流水重算余额（不对前端授权）
--
-- 说明：不新增表、不改表结构；星光与积分两套账本完全独立。
-- 执行完请再执行：notify pgrst, 'reload schema';
-- ============================================================


-- ------------------------------------------------------------
-- 1. 星光台账函数（6 个，全部幂等：create or replace）
-- ------------------------------------------------------------

-- _recalc_starlight
create or replace function public._recalc_starlight(p_student_id uuid)
returns int
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_balance int;
begin
  select coalesce(sum(l.change_amount), 0)::int into v_balance
    from public.starlight_logs l
   where l.student_id = p_student_id;

  insert into public.starlight_accounts (student_id, balance, updated_at)
  values (p_student_id, v_balance, now())
  on conflict (student_id) do update
     set balance = excluded.balance,
         updated_at = now();

  return v_balance;
end;
$$;
revoke all on function public._recalc_starlight(uuid) from public, anon, authenticated;

-- starlight_table
create or replace function public.starlight_table(p_month_key text default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text;
  v_month text;
  v_group text;
  v_out   jsonb;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder'],
    '没有权限查看星光台账'
  );
  v_role  := public.caller_role();
  v_month := coalesce(nullif(btrim(coalesce(p_month_key, '')), ''), public.current_month_key());
  if v_month !~ '^\d{4}-\d{2}$' then
    raise exception '月份格式应为 YYYY-MM';
  end if;
  v_group := case when v_role = 'group_recorder' then public.my_group_name() else null end;

  with base as (
    select s.id, s.name, s.group_name,
           coalesce(a.balance, 0) as balance,
           coalesce(mc.month_change, 0) as month_change,
           coalesce(lc.log_count, 0) as log_count,
           lc.last_at as last_at,
           lc.last_note as last_note
      from public.students s
      left join public.starlight_accounts a on a.student_id = s.id
      left join (
        select l.student_id, sum(l.change_amount)::int as month_change
          from public.starlight_logs l
         where to_char(l.created_at at time zone 'Asia/Shanghai', 'YYYY-MM') = v_month
         group by l.student_id
      ) mc on mc.student_id = s.id
      left join (
        select l.student_id, count(*)::int as log_count,
               max(l.created_at) as last_at,
               (array_agg(l.note order by l.created_at desc))[1] as last_note
          from public.starlight_logs l
         group by l.student_id
      ) lc on lc.student_id = s.id
     where (v_group is null or s.group_name = v_group)
     order by coalesce(a.balance, 0) desc, s.name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'student_id',  id,
           'name',        name,
           'group_name',  group_name,
           'balance',     balance,
           'month_change', month_change,
           'log_count',   log_count,
           'last_at',     last_at,
           'last_note',   last_note
         ) order by balance desc, name), '[]'::jsonb)
    into v_out
    from base;

  return jsonb_build_object(
    'month_key', v_month,
    'scope',     case when v_group is null then 'all' else 'group' end,
    'items',     v_out
  );
end;
$$;
revoke all on function public.starlight_table(text) from public, anon, authenticated;
grant execute on function public.starlight_table(text) to authenticated;

-- starlight_logs
create or replace function public.starlight_logs(p_student_id uuid, p_limit int default 200)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role  text;
  v_group text;
  v_limit int;
  v_out   jsonb;
begin
  perform public.require_role(
    array['super_admin','admin','executive','group_recorder'],
    '没有权限查看星光流水'
  );
  if p_student_id is null then
    raise exception '请选择学生';
  end if;
  v_role  := public.caller_role();
  v_group := public.student_group(p_student_id);
  if v_role = 'group_recorder' and v_group is distinct from public.my_group_name() then
    raise exception '记录员只能查看本组学生的星光流水';
  end if;
  v_limit := greatest(1, least(coalesce(p_limit, 200), 500));

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            x.id,
           'student_id',    x.student_id,
           'change_amount', x.change_amount,
           'source',        x.source,
           'note',          x.note,
           'period_key',    x.period_key,
           'created_at',    x.created_at,
           'editable',      (x.source <> 'term_reset'),
           'operator_name', x.operator_name
         ) order by x.created_at desc, x.id desc), '[]'::jsonb)
    into v_out
    from (
      select l.*, p.name as operator_name
        from public.starlight_logs l
        left join public.profiles p on p.id = l.operator_id
       where l.student_id = p_student_id
       order by l.created_at desc, l.id desc
       limit v_limit
    ) x;

  return jsonb_build_object(
    'student_id', p_student_id,
    'balance',    public._recalc_starlight(p_student_id),
    'items',      v_out
  );
end;
$$;
revoke all on function public.starlight_logs(uuid, int) from public, anon, authenticated;
grant execute on function public.starlight_logs(uuid, int) to authenticated;

-- starlight_insert_log
create or replace function public.starlight_insert_log(
  p_student_id uuid,
  p_change_amount int,
  p_note text,
  p_created_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_note    text;
  v_at      timestamptz;
  v_log     public.starlight_logs;
  v_balance int;
begin
  perform public.require_role(array['super_admin','admin','executive'], '没有权限补录星光流水');
  if p_student_id is null then
    raise exception '请选择学生';
  end if;
  if p_change_amount is null or p_change_amount = 0 then
    raise exception '变动数量不能为 0';
  end if;
  if not exists (select 1 from public.students s where s.id = p_student_id) then
    raise exception '学生不存在';
  end if;
  v_note := btrim(coalesce(p_note, ''));
  if v_note = '' then
    raise exception '请填写说明';
  end if;
  v_at := coalesce(p_created_at, now());
  if v_at > now() + interval '1 minute' then
    raise exception '变动时间不能晚于当前时间';
  end if;

  insert into public.starlight_logs
    (student_id, change_amount, source, period_key, note, operator_id, created_at)
  values
    (p_student_id, p_change_amount, 'manual',
     to_char(v_at at time zone 'Asia/Shanghai', 'YYYY-MM'), v_note, auth.uid(), v_at)
  returning * into v_log;

  v_balance := public._recalc_starlight(p_student_id);

  perform public.write_audit(
    '补录星光流水',
    'starlight_log',
    v_log.id::text,
    jsonb_build_object('student_id', p_student_id, 'change_amount', p_change_amount,
                       'note', v_note, 'created_at', v_at, 'balance', v_balance)
  );

  return jsonb_build_object('log', to_jsonb(v_log), 'balance', v_balance);
end;
$$;
revoke all on function public.starlight_insert_log(uuid, int, text, timestamptz) from public, anon, authenticated;
grant execute on function public.starlight_insert_log(uuid, int, text, timestamptz) to authenticated;

-- starlight_edit_log
create or replace function public.starlight_edit_log(
  p_log_id uuid,
  p_change_amount int default null,
  p_note text default null,
  p_created_at timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_old     public.starlight_logs;
  v_log     public.starlight_logs;
  v_balance int;
  v_amount  int;
  v_note    text;
  v_at      timestamptz;
begin
  perform public.require_role(array['super_admin','admin','executive'], '没有权限修改星光流水');
  if p_log_id is null then
    raise exception '请选择要修改的星光流水';
  end if;
  select * into v_old from public.starlight_logs where id = p_log_id;
  if v_old.id is null then
    raise exception '星光流水不存在';
  end if;
  if v_old.source = 'term_reset' then
    raise exception '学期清零流水不允许修改';
  end if;

  v_amount := coalesce(p_change_amount, v_old.change_amount);
  if v_amount = 0 then
    raise exception '变动数量不能为 0（如需删除请使用「删除」）';
  end if;
  v_note := coalesce(nullif(btrim(coalesce(p_note, '')), ''), v_old.note);
  v_at   := coalesce(p_created_at, v_old.created_at);
  if v_at > now() + interval '1 minute' then
    raise exception '变动时间不能晚于当前时间';
  end if;

  update public.starlight_logs l
     set change_amount = v_amount,
         note          = v_note,
         created_at    = v_at,
         period_key    = to_char(v_at at time zone 'Asia/Shanghai', 'YYYY-MM')
   where l.id = p_log_id
   returning * into v_log;

  v_balance := public._recalc_starlight(v_log.student_id);

  perform public.write_audit(
    '编辑星光流水',
    'starlight_log',
    p_log_id::text,
    jsonb_build_object(
      'student_id',   v_log.student_id,
      'before',       jsonb_build_object('change_amount', v_old.change_amount,
                                         'note', v_old.note, 'created_at', v_old.created_at),
      'after',        jsonb_build_object('change_amount', v_log.change_amount,
                                         'note', v_log.note, 'created_at', v_log.created_at),
      'balance',      v_balance
    )
  );

  return jsonb_build_object('log', to_jsonb(v_log), 'balance', v_balance);
end;
$$;
revoke all on function public.starlight_edit_log(uuid, int, text, timestamptz) from public, anon, authenticated;
grant execute on function public.starlight_edit_log(uuid, int, text, timestamptz) to authenticated;

-- starlight_delete_log
create or replace function public.starlight_delete_log(p_log_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_old     public.starlight_logs;
  v_balance int;
begin
  perform public.require_role(array['super_admin','admin','executive'], '没有权限删除星光流水');
  select * into v_old from public.starlight_logs where id = p_log_id;
  if v_old.id is null then
    raise exception '星光流水不存在';
  end if;
  if v_old.source = 'term_reset' then
    raise exception '学期清零流水不允许删除';
  end if;

  delete from public.starlight_logs where id = p_log_id;
  v_balance := public._recalc_starlight(v_old.student_id);

  perform public.write_audit(
    '删除星光流水',
    'starlight_log',
    p_log_id::text,
    jsonb_build_object('student_id', v_old.student_id, 'change_amount', v_old.change_amount,
                       'note', v_old.note, 'created_at', v_old.created_at, 'balance', v_balance)
  );

  return jsonb_build_object('deleted', p_log_id, 'student_id', v_old.student_id, 'balance', v_balance);
end;
$$;
revoke all on function public.starlight_delete_log(uuid) from public, anon, authenticated;
grant execute on function public.starlight_delete_log(uuid) to authenticated;


-- ------------------------------------------------------------
-- 2. 自检
-- ------------------------------------------------------------
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('_recalc_starlight','starlight_table','starlight_logs',
                        'starlight_insert_log','starlight_edit_log','starlight_delete_log')) as 星光台账函数数_应为6,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'starlight_edit_log'
      and pg_get_function_arguments(p.oid) like '%p_created_at%') as 编辑函数含发生时间参数_应为1,
  (select public.current_month_key()) as 当前月;
