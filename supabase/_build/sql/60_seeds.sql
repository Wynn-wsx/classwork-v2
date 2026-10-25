-- ============================================================
-- 6. 初始数据（全部幂等：重复执行不会重复插入）
-- ============================================================

-- ------------------------------------------------------------
-- 6.1 系统配置单行
-- ------------------------------------------------------------
insert into public.app_config (id) values (1) on conflict (id) do nothing;

-- 初始化分隔点（未来 12 个月 / 回看 6 个月）
select public.ensure_boundaries();

-- 兼容已有库：1 天以前的历史分隔点视为已结算，避免 cron 首次运行时把过去半年周期全部补结算
update public.boundaries
   set settled = true
 where settled = false
   and boundary_at <= now() - interval '1 day';

-- ------------------------------------------------------------
-- 6.2 默认积分规则（V1.6 原有 37 条，原样保留）
-- ------------------------------------------------------------
insert into public.rules (score_type, category, reason, points, sort_order)
select v.score_type, v.category, v.reason, v.points, v.sort_order
from (values
('加分','学业表现','月考/期中/期末成绩进步前三名',3,1),
('加分','学业表现','月考/期中/期末后10名较上次班排进步5名/年排进步15名及以上',2,2),
('加分','学业表现','月考/期中/期末总分前10名',2,3),
('加分','学业表现','月考/期中/期末总分10~20名',1,4),
('加分','学业表现','月考/期中/期末单科前10名',1,5),
('加分','学业表现','周测前3名',1,6),
('加分','学业表现','作业质量获老师表扬',2,7),
('加分','学业表现','主动向老师请教问题、主动整理错题本上交',2,8),
('加分','学业表现','课堂主动举手回答问题（回答正确）',1.5,9),
('加分','学业表现','课堂主动举手回答问题（回答不正确）',0.5,10),
('加分','行为规范','拾金不昧/主动帮助师生解决问题（小额物品）',2,11),
('加分','行为规范','拾金不昧/主动帮助师生解决问题（贵重物品/紧急帮扶）',5,12),
('加分','行为规范','主动承担班级事务/态度认真',2,13),
('加分','文体实践','运动会/文艺活动参赛',1,14),
('加分','文体实践','主动参与班级文化布置',2,15),
('加分','文体实践','班级活动主动报名主持/表演/分享',2,16),
('加分','文体实践','参与赛事后勤、道具搬运、班级啦啦队组织、场地清理等',1,17),
('加分','文体实践','小组积分记录员周积分',1,18),
('加分','特殊加分','提出班级管理优化建议并被采纳',5,19),
('加分','特殊加分','获得校级特长类奖项（一等奖）',3,20),
('加分','特殊加分','获得校级特长类奖项（二等奖）',2,21),
('加分','特殊加分','获得校级特长类奖项（三等奖及以下）',1,22),
('加分','特殊加分','获得市级特长类奖项（一等奖）',6,23),
('加分','特殊加分','获得市级特长类奖项（二等奖）',5,24),
('加分','特殊加分','获得市级特长类奖项（三等奖及以下）',4,25),
('加分','特殊加分','获得省级/国家级特长类奖项（一等奖）',9,26),
('加分','特殊加分','获得省级/国家级特长类奖项（二等奖）',8,27),
('加分','特殊加分','获得省级/国家级特长类奖项（三等奖及以下）',7,28),
('扣分','纪律表现','早操（课间操）迟到/无故不上早操（课间操）',-2,29),
('扣分','纪律表现','作业无故未交',-2,30),
('扣分','纪律表现','课堂被老师点名批评（讲话、睡觉）',-2,31),
('扣分','纪律表现','自习讲话/做与自习无关的事',-3,32),
('扣分','纪律表现','与同学发生冲突且负主要责任',-3,33),
('扣分','纪律表现','考试作弊',-5,34),
('扣分','纪律表现','不做眼保健操',-2,35),
('扣分','纪律表现','顶撞老师',-2,36),
('扣分','纪律表现','年级组重大违纪通报批评',-5,37)
) as v(score_type, category, reason, points, sort_order)
where not exists (
  select 1 from public.rules r
  where r.score_type = v.score_type and r.category = v.category
    and r.reason = v.reason and r.points = v.points
);

-- ------------------------------------------------------------
-- 6.3 奖励池（8 种卡，概率即权重；权重按百分比原值存储，抽选时归一化）
-- ------------------------------------------------------------
insert into public.lottery_items (pool_type, item_kind, starlight_amount, title, description,
  weight, is_active, validity_type, sort_order)
select v.pool_type, v.item_kind, v.amount, v.title, v.descr, v.weight, true, v.validity, v.sort_order
from (values
('reward','func_card',0,'指定惩罚卡','可指定任意一名同学执行 1 条惩罚（惩罚池内容随机，由执行小组登记生效）。',11,'month_boundary',1),
('reward','func_card',0,'免罚卡','免除 1 次本人应执行的惩罚（含小组共担惩罚中本人份额，由执行小组登记）。',11,'month_boundary',2),
('reward','func_card',0,'免扣分卡','免除 1 次扣分（需关联具体扣分记录编号，由执行小组登记）。',11,'month_boundary',3),
('reward','starlight',3,'3 星光卡','抽中即自动入账 +3 星光值（星光卡不入仓库）。',15,'permanent',4),
('reward','starlight',5,'5 星光卡','抽中即自动入账 +5 星光值（星光卡不入仓库）。',15,'permanent',5),
('reward','starlight',10,'10 星光卡','抽中即自动入账 +10 星光值（星光卡不入仓库）。',15,'permanent',6),
('reward','func_card',0,'免值日卡','免除 1 次值日（值日安排仍按班级线下执行，由执行小组登记确认）。',11,'month_boundary',7),
('reward','func_card',0,'万能卡','可兑换为任意 1 张其他奖励卡（由执行小组登记兑换，新卡有效期至下一个月分隔点）。',8,'month_boundary',8)
) as v(pool_type, item_kind, amount, title, descr, weight, validity, sort_order)
where not exists (
  select 1 from public.lottery_items i where i.pool_type = v.pool_type and i.title = v.title
);

-- ------------------------------------------------------------
-- 6.4 惩罚池（20 条，来自 punishments.txt，默认等概率）
--     第 12、13 条为扣星光，抽中即时扣减并写流水
-- ------------------------------------------------------------
insert into public.lottery_items (pool_type, item_kind, starlight_amount, title, description,
  weight, is_active, validity_type, sort_order)
select 'penalty', v.kind, v.amount, v.title, '', 1, true, 'permanent', v.sort_order
from (values
('plain_text',0,'绕丹阳广场跑 3 圈',1),
('plain_text',0,'负责教室全面清扫，连续2天（早中晚）',2),
('plain_text',0,'课后主动请教任课老师连续 3 天',3),
('plain_text',0,'撰写 300 字《我的行为反思与改进方向》，重点写问题成因、自身不足以及具体改进做法',4),
('plain_text',0,'帮助学困生辅导功课（向学习成绩好的同学请教），连续一周',5),
('plain_text',0,'配合班委，课后检查班级门窗、电器关闭情况并做好简单记录，连续 1 周',6),
('plain_text',0,'撰写详细的个人行为改正计划书（不少于200字）',7),
('plain_text',0,'为全班朗读一篇励志教育文章（不少于5分钟）',8),
('plain_text',0,'整理班级粉笔、板擦等教具，连续 1 周',9),
('plain_text',0,'抄写名人励志名言20条（手写）',10),
('plain_text',0,'在班会上做200字以上自我反省发言，听取大家意见',11),
('starlight_penalty',-3,'星光积分扣除3颗',12),
('starlight_penalty',-5,'星光积分扣除5颗',13),
('plain_text',0,'整理班级劳动工具并摆放整齐，连续 1 周',14),
('plain_text',0,'替班级换水，连续一周',15),
('plain_text',0,'写一封给未来自己的信，畅谈自我改正的决心',16),
('plain_text',0,'主动向被自己影响的同学真诚道歉信（不少于100字）',17),
('plain_text',0,'为班级绿植浇水养护，连续 1 个星期',18),
('plain_text',0,'协助值日生完成全部值日工作，连续1天',19),
('plain_text',0,'写出任意一个小组的所有组员的优点',20)
) as v(kind, amount, title, sort_order)
where not exists (
  select 1 from public.lottery_items i where i.pool_type = 'penalty' and i.title = v.title
);

-- ------------------------------------------------------------
-- 6.5 首次初始化：默认账号（仅当 profiles 为空时创建；线上已有账号则跳过）
--     依赖 54_accounts.sql 的 admin_create_user(p_username,p_password,p_name,p_role,p_group)
--     super_admin 说明：V2.0 的 A1/A2/A8/B1/B3/B4/B7/B8/C1 等专属权限只属于
--     超级管理员。全新空库会建一个 guanliyuan 超级管理员；已存在的线上库不会自动
--     提权任何人，迁移后用 SQL Editor 手动把指定账号提升为 super_admin（见部署说明）。
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.profiles) then
    perform public.admin_create_user('admin',       'admin123',      '班主任',  'admin',       null);
    perform public.admin_create_user('guanliyuan',  'guanliyuan123', '管理员',  'super_admin', null);
    perform public.admin_create_user('banzhang',    'banzhang123',   '班长',    'executive',   null);
    perform public.admin_create_user('tuanzhishu',  'tuanzhishu123', '团支书',  'executive',   null);
  end if;
end $$;

-- 已升级库若没有任何超级管理员：只提示、不自动提权（权限变更必须由人决定）
do $$
begin
  if exists (select 1 from public.profiles)
     and not exists (select 1 from public.profiles where role = 'super_admin') then
    raise notice '提醒：当前没有任何超级管理员(super_admin)账号。请用 SQL Editor 执行：';
    raise notice '  update public.profiles set role = ''super_admin'' where username = ''<你的账号>'';';
    raise notice '否则老师账号管理、分隔点规则、备份导出等管理员专属功能无人可用。';
  end if;
end $$;
