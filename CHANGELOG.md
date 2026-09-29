# 变更记录

本文件记录本仓库面向用户的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

版本号同时写在 `zcode-tps/.zcode-plugin/plugin.json` 与根 `marketplace.json` 里，
两处必须一致——`marketplace.json` 的 `version` 决定用户在插件市场看到的版本。

> 尚未打 git tag，也没有 GitHub Release。下面的日期是「该版本代码进入 main 分支的日期」。

## [Unreleased]

### Added

- **会话标题显示**：小窗元信息首行右列优先显示当前会话的人能读懂的标题
  （落实 FR1-5 的「标题」半边），req 计数在场时退到 `status.json` 可查。标题由
  新增的 node sidecar（`monitor/tps-sidecar.mjs`，用 `node:sqlite` 只读轮询
  `db.sqlite` 的 `session` 表）每 250ms 写入交换文件递给监控；没有 node 环境、
  sidecar 连续失败或表结构变更时自动降级回 v1 的 id 前 8 位短码，无头/受控测试
  不启动 sidecar。DESIGN.md §7.1 的完整多会话并列展示仍是 v2 待办。

- 仓库工程化：`.gitattributes`（LF 统一 + `.ps1` 字节原样以保住 UTF-8 BOM）、
  `.gitignore`、`LICENSE`（MIT）、根 `README.md`、本文件、`CONTRIBUTING.md`、
  GitHub Actions CI（清单 JSON 校验 + `.ps1` BOM 守卫 + 跟随回归测试）、
  issue / PR 模板。

## [0.2.0] — 2026-09-29

可迁移性（PORTABILITY.md）五个层次全部落地，目标从「我本机能跑」变成「别人下载即用」。
本版未改变默认行为，P1 场景在每步后都保持通过。

### Added

- **L1 环境守门**：`SessionStart` hook 在非 Windows 上静默 `exit 0`（hook 报错会打扰
  每个会话启动）；监控启动时探测 PowerShell 受限语言模式（CLM），受限时照常运行但在
  小窗标注「精简模式（系统策略限制）」，把静默退化变成可见的退化。
- **L2 配置文件**：`%LOCALAPPDATA%\ZCodeTpsMonitor\config.json`，可配界面语言、
  不透明度、ZCode 数据目录、主窗口匹配（标题 / 进程名）、前台跟随；命令行参数优先，
  便于排查时临时覆盖。
- **L3 界面文案 i18n**：zh-CN / en-US 两份字符串表，取用顺序为
  `config.language` → 系统文化 → 英文兜底。
- **L4 生命周期**：卸载毒丸（监控每 2s 检查插件根目录，目录消失即退出并清掉
  `pos.txt` / `status.json` / `config.json`）与 `/tps start|stop` 命令（`stop` 写哨兵
  文件 `stop.flag`，不用杀进程）。
- **L5 分发**：README 增加英文 quickstart、环境声明与配置章节；版本号提升到 0.2.0。

### Fixed

- 并发场景下会话跟随失效：归属判定曾把「rollout 文件写入时间」当成「用户在哪」的
  证据，而 rollout 只在一次请求**结束**时落盘——后台会话每完成一个请求就刷新自己的
  文件，用户所在会话在思考期间根本不写文件，于是用户意图被否决。实测切换后显示别的
  会话长达 102 秒 / 131 秒。改为「用户意图（`turn.started` / `session.resumed`）+ 10
  分钟有效期」无条件跟随，且不再被其他会话的写入否决；`bootstrap.app.startup.started`
  与 `session_create.completed` 不再算意图（防止临时会话劫持归属）。
  同一批真实日志回放：目标切换 30 次 → 4 次，来回抖动 16 次 → 0，归属正确率 76% → 100%。

### Documentation

- 新增 `PORTABILITY.md`（可迁移性设计：迁移面盘点、L1–L5 方案、P1–P9 验收矩阵）。
- 新增 `VISUAL.md`（小窗视觉方案）与 `REQUIREMENTS.md`（需求基线 v1.5）。

## [0.1.0] — 2026-09-28

首个可运行版本。

### Added

- ZCode 插件骨架与本地插件市场清单（`marketplace.json`）。
- `SessionStart` hook 拉起常驻 PowerShell 守护进程，增量解析
  `~/.zcode/cli/rollout/model-io-<sessionId>.jsonl` 计算 TPS，绘制置顶小窗。
- 速率口径 `outputTokens ÷ durationMs`，同时显示单次请求最高速率与会话平均速率
  （Σ outputTokens ÷ Σ durationMs）。
- 会话跟随：`turn.started` 等日志事件判定归属，回落到最新写入的 rollout 文件。
- 子代理（会话 id 前缀 `sess_subagent_`）不参与统计、不影响归属。
- 半透明小窗（默认 0.85 不透明度，`-Opacity` 可调 0.3–1.0），拖动记忆位置，
  悬停显示关闭钮。
- 跟随 ZCode 主窗口：最小化一并收起、恢复弹回、关闭则退出；ZCode 失去前台时隐藏，
  回前台恢复显示且不抢焦点（`WS_EX_NOACTIVATE`）。
- 深色视觉改版：等宽大号主数字、迷你柱状图、元信息三行（依据 `VISUAL.md`）。
- `-Headless` 自检模式与 `status.json` 诊断输出；`tests/follow-test.ps1` 回归测试
  （6 个场景 15 项断言）。

