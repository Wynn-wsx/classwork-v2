-- ============================================================
-- V2.0.9 热修复 2：仓库卡片「作废」状态限制
-- 规则：只有「未使用」的卡片可以作废；
--       已使用 / 已过期 / 已即时生效（星光类、文本类抽中即生效）的卡片不能作废。
-- 另外：只有「未使用」的卡片可以手工置为已过期。
-- 幂等：可重复执行；只改函数，不动数据。
-- ============================================================

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

-- 自检：函数存在
select count(*) as mark_cards_funcs
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'admin_batch_mark_cards';
