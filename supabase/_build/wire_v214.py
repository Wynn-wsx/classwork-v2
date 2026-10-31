import io, pathlib, sys

def patch(path, old, new, tag, count=1):
    p = pathlib.Path(path)
    s = p.read_text(encoding='utf-8')
    n = s.count(old)
    if n != count:
        print('FAIL [%s] hits=%d' % (tag, n)); sys.exit(1)
    p.write_text(s.replace(old, new), encoding='utf-8', newline='\n')
    print('OK   [%s]' % tag)

patch('build_sql.py', '    "63_ops_v211.sql",', '    "63_ops_v211.sql",\n    "64_ops_v214.sql",', 'build ORDER')
patch('check_sql.py', '"62_ops_v209.sql", "63_ops_v211.sql",', '"62_ops_v209.sql", "63_ops_v211.sql", "64_ops_v214.sql",', 'check ORDER')
patch('check_sql.py', 'EXPECTED_FUNCS = [', 'EXPECTED_FUNCS = [\n    "admin_group_week_board", "admin_draw_group_manual",', 'check EXPECTED')
patch('gen_rpc_doc.py', '    ("63_ops_v211.sql", "手动发放卡片"),', '    ("63_ops_v211.sql", "手动发放卡片"),\n    ("64_ops_v214.sql", "周期结算调整（小组人工抽奖）"),', 'rpc doc FILES')
patch('sql/90_verify.sql', "  'admin_set_user_positions','admin_run_weekly_summary','admin_run_monthly_summary',",
      "  'admin_set_user_positions','admin_run_weekly_summary','admin_run_monthly_summary',\n  'admin_group_week_board','admin_draw_group_manual',", 'verify funcs')
