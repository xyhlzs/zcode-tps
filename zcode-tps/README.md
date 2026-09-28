# zcode-tps

在 ZCode 界面**之外**开一个置顶小窗，实时显示模型生成速率（tok/s），并跟随你当前
所在的会话。

ZCode 插件系统没有 UI 扩展点（插件只能贡献 skills / commands / hooks / MCP / agents，
manifest 里的 `channels`、`outputStyles`、`settings` 等字段是「记录但不执行」），
所以界面内嵌显示做不到。这个插件走的是另一条路：用 `SessionStart` hook 拉起一个
独立的监控守护进程，它读 ZCode 自己写到磁盘的文件算速率。

## 显示内容

深色小窗（#1A1D22，视觉方案见 VISUAL.md），「数字即界面」：大号等宽数字是唯一的
主角，其余信息以小号灰字收在下方，彩色只在表达状态时出现。

| 位置 | 含义 |
|---|---|
| 大号数字 | 最近一次模型请求的速率 = `outputTokens ÷ durationMs`；等宽字体，刷新时字宽稳定不抖。在飞时亮白，空闲时降为灰色 |
| 左上圆点 | 绿色 = 正在生成（日志有 started 未配对 completed 的请求）或 2.5 秒内有新数据；红色 = 出错；灰色 = 空闲 |
| 右上角 | 生成中显示本次请求已进行的秒数（计时来源是日志 `model.request.started`，≤1s 刷新）；空闲/等待时显示 `id xxxxxxxx`（当前会话 id 前 8 位） |
| 迷你柱状图 | 最近 40 次请求的速率，历史柱灰色，最右一根是当前值（在飞时绿色）；纵轴带迟滞，刷出新高不会整图重缩放 |
| 元信息三行 | 左列：模型名（超长截断）、本轮 turn 输出 token、会话累计输出 token；右列：已统计请求数、平均速率（Σ outputTokens ÷ Σ durationMs）、单次请求最高速率 |
| 状态文案 | 归属切到无数据会话时显示「该会话暂无生成数据」；出错时显示红色错误信息 |

窗口可拖动（拖完位置记在 `%LOCALAPPDATA%\ZCodeTpsMonitor\pos.txt`）。
关闭钮平时不显示，鼠标悬停到小窗上时右上角淡入 `×`。窗口默认 85% 不透明度
（半透明），想更透或更实用 `-Opacity` 在 0.3–1.0 间调整；半透明下文字改用
灰度抗锯齿渲染——分层窗口没有不透明底色，ClearType 会按透明底混出彩边。

小窗跟随 ZCode 主窗口：ZCode 最小化时一并收起、恢复时弹回原位；ZCode
切到后台（不在前台）时小窗隐藏、回到前台自动恢复显示；ZCode 关闭时小窗
自动退出。恢复显示不抢焦点——小窗带 `WS_EX_NOACTIVATE`，永远不当地前台
窗口，隐藏期间统计照常进行。识别按「窗口标题 `ZCode` + 进程名 `ZCode`」
定位——ZCode 是 Electron 窗口，`FindWindow` 实测搜不到，走的是
`EnumWindows`。找不到 ZCode 窗口时（比如手动裸跑脚本）不做跟随动作，
不会误关。

## 会话跟随

目标会话按这个优先级决定，每 400ms 重新判定一次：

1. **`-SessionId` 显式覆盖** —— 只给手动排查用，hook 不传它。
2. **用户意图**（日志事件 `turn.started` / `session.resumed`）—— 在 **10 分钟有效期**
   （`-IntentTtlMs`，默认 600000ms）内**无条件跟随**：意图会话还没有数据就显示等待态，
   绝不拿别的会话的数字顶上。
3. **最新写入的 rollout 文件** —— 只在没有意图、或意图已过期时兜底，带 2 秒迟滞，
   避免两个会话交替写入时来回跳。

第 2 条是关键。rollout 记录是**一次生成结束后**才落盘的（可能几十秒后），
而日志里的 `turn.started` 在按下回车的瞬间就写了，所以只看文件时间会明显滞后。
`session.resumed` 在恢复「有历史」的会话时发出（任务系统临时建的会话不触发），
`bootstrap.app.startup.started` / `session_create.completed` 则刻意**不**参与判定。

**为什么意图带 10 分钟有效期、而且不被文件新鲜度否决**：并发时后台会话每完成一个
请求就刷新自己的 rollout 文件，而你所在的会话在「思考」期间（一次请求没结束）根本
不写文件——拿文件新鲜度去比较，显示必然被后台会话抢走。实测过：切换后显示别的会话
长达 102 秒、另一次 131 秒；20 分钟内目标切换 30 次、来回抖动 16 次、只有 44.9% 的
时间显示的是你所在的会话。有效期取 10 分钟，与 ZCode 回收空闲会话运行时的超时
（实测 600s）一致：这段时间内该会话仍然「活着」，超过后用户多半已经离开，才允许
回落到「谁在生成就显示谁」。

**为什么 `bootstrap.app.startup.started` / `session_create.completed` 不算意图**：
它们既对「用户新建会话」触发，也对「任务系统临时建会话」触发（实测当天 44 次创建里
24 次创建后没有任何对话活动、没有 turn、没有模型请求）。采纳它们会把显示目标劫持到
一个永远没有数据的会话上，表现为「一个会话的 TPS 时不时弹出」——目标会话没有数据
文件时，窗口会在「某个后台会话的数字」和「暂无生成数据」之间反复横跳。新建的会话在
你发出第一条消息（`turn.started`）时立刻跟过去。

**切换是怎么被发现的**：点击切换到一个**不在驻留期**的会话时，ZCode 会写
`session.resumed`（伴随 `bootstrap.app.startup.*`）事件，守护进程 400ms 内跟过去。
`turn.started` 则在按下回车时立刻跟过去。

**切到一个还没生成过的会话**：它连数据文件都还没有——rollout 文件随会话运行时生灭，
运行时被回收（空闲 10 分钟）后文件会被删除。此时窗口显示「该会话暂无生成数据」，
右上角 `id` 已换成新会话（可以确认归属确实切过去了）；它产生第一次生成后自动开始
显示。右上角的 `id` 就是用来核对归属的。

**已知边界**：纯「浏览式切换」——切到一个仍在驻留期内（10 分钟内活动过）的会话、
又不发消息——在日志和数据库里没有任何事件可依据（窗口标题固定为 `ZCode`，
localStorage 只存草稿，没有持久化的「当前会话」）。此时显示保持在上一个会话。
要覆盖这种情况，需要并列显示所有会话（[DESIGN.md](DESIGN.md) §7 的多行方案）或读
UI 无障碍树（§12 的开放问题）。

## 数据来源与已知限制

两个内部文件，都**没有官方 API 保证**，ZCode 升级后字段可能变：

- `~/.zcode/cli/rollout/model-io-<sessionId>.jsonl` —— 每次模型请求一行，
  含 `durationMs` 与 `response.usage.outputTokens`，是速率的唯一真实来源。
  （日志里的同一组数字已经被他们写成 `[Redacted]` 了。）
- `~/.zcode/cli/log/zcode-YYYY-MM-DD.jsonl` —— 只用来判断当前会话。

由此带来三个限制：

1. **不是逐 token 平滑刷新**，粒度是「一次流式生成结束」。一个回合里有几次工具调用
   就有几次刷新，观感是活的，但不会像打字机那样连续跳。
2. **时长含首字延迟（TTFT）**，所以算出来是端到端速率，比模型纯解码速率略低。
3. 单个 rollout 记录里带完整对话历史，长会话下单条可达数 MB。脚本因此不整体解析
   JSON（PS 5.1 的 `ConvertFrom-Json` 有 2MB 上限），只从行首/行尾切片正则提取
   需要的字段，并按行边界回看最多 8MB。

## 安装

1. 打开 **插件市场 → 添加 → 添加插件市场**，粘贴这个目录：

   ```
   D:\dev\zcode-tps
   ```

2. 到 **个人 → ZCode TPS 监控（本地市场名 `dev-zcode-tps-local`）→ 安装**。
3. 新开一个任务，小窗会随 `SessionStart` 自动出现。

## 手动运行与自检

不装插件也能直接用：

```powershell
# 正常启动（带窗口）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File monitor\tps-monitor.ps1

# 无窗自检：跑 10 秒，把统计写到 %LOCALAPPDATA%\ZCodeTpsMonitor\status.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File monitor\tps-monitor.ps1 -Headless -Seconds 10

# 手动钉死某个会话排查
powershell.exe -NoProfile -ExecutionPolicy Bypass -File monitor\tps-monitor.ps1 -SessionId sess_xxxx

# 调整窗口不透明度（0.3-1.0，默认 0.85）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File monitor\tps-monitor.ps1 -Opacity 0.7
```

`status.json` 是排查入口，重点看：

| 字段 | 说明 |
|---|---|
| `source` | 目标是怎么选出来的：`override`（手动钉死）/ `intent`（用户意图）/ `intent-wait`（意图会话还没有数据，等待态）/ `mtime`（意图过期后的兜底）/ `none` |
| `waiting` | 归属已切到某个会话但它还没有生成数据（窗口显示「该会话暂无生成数据」） |
| `zcodeWin` | ZCode 主窗口状态：`normal` / `minimized` / `hidden`（不在前台，小窗已隐藏）/ `closed` / `none`（`none`=没找到，不跟随） |
| `desiredSession` | 用户意图指向的会话；为空说明还没抓到 `turn.started` / `session.resumed` |
| `intentAtUtc` / `intentAgeMs` / `intentTtlMs` | 该意图的日志时间戳、已过时长、有效期。排查「显示为什么没跟着我切」先看这三个 |
| `requests` / `skipped` | 认出的记录数 / 读到但没认出的行数 |
| `error` | 非空即文件读不到，通常是 rollout 目录路径不对 |

- `requests = 0` 且 `skipped > 0`：读到行但字段没认出来，说明 ZCode 改了格式。
- 想验证跟随逻辑，用 `-LogDir` / `-RolloutDir` / `-StateDir` 指向合成目录做受控测试，
  或直接跑现成的回归测试：

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\follow-test.ps1
  ```

  它用合成日志/rollout 驱动一个隔离的 `-Headless` 监控进程，断言 6 个场景（意图跟随、
  后台会话持续生成时不抢归属、幽灵会话不劫持、无数据会话的等待态不抖动、子代理不影响
  归属、意图过期后回落），退出码 0 即全部通过。

## 关闭与卸载

- 关窗口：点 `×`。下次 `SessionStart` 会再拉起。
- 彻底卸载：在 **设置 → 插件管理 → 已安装** 里卸载；再删掉
  `%LOCALAPPDATA%\ZCodeTpsMonitor` 目录（位置与状态缓存）。

## 排查

- **没看到窗口 / 被别的窗口盖住**：查进程里有没有 `tps-monitor.ps1`：

  ```powershell
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*tps-monitor*' }
  ```

  守护进程是单实例的（命名互斥体 `Local\ZCodeTpsMonitor`），已经在跑时重复启动会
  立刻退出，这是预期行为。

  小窗靠 `WS_EX_TOPMOST` 保持置顶。只设 `Form.TopMost` 实测不生效，脚本因此在窗口
  显示时断言一次、之后每 2 秒检查一次并自愈。要看当前状态：

  ```powershell
  Add-Type -Namespace T -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h,int i);'
  # 对 hwnd 取 GWL_EXSTYLE(-20)，与 0x8 按位与，非 0 即为置顶
  ```

- **数字发虚**：窗口按屏幕缩放因子（`DpiX / 96`）放大布局并做了 DPI 感知，
  在 200% 缩放下以原生分辨率渲染。若仍发虚，确认没有用一个自绘缩放的放大镜工具
  去截它。
- **控制台一闪而过**：启动器把 `-WindowStyle Hidden` 传给 `powershell.exe` 自己，
  只隐藏控制台。如果默认终端宿主是 Windows Terminal，它可能忽略这个开关而闪一下，
  不影响功能。
