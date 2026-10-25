-- ============================================================
-- 7.5 废弃功能清理（V2.0.4：申诉功能取消）
--   幂等：重复执行无副作用
-- ============================================================

drop function if exists public.submit_appeal(uuid, text) cascade;
drop function if exists public.list_appeals(text) cascade;
drop function if exists public.handle_appeal(uuid, boolean, text) cascade;
drop table if exists public.appeals cascade;

-- 周惩罚组数默认由 3 改为 2（只纠正旧默认值，管理员手工改过的保持原值）
update public.app_config
   set week_penalty_bottom_groups = 2
 where id = 1
   and week_penalty_bottom_groups = 3;
