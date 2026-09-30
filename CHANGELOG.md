# 变更记录

本文件记录本仓库面向用户的变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

版本号同时写在 `zcode-tps/.zcode-plugin/plugin.json` 与根 `marketplace.json` 里，
两处必须一致——`marketplace.json` 的 `version` 决定用户在插件市场看到的版本。

> 尚未打 git tag，也没有 GitHub Release。下面的日期是「该版本代码进入 main 分支的日期」。

## [Unreleased]

（下一个版本的在制品放这里。）

## [0.3.4] — 2026-09-30

### Changed

- 多行会话列表改为**稳定行序**。旧实现按「在飞 elapsed 升序 + 空闲
  `time_updated` 降序」排序，每个请求开始（计时归零）或任何会话活动
  （时间戳刷新）都会重排整列——多任务并发时行序一直切换（用户反馈）。
  现在行序保持会话首现位置，只有行集合变化才动序：新出现（新建/恢复/
  进入活跃窗口）的会话插到最上，已显示的会话原位不动；在飞状态改由
  高亮 + 计时表达，不再参与排序。tests/estim-test.ps1 场景 3/4 新增
  行序稳定性断言。

## [0.3.3] — 2026-09-30

### Changed

- 在飞且无实测估算时，速率不再显示为亮白的旧真值。实测（DESIGN.md §3.1 修订）
  推翻了「DB 落库是中位 3.5 秒一次」的前提：part 内容在该请求结束前 0.1–0.5s
  才一次性落库，请求中途（实测 7–150s）没有任何字节增量，L3 估算恒无依据。
  旧真值以亮白渲染会被读成实时速率，整段请求纹丝不动像坏了——这就是
  「切换会话后未聚焦会话 TPS 不刷新」的观感来源。现在在飞且无估算依据的行
  显示 `≈` + 该会话近期请求均值（估算色琥珀），2.5s 内刚完成的请求仍亮白
  显示真值（工具循环里保留「完成即刷新」的可见性）；连均值都没有显示 `—`。
  单卡主数字同规。L3 代码保留（多步请求按 step 边界仍有零星落库）。

### Fixed

- 标定基线改为一次性消费（配对成败都移除，下个请求 started 重新捕获）。
  基线捕获常落在 sidecar 还没看到新 message 的窗口里，旧实现把失配基线留到
  600s 兜底清理，而 message id 不会重复出现，期间该会话所有请求都配不上，
  换算系数永远得不到真值修正（calibN 恒 0）；同时历史记录（completedAt 早于
  基线捕获时刻）不消费基线，保住启动回看场景。tests/estim-test.ps1 新增
  场景 5 钉住此行为，并断言在飞行携带近期均值（avgTps）。

## [0.3.2] — 2026-09-30

### Fixed

- 消除每个新会话启动时闪现的 PowerShell 控制台窗口。SessionStart hook 每次都会
  拉起一个监控实例（已在跑的靠互斥体自灭），原先用 `Start-Process` 拉起走
  ShellExecute：控制台先以可见状态创建、等 PowerShell 启动后才被 `-WindowStyle
  Hidden` 藏起来，这段间隙就是每次会话启动看到的黑框。改为
  `ProcessStartInfo.CreateNoWindow`（CREATE_NO_WINDOW）拉起：控制台从创建起就
  无窗口，也不再写 STARTUPINFO 的 `wShowWindow`，WinForms 小窗首次 Show 不受
  影响（session-start.ps1 原注释里规避的正是这件事）。ZCode 拉起 hook 本身的
  进程是隐藏的（`windowsHide`），闪的只是脚本内部再拉起的这个。

## [0.3.1] — 2026-09-30

### Fixed

- 消除安装后的加载警告「Duplicate plugin hooks file ignored: ./hooks/hooks.json」：
  ZCode 插件加载器会自动发现约定路径 `hooks/hooks.json`，plugin.json 再显式声明
  一遍会被判为重复而忽略（仅警告，hook 本身始终生效）。修复是从 plugin.json 去掉
  `hooks` 字段，保留约定路径文件不动。

## [0.3.0] — 2026-09-29

**v2 主体落地**（DESIGN.md §6/§7 全部功能）：在飞估算与多会话并列，直接回应
「刷新率偏慢」与「并发分不清是哪个任务」两条实测反馈。

### Added

- **在飞估算速率（L3，DESIGN.md §6）**：生成过程中速率数字不再一动不动。node sidecar
  轮询 db.sqlite 里当前 assistant message 的 reasoning/text 字节数，监控按 7 秒滑动
  窗口算增量，乘以由真实请求标定出的换算系数 k（保留最近 8 次配对，`usage` 真值修正），
  显示为琥珀色 `≈N`，请求落盘后回落真值。窗口内落库不足 2 次（没有依据）时不出数字，
  只显示在飞计时——FR1-4「每个数字可溯源」。k 标定只认 30 秒内完成的请求，
  启动回看读到的历史记录不参与，基线只在真正配对成功后消费。

- **多会话并列展示（DESIGN.md §7.2/§7.3）**：并发多个任务时不再「猜一个显示」。
  活跃会话（最近 5 分钟内活动、排除子代理）各占一行：序号 + 标题 + 各自的速率；
  在飞行置顶并带高亮条与计时，空闲行按最近活动排序；上限 5 行，超出折叠为 `+N`；
  单会话时退回 v1 紧凑卡片。每行的真值来自各会话自己的 rollout tail（增量读取
  抽成共用函数），主目标会话保证在场。窗口宽度/高度随模式与行数自适应，
  关闭钮命中区同步更新。

- **sidecar 升级到 DESIGN.md §8 完整数据契约**：`titles` 全量照旧，新增 `sessions`
  数组（10 分钟活跃窗口、排除 `subagent_child`、上限 8），每项带当前 assistant
  message 的 `msgId`/`msgSeq` 与分类型计数（reasoning/text/other，tool 载荷不参与
  换算）。查询走 `(session_id, time_created, id)` 与 `(message_id, id)` 索引，
  守住 §3.2 的查询代价约束。计数口径是 UTF-16 码元（与 SQLite `length(text)` 同基准），
  标定与使用同口径自洽。

- **在飞跟踪升级为按会话的请求表**：并发多任务各自计时，`started`/`completed`
  按 sessionId 配对、`parentSpanId` 兜底，不再互相干扰。

- **测试**：`tests/estim-test.ps1`（15 项：估算出现、真值标定、多行数据、无依据不出数）
  与 `tests/sidecar-test.mjs`（7 项：合成库 + 真实 sidecar 子进程断言 §8 契约），
  均接入 CI；follow-test 15 项回归通过。`status.json` 新增 `estimTps`/`calib*`/`rows`/
  `inFlight`/`activeSessions` 字段供排查与断言。

- **截图**：README 截图工具从两张变四张，新增多行并列形态；单卡图改为「≈估算」在飞
  形态（VISUAL.md 预留的琥珀色就此启用）。

### Documentation

- README（根与插件）补多行模式、估算语义与测试入口；DESIGN.md §7.1 注记更新为
  「已落地」；VISUAL.md 补多行布局小节。

## [0.2.0] — 2026-09-29

**首个公开发布版本。** 可迁移性（PORTABILITY.md）五个层次全部落地，目标从「我本机能跑」
变成「别人下载即用」。P1 场景在每步后都保持通过。

### Added

- **会话标题显示**：小窗元信息首行右列优先显示当前会话的人能读懂的标题
  （落实 FR1-5 的「标题」半边），req 计数在场时退到 `status.json` 可查。标题由
  新增的 node sidecar（`monitor/tps-sidecar.mjs`，用 `node:sqlite` 只读轮询
  `db.sqlite` 的 `session` 表）每 250ms 写入交换文件递给监控；没有 node 环境、
  sidecar 连续失败或表结构变更时自动降级回 v1 的 id 前 8 位短码，无头/受控测试
  不启动 sidecar。DESIGN.md §7.1 的完整多会话并列展示仍是 v2 待办。

- 仓库工程化：`.gitattributes`（LF 统一 + `.ps1` 字节原样以保住 UTF-8 BOM）、
  `.gitignore`、`LICENSE`（MIT）、根 `README.md`、本文件、`CONTRIBUTING.md`、
  GitHub Actions CI（清单 JSON 校验 + 版本号一致性 + `.ps1` BOM 守卫 +
  sidecar 语法检查 + 跟随回归测试）、issue / PR 模板、README 截图生成工具。

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

