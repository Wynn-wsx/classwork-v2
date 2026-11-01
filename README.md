# 班级积分管理系统

班级量化积分管理平台。当前以 **网页版** 为唯一开发主线，目标是 **电脑 / 手机通用** 的响应式 Web 应用。

- 线上地址：<https://wynn-wsx.github.io/classwork-v2/>（V2.0 正式版）
- 源码仓库：<https://github.com/Wynn-wsx/classwork-v2>
- 线上后端：Supabase（PostgreSQL + Auth + RLS）
- 当前版本：网页版 **V2.1.4（正式版）**；旧版 V1.6 站点 <https://wynn-wsx.github.io/classwork/> 保留作回退

## 项目状态（重要）

| 部分 | 状态 | 说明 |
|---|---|---|
| **网页版（Supabase）** | **开发中（主线）** | 源文件 `supabase/index.html`，线上部署的就是它 |
| 桌面版（PyQt5） | **暂停开发** | `main.py` / `database.py` / exe 仅作存档，不再迭代 |
| 腾讯云开发版（CloudBase） | 冻结（备选） | `cloudbase/`，未上线，仅在需要迁移后端时参考 |
| 单机网页版（localStorage） | 冻结（参考） | `源代码/index.html`，早期版本，无后端 |
| 班级日记「拾光记」 | **不纳入本项目** | `拾光记_班级日记.html`、`parse_diary.py`、`generate_html.py`、`extract_images.py`、`diary_data.json`、`assets/`；开发时忽略，勿修改 |

## 目录结构

```
班级积分/
├─ supabase/                     # ★ 网页版主线（开发副本）
│  ├─ index.html                 #   单文件 Web 应用（HTML+CSS+JS 全在一个文件，V2.0 全部走 RPC）
│  ├─ schema.sql                 #   V2.0 全量库结构（幂等，可重复执行）
│  ├─ migration_v2.0.sql         #   V1.6 → V2.0 增量迁移（线上用这个，含数据回填与自检）
│  ├─ rollback_v1.6_policies.sql #   应急回退（恢复 V1.6 策略，不动数据）
│  ├─ enable_pgcron.sql          #   取消/恢复 pg_cron 周期作业（V2.0.17 起默认不启用）
│  ├─ _build/                    #   模块化 SQL 源 + build_sql.py / check_sql.py / 测试脚本
│  ├─ 部署说明.md                 #   面向老师的零基础部署教程
│  └─ 生成积分规则_加扣分速查.sql    #   积分规则速查
├─ docs/                         # 工程文档（架构、开发、部署、安全、开发列表）
├─ 开发文件/                      # ★ V2.0 开发目录（设计文档、SQL 构建源、V2 前端副本、验收文档）
├─ cloudbase/                    # 腾讯云开发版（备选后端，冻结）
├─ 源代码/                        # 早期单机网页版（localStorage，冻结）
├─ 漏洞扫描/                      # 渗透测试报告（只读参考）
├─ main.py / database.py         # 桌面版（暂停开发）
├─ 班级积分管理系统_V1.6.exe       # 桌面版打包产物（暂停开发）
├─ class_points.enc              # 桌面版加密数据库（私有数据，勿外传）
├─ 拾光记_班级日记.html 等         # 班级日记（独立项目，勿动）
└─ README.md / CHANGELOG.md / .gitignore
```

## 快速开始（正式库升级）

在 Supabase SQL Editor 执行 `supabase/upgrade_v2.1.0_正式库升级.sql`，再进「设置 → 周期定义」建立当前周/月。

## 快速开始

### 本地预览

网页版是纯静态单文件，但依赖两个 CDN（supabase-js、SheetJS）和线上 Supabase 后端，**需要联网**：

- 方式一：直接双击 `supabase/index.html` 用浏览器打开；
- 方式二（推荐，避免部分浏览器对本地文件的限制）：

```powershell
cd supabase
python -m http.server 8000
# 浏览器打开 http://localhost:8000
```

### 部署 / 更新线上

见 [docs/deployment.md](docs/deployment.md)。简版：把 `supabase/index.html` 覆盖到 GitHub 仓库 `Wynn-wsx/classwork` 根目录，等待 GitHub Pages 构建（约 1 分钟）即可。

### 初始账号

| 账号 | 密码 | 角色 |
|---|---|---|
| `admin` | `admin123` | 班主任（admin，全部班级事务权限） |
| `guanliyuan` | `guanliyuan123` | 管理员（super_admin，含时间规则/分隔点/奖池等系统配置） |
| `banzhang` | `banzhang123` | 执行管理（executive） |
| `tuanzhishu` | `tuanzhishu123` | 执行管理（executive） |

> V2.0 角色为五级：`super_admin` 管理员 > `admin` 班主任 > `executive` 执行管理 > `group_recorder` 小组记录员 > `student` 学生。
> 首次登录后请立即修改密码；学生账号用户名=学号，初始密码见系统配置（默认 `123456`），首次登录强制改密。

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 系统架构、数据模型、角色权限、模块与数据流 |
| [docs/development.md](docs/development.md) | 开发规范、移动端适配基线、调试与发布流程 |
| [docs/deployment.md](docs/deployment.md) | Supabase / GitHub Pages 部署与环境配置 |
| [docs/security.md](docs/security.md) | 安全现状（漏洞报告 V1–V5）、RLS 待办、密钥管理 |
| [docs/backlog.md](docs/backlog.md) | 开发列表（后续需求按条目登记） |
| [CHANGELOG.md](CHANGELOG.md) | 版本变更记录 |
| [supabase/部署说明.md](supabase/部署说明.md) | 非技术用户视角的完整部署教程（保留） |
| [开发文件/docs/V2.0_总体设计方案.md](开发文件/docs/V2.0_总体设计方案.md) | V2.0 需求口径与设计（时间规则、抽选、星光、通知、申诉、角色） |
| [开发文件/docs/V2.0_RPC接口清单.md](开发文件/docs/V2.0_RPC接口清单.md) | V2.0 全部 70 个 RPC 的参数与返回 |
| [开发文件/docs/数据库升级与部署说明_V2.0.md](开发文件/docs/数据库升级与部署说明_V2.0.md) | V1.6 → V2.0 数据库升级、pg_cron（已取消）、回退 |
| [开发文件/docs/M2_验收测试步骤.md](开发文件/docs/M2_验收测试步骤.md) | 数据库层验收步骤（SQL Editor 逐节操作） |
| [开发文件/docs/V2.0_开发进度与验收记录.md](开发文件/docs/V2.0_开发进度与验收记录.md) | V2.0 各模块进度、验证证据、复跑方法、待确认项 |

## 开发约定（摘要）

1. **只改 `supabase/index.html`**（以及必要的 `schema.sql`）。其他版本目录冻结，不作为开发对象。
2. **保持单文件、无构建步骤**：CSS、HTML、JS 都在一个 `index.html` 内，方便直接上传部署。
3. **移动优先**：任何界面改动都要在手机尺寸（375×667 起）和桌面尺寸下自测；断点 `768px` / `420px`。
4. **安全边界在数据库**：V2.0 前端**不再直接读写业务表**，所有写操作走 RPC、读操作走 RLS 允许的 SELECT 与查询 RPC；真正的权限由 Supabase RLS 与 SECURITY DEFINER 函数保证；前端严禁出现 `service_role` key。
5. **版本号与 CHANGELOG 同步更新**：改功能 → 升版本号（见 [CHANGELOG.md](CHANGELOG.md) 规则）。
6. 需求以 [docs/backlog.md](docs/backlog.md) 登记为准，完成一项更新一项。

## 忽略项

以下内容不参与工程化与开发：班级日记相关文件、桌面版、CDN/临时产物（详见 `.gitignore`）。`class_points.enc` 含真实班级数据，不要提交或外传。
