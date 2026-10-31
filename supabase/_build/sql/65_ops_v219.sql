-- ============================================================
-- 8.5 V2.0.19 周期定义（周 / 月起止日期 + 规则计分周）
--    设计：开发文件/docs/周期定义改造方案_V2.0.17.md
--    · 周：直接设置起止日期（可跨自然月），相邻周首尾相接
--    · 月：两段式——先设起始（进行中，结束日期为空），再设结束；
--          结束日+1 自动成为下月起始日；月起止必须落在周边界上
--    · 规则计分周：该周按 N 个规则计分周计算（上限 ×N）
--    · period_key = 起始日期（如 2026-10-26），周期结束不改变键
-- ============================================================

-- ------------------------------------------------------------
-- 8.5.0 日期中文/ISO 显示辅助
-- ------------------------------------------------------------
create or replace function public.fmt_cn_date(p_date date)
returns text
language sql immutable security definer set search_path = public, extensions as $$
  select case when p_date is null then '—' else to_char(p_date, 'YYYY-MM-DD') end;
$$;

-- ------------------------------------------------------------
-- 8.5.1 周期一致性检查：返回 {ok, issues:[{level,type,detail,start_date}]}
-- ------------------------------------------------------------
create or replace function public.admin_validate_periods()
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_issues jsonb := '[]'::jsonb;
  v_w      record;
  v_m      record;
  v_prev   date;
begin
  if public.caller_role() not in ('system', 'super_admin', 'admin', 'executive') then
    raise exception '没有权限检查周期定义';
  end if;

  -- 周：时间递进 + 首尾相接
  v_prev := null;
  for v_w in
    select b.* from public.boundaries b
     where b.type = 'week' and b.deprecated = false and b.start_date is not null
     order by b.start_date
  loop
    if v_w.end_date is null then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'week',
        'start_date', v_w.start_date, 'detail', '周周期缺少结束日期');
    elsif v_w.end_date < v_w.start_date then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'week',
        'start_date', v_w.start_date, 'detail', '结束日期早于起始日期');
    end if;
    if v_prev is not null and v_w.start_date <> v_prev + 1 then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'week',
        'start_date', v_w.start_date, 'detail',
        format('与前一周不连续：上一周结束于 %s，本周开始于 %s', v_prev, v_w.start_date));
    end if;
    v_prev := v_w.end_date;
  end loop;

  -- 月：起止必须落在周边界
  for v_m in
    select b.* from public.boundaries b
     where b.type = 'month' and b.deprecated = false and b.start_date is not null
     order by b.start_date
  loop
    if not exists (select 1 from public.boundaries w
                    where w.type = 'week' and w.deprecated = false and w.start_date = v_m.start_date) then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'month',
        'start_date', v_m.start_date, 'detail', '月起始日不在任何周周期的起始日上');
    end if;
    if v_m.end_date is not null and not exists (
         select 1 from public.boundaries w
          where w.type = 'week' and w.deprecated = false and w.start_date = v_m.end_date + 1) then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'month',
        'start_date', v_m.start_date, 'detail', '月结束日的下一天不是任何周周期的起始日');
    end if;
    if v_m.end_date is not null and v_m.end_date < v_m.start_date then
      v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'month',
        'start_date', v_m.start_date, 'detail', '月结束日期早于起始日期');
    end if;
  end loop;

  -- 月之间：只能有一个进行中，且相邻月必须首尾相接
  if (select count(*) from public.boundaries
       where type = 'month' and deprecated = false and end_date is null) > 1 then
    v_issues := v_issues || jsonb_build_object('level', 'error', 'type', 'month',
      'detail', '存在多个「进行中」的月周期，最多只能有一个');
  end if;
  for v_m in
    select b.*, lag(b.end_date) over (order by b.start_date) as prev_end
      from public.boundaries b
     where b.type = 'month' and b.deprecated = false and b.start_date is not null
  loop
    if v_m.prev_end is not null and v_m.start_date <> v_m.prev_end + 1 then
      v_issues := v_issues || jsonb_build_object('level', 'warn', 'type', 'month',
        'start_date', v_m.start_date, 'detail',
        format('与上一个月不连续：上一月结束于 %s，本月开始于 %s', v_m.prev_end, v_m.start_date));
    end if;
  end loop;

  return jsonb_build_object(
    'ok', jsonb_array_length(v_issues) = 0,
    'issue_count', jsonb_array_length(v_issues),
    'issues', v_issues
  );
end;
$$;

-- ------------------------------------------------------------
-- 8.5.2 设置/修改周期
--   p_type: week | month
--   p_start: 起始日期（周一或任意，但月必须是某个周的起始日）
--   p_end:   结束日期（含当天）；week 必填，month 可为空 = 进行中
--   p_rule_weeks: 该周按几个「规则计分周」算（1~4，默认 1）
-- ------------------------------------------------------------
create or replace function public.admin_set_period(
  p_type text,
  p_start date,
  p_end date default null,
  p_rule_weeks int default 1
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role   text := public.caller_role();
  v_id     uuid;
  v_b      public.boundaries;
  v_prev   public.boundaries;
  v_next   public.boundaries;
  v_pk     text;
  v_at     timestamptz;
  v_weeks  int := coalesce(p_rule_weeks, 1);
  v_new    public.boundaries;
begin
  if v_role not in ('system', 'super_admin') then
    raise exception '只有管理员可以修改周期定义';
  end if;
  if p_type not in ('week', 'month') then
    raise exception '周期类型只能是 week 或 month';
  end if;
  if p_start is null then
    raise exception '请选择起始日期';
  end if;
  if v_weeks < 1 or v_weeks > 4 then
    raise exception '规则计分周只能是 1~4';
  end if;

  if p_type = 'week' then
    if p_end is null then
      raise exception '周周期需要填写结束日期';
    end if;
    if p_end < p_start then
      raise exception '结束日期不能早于起始日期';
    end if;
    if (p_end - p_start) > 27 then
      raise exception '一周最多 28 天，请检查日期';
    end if;
    v_prev := (select b from public.boundaries b
                where b.type = 'week' and b.deprecated = false and b.end_date is not null
                  and b.end_date < p_start
                order by b.end_date desc limit 1);
    if v_prev.id is not null and v_prev.end_date + 1 <> p_start then
      raise exception '与前一周不连续：上一周结束于 %，本周应从 % 开始',
        public.fmt_cn_date(v_prev.end_date), public.fmt_cn_date(v_prev.end_date + 1);
    end if;
    v_next := (select b from public.boundaries b
                where b.type = 'week' and b.deprecated = false
                  and b.start_date > p_start
                order by b.start_date limit 1);
    if v_next.id is not null and v_next.start_date - 1 <> p_end then
      raise exception '与后一周重叠或留空：下一周开始于 %，本周应结束于 %',
        public.fmt_cn_date(v_next.start_date), public.fmt_cn_date(v_next.start_date - 1);
    end if;
  else
    -- 月：起止必须落在周边界上
    if not exists (select 1 from public.boundaries w
                    where w.type = 'week' and w.deprecated = false and w.start_date = p_start) then
      raise exception '月起始日必须是某个周周期的第一天（当前不是），请先设置对应的周';
    end if;
    if p_end is not null then
      if p_end < p_start then
        raise exception '结束日期不能早于起始日期';
      end if;
      if not exists (select 1 from public.boundaries w
                      where w.type = 'week' and w.deprecated = false and w.start_date = p_end + 1) then
        raise exception '月结束日的下一天必须是某个周周期的第一天，请把结束日设为该周的周日';
      end if;
    end if;
    v_prev := (select b from public.boundaries b
                where b.type = 'month' and b.deprecated = false and b.start_date < p_start
                order by b.start_date desc limit 1);
    if v_prev.id is not null then
      if v_prev.end_date is null then
        if p_end is not null then
          raise exception '上一个月（% 起）还在进行中，请先为它设置结束日期',
            public.fmt_cn_date(v_prev.start_date);
        else
          raise exception '已有一个进行中的月周期（% 起），不能再开新的',
            public.fmt_cn_date(v_prev.start_date);
        end if;
      elsif v_prev.end_date + 1 <> p_start then
        raise exception '与上一个月不连续：上一月结束于 %，本月应从 % 开始',
          public.fmt_cn_date(v_prev.end_date), public.fmt_cn_date(v_prev.end_date + 1);
      end if;
    end if;
    v_next := (select b from public.boundaries b
                where b.type = 'month' and b.deprecated = false and b.start_date > p_start
                order by b.start_date limit 1);
    if v_next.id is not null and p_end is not null and v_next.start_date <> p_end + 1 then
      raise exception '与下一个月重叠或留空：下一月开始于 %，本月应结束于 %',
        public.fmt_cn_date(v_next.start_date), public.fmt_cn_date(v_next.start_date - 1);
    end if;
    if v_next.id is not null and p_end is null then
      raise exception '后面已经有月周期（% 起），不能把本月设成进行中', public.fmt_cn_date(v_next.start_date);
    end if;
  end if;

  v_pk := to_char(p_start, 'YYYY-MM-DD');
  v_at := case when p_end is null then null
               else (p_end + 1)::timestamp at time zone 'Asia/Shanghai' end;

  select * into v_b from public.boundaries
   where type = p_type and start_date = p_start;
  if v_b.id is null then
    insert into public.boundaries (type, period_key, boundary_at, label, is_manual,
                                   start_date, end_date, rule_weeks, settled)
    values (p_type, v_pk, v_at,
            case when p_type = 'week' then '周 ' || v_pk else '月 ' || v_pk end,
            true, p_start, p_end,
            case when p_type = 'week' then v_weeks else 1 end,
            false)
    returning * into v_new;
  else
    update public.boundaries
       set period_key = v_pk,
           boundary_at = v_at,
           end_date = p_end,
           rule_weeks = case when p_type = 'week' then v_weeks else 1 end,
           label = case when p_type = 'week' then '周 ' || v_pk else '月 ' || v_pk end,
           is_manual = true,
           settled = false
     where id = v_b.id
     returning * into v_new;
  end if;

  -- 关闭上一个月（写入结束日期）时，自动把下一月的起始日补上
  if p_type = 'month' and p_end is not null then
    if not exists (select 1 from public.boundaries w
                    where w.type = 'month' and w.deprecated = false and w.start_date = p_end + 1) then
      v_pk := to_char(p_end + 1, 'YYYY-MM-DD');
      insert into public.boundaries (type, period_key, boundary_at, label, is_manual,
                                     start_date, end_date, rule_weeks, settled)
      values ('month', v_pk, null, '月 ' || v_pk, true, p_end + 1, null, 1, false);
    end if;
  end if;

  perform public.write_audit('set_period', p_type, v_new.id::text,
    jsonb_build_object('start_date', p_start, 'end_date', p_end, 'rule_weeks', v_weeks));

  return jsonb_build_object('ok', true, 'period', to_jsonb(v_new));
end;
$$;

-- ------------------------------------------------------------
-- 8.5.3 关闭「进行中」的月：结束日默认取本周周日（所在周的 end_date）
-- ------------------------------------------------------------
create or replace function public.admin_close_period(p_end date default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b    public.boundaries;
  v_end  date;
  v_res  jsonb;
begin
  if public.caller_role() not in ('system', 'super_admin') then
    raise exception '只有管理员可以关闭月周期';
  end if;
  select * into v_b from public.boundaries
   where type = 'month' and deprecated = false and end_date is null
   order by start_date desc limit 1;
  if v_b.id is null then
    raise exception '当前没有进行中的月周期';
  end if;
  v_end := coalesce(p_end, (select w.end_date from public.boundaries w
                             where w.type = 'week' and w.deprecated = false
                               and w.start_date <= public.bj_today()
                             order by w.start_date desc limit 1));
  if v_end is null then
    raise exception '找不到可用的周周期，请先设置周周期';
  end if;
  if v_end < v_b.start_date then
    raise exception '结束日期不能早于本月的起始日期 %', public.fmt_cn_date(v_b.start_date);
  end if;
  v_res := public.admin_set_period('month', v_b.start_date, v_end, 1);
  perform public.notify_audience('admins', '月周期已关闭',
    format('月周期 %s ~ %s 已关闭，可进行月度结算', public.fmt_cn_date(v_b.start_date), public.fmt_cn_date(v_end)),
    'system', 'boundaries', v_b.id);
  return v_res;
end;
$$;

-- ------------------------------------------------------------
-- 8.5.4 补周：在 [p_from, p_to] 之间按 7 天一段补周周期（需与前后衔接）
-- ------------------------------------------------------------
create or replace function public.admin_fill_weeks(p_from date, p_to date)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_d    date := p_from;
  v_cnt  int := 0;
  v_last public.boundaries;
begin
  if v_role not in ('system', 'super_admin') then
    raise exception '只有管理员可以补周周期';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception '补周区间不合法';
  end if;
  if (p_to - p_from) > 400 then
    raise exception '一次最多补 400 天，请分段执行';
  end if;
  while v_d <= p_to loop
    if not exists (select 1 from public.boundaries w
                    where w.type = 'week' and w.deprecated = false
                      and w.start_date <= v_d and coalesce(w.end_date, w.start_date) >= v_d) then
      insert into public.boundaries (type, period_key, boundary_at, label, is_manual,
                                     start_date, end_date, rule_weeks, settled)
      values ('week', to_char(v_d, 'YYYY-MM-DD'),
              (v_d + 7)::timestamp at time zone 'Asia/Shanghai',
              '周 ' || to_char(v_d, 'YYYY-MM-DD'), true, v_d, v_d + 6, 1, false)
      on conflict (type, start_date) where start_date is not null do nothing;
      v_cnt := v_cnt + 1;
    end if;
    v_d := v_d + 7;
  end loop;
  perform public.write_audit('fill_weeks', 'week', null,
    jsonb_build_object('from', p_from, 'to', p_to, 'created', v_cnt));
  return jsonb_build_object('ok', true, 'created', v_cnt,
                            'validate', public.admin_validate_periods());
end;
$$;

-- ------------------------------------------------------------
-- 8.5.5 删除周期（仅未结算、区间内无记录）
-- ------------------------------------------------------------
create or replace function public.admin_delete_period(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_b   public.boundaries;
  v_n   int := 0;
begin
  if public.caller_role() not in ('system', 'super_admin') then
    raise exception '只有管理员可以删除周期';
  end if;
  select * into v_b from public.boundaries where id = p_id;
  if v_b.id is null then
    raise exception '周期不存在';
  end if;
  if v_b.settled then
    raise exception '该周期已结算/已汇总，不能删除';
  end if;
  if v_b.end_date is not null then
    select count(*) into v_n from public.records
     where status = '正常'
       and record_date >= to_char(v_b.start_date, 'YYYY-MM-DD')
       and record_date <= to_char(v_b.end_date, 'YYYY-MM-DD');
    if v_n > 0 then
      raise exception '该周期内有 % 条积分记录，不能删除', v_n;
    end if;
  end if;
  if v_b.type = 'month' and exists (select 1 from public.boundaries w
                                     where w.type = 'month' and w.deprecated = false
                                       and w.start_date = v_b.end_date + 1) then
    raise exception '后面还有月周期，不能删除本月（会断开连续性）';
  end if;
  delete from public.boundaries where id = p_id;
  perform public.write_audit('delete_period', v_b.type, p_id::text,
    jsonb_build_object('start_date', v_b.start_date, 'end_date', v_b.end_date));
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 8.5.6 周期列表（前端周期定义页）
-- ------------------------------------------------------------
create or replace function public.list_periods(p_type text default 'week', p_limit int default 40)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_role text := public.caller_role();
  v_rows jsonb;
begin
  if v_role not in ('system', 'super_admin', 'admin', 'executive') then
    raise exception '没有权限查看周期定义';
  end if;
  select coalesce(jsonb_agg(x order by x->>'start_date' desc), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'id', b.id,
               'type', b.type,
               'period_key', b.period_key,
               'start_date', b.start_date,
               'end_date', b.end_date,
               'rule_weeks', b.rule_weeks,
               'settled', b.settled,
               'is_manual', b.is_manual,
               'ongoing', (b.end_date is null),
               'records_count', case
                 when b.end_date is null then (
                   select count(*) from public.records r
                    where r.status = '正常'
                      and r.record_date >= to_char(b.start_date, 'YYYY-MM-DD'))
                 else (
                   select count(*) from public.records r
                    where r.status = '正常'
                      and r.record_date >= to_char(b.start_date, 'YYYY-MM-DD')
                      and r.record_date <= to_char(b.end_date, 'YYYY-MM-DD'))
               end
             ) as x
        from public.boundaries b
       where b.type = p_type and b.deprecated = false and b.start_date is not null
       order by b.start_date desc
       limit greatest(coalesce(p_limit, 40), 1)
    ) q;
  return jsonb_build_object('type', p_type, 'items', v_rows,
                            'current_key', case when p_type = 'week'
                                                then public.current_week_key()
                                                else public.current_month_key() end,
                            'validate', public.admin_validate_periods());
end;
$$;

-- ------------------------------------------------------------
-- 8.5.7 授权：仅管理员可用
-- ------------------------------------------------------------
revoke all on function public.admin_validate_periods() from public, anon;
revoke all on function public.admin_set_period(text, date, date, int) from public, anon;
revoke all on function public.admin_close_period(date) from public, anon;
revoke all on function public.admin_fill_weeks(date, date) from public, anon;
revoke all on function public.admin_delete_period(uuid) from public, anon;
revoke all on function public.list_periods(text, int) from public, anon;

grant execute on function public.admin_validate_periods() to authenticated;
grant execute on function public.admin_set_period(text, date, date, int) to authenticated;
grant execute on function public.admin_close_period(date) to authenticated;
grant execute on function public.admin_fill_weeks(date, date) to authenticated;
grant execute on function public.admin_delete_period(uuid) to authenticated;
grant execute on function public.list_periods(text, int) to authenticated;
