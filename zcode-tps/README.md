# zcode-tps

在 ZCode 界面**之外**开一个置顶小窗，实时显示模型生成速率（tok/s），并跟随你当前
所在的会话。

ZCode 插件系统没有 UI 扩展点（插件只能贡献 skills / commands / hooks / MCP / agents，
manifest 里的 `channels`、`outputStyles`、`settings` 等字段是「记录但不执行」），
所以界面内嵌显示做不到。这个插件走的是另一条路：用 `SessionStart` hook 拉起一个
独立的监控守护进程，它读 ZCode 自己写到磁盘的文件算速率。

## 显示内容

| 位置 | 含义 |
|---|---|
| 大号数字 | 最近一次模型请求的速率 = `outputTokens ÷ durationMs` |
| 迷你柱状图 | 最近 40 次请求的速率，最右一根是当前值 |
| 右上 `id xxxxxxxx` | 当前显示的是哪个会话（会话 id 前 8 位） |
| 左上圆点 | 绿色 = 2.5 秒内有新数据，灰色 = 空闲 |
| 本轮 | 当前 turn 内所有请求的合计速率与总输出 token |
| 平均 | 该会话（从回看窗口起）的平均速率 = Σ outputTokens ÷ Σ durationMs，与总输出 token |
| 最高 | 该会话内单次请求的最高速率 |
| 底部 | 模型名、已统计请求数、距上次更新的秒数；归属切到无数据会话时显示「该会话暂无生成数据」 |

窗口可拖动（拖完位置记在 `%LOCALAPPDATA%\ZCodeTpsMonitor\pos.txt`），
点右上角 `×` 关闭。窗口默认 80% 不透明度（半透明），想更透或更实用
`-Opacity` 在 0.3–1.0 间调整；半透明下文字改用灰度抗锯齿渲染——分层窗口
没有不透明底色，ClearType 会按透明底混出彩边。

小窗跟随 ZCode 主窗口：ZCode 最小化时一并收起、恢复时弹回原位；ZCode
关闭时小窗自动退出。识别按「窗口标题 `ZCode` + 进程名 `ZCode`」定位——
ZCode 是 Electron 窗口，`FindWindow` 实测搜不到，走的是 `EnumWindows`。
找不到 ZCode 窗口时（比如手动裸跑脚本）不做跟随动作，不会误关。

## 会话跟随

目标会话按这个优先级决定，每 400ms 重新判定一次：

1. **`-SessionId` 显式覆盖** —— 只给手动排查用，hook 不传它。
2. **日志事件指定的会话** —— 用户在哪个会话里按了回车或切过去，就显示哪个。
3. **最新写入的 rollout 文件** —— 兜底，带 2 秒迟滞，避免两个会话交替写入时来回跳。

第 2 条是关键。rollout 记录是**一次生成结束后**才落盘的（可能几十秒后），
而日志里的 `turn.started` 在按下回车的瞬间就写了，所以只看文件时间会明显滞后。
参与判定的日志事件是 `turn.started`、`session.resumed`、
`zcode_protocol.session_create.completed`、`bootstrap.app.startup.started`，
其中 `sess_subagent_` 开头的子代理会话被排除。

同时第 2 条带新鲜度约束：若日志指定的会话已经落后最新活动超过 30 秒，说明你跑到
别的会话干活了，就交给第 3 条跟过去。

**切换是怎么被发现的**：实测点击切换会话时，ZCode 会立刻写一条
`session.resumed` 日志事件（子代理的同类事件按 `sess_subagent_` 前缀过滤），
守护进程 400ms 内就跟过去——不需要等新会话产生活动。

**切到一个还没生成过的会话**：它连数据文件都还没有，没有速率可显示。此时
窗口显示「该会话暂无生成数据」，右上角 `id` 已换成新会话（可以确认归属确实
切过去了）；它产生第一次生成后自动开始显示。例外：切换的同时如果有别的会话
正在生成（最近 5 秒内有写入），视为日志信号过期，继续显示正在生成的那个。
右上角的 `id` 就是用来核对归属的。

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

# 调整窗口不透明度（0.3-1.0，默认 0.8）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File monitor\tps-monitor.ps1 -Opacity 0.7
```

`status.json` 是排查入口，重点看：

| 字段 | 说明 |
|---|---|
| `source` | 目标是怎么选出来的：`override` / `log` / `log-empty`（归属指向无数据会话，等待态）/ `mtime` / `none` |
| `waiting` | 归属已切到某个会话但它还没有生成数据（窗口显示「该会话暂无生成数据」） |
| `zcodeWin` | ZCode 主窗口状态：`normal` / `minimized` / `closed` / `none`（`none`=没找到，不跟随） |
| `desiredSession` | 日志事件给出的会话；为空说明还没抓到激活事件 |
| `requests` / `skipped` | 认出的记录数 / 读到但没认出的行数 |
| `error` | 非空即文件读不到，通常是 rollout 目录路径不对 |

- `requests = 0` 且 `skipped > 0`：读到行但字段没认出来，说明 ZCode 改了格式。
- 想验证跟随逻辑，可以用 `-LogDir` 指向一个合成日志目录做受控测试。

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
