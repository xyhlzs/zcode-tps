#Requires -Version 5.1
<#
  ZCode TPS Monitor

  在 ZCode 界面之外开一个置顶小窗，实时显示模型生成速率（tok/s）。

  == 数据来源 ==
  rollout：~/.zcode/cli/rollout/model-io-<sessionId>.jsonl
    每个模型请求追加一行，含 durationMs 与 response.usage.outputTokens。
    速率 = outputTokens / (durationMs/1000)。

  log：~/.zcode/cli/log/zcode-YYYY-MM-DD.jsonl
    只用来判断「当前是哪个会话」。turn.started 在你按下回车时就写，
    而 rollout 要等这次生成结束才落盘（可能几十秒），所以光看 rollout
    的 mtime 会明显滞后；靠日志事件才能立刻跟住会话切换。

    只有 turn.started / session.resumed 算「用户意图」，且带有效期
    （IntentTtlMs，默认 10 分钟）。有效期内的意图不会被别的会话的 rollout
    写入否决——这是必须的：并发时后台会话每完成一个请求就刷新自己的文件，
    而用户所在会话在「思考」期间（一次请求没结束）根本不写文件，拿文件
    新鲜度去比较，显示必然被后台会话抢走。
    bootstrap.app.startup.started / session_create.completed 刻意不算意图：
    它们对「用户新建会话」和「任务系统临时建会话」一视同仁（实测当天 44 次
    创建里 24 次创建后没有任何对话活动），采纳它们会把显示目标劫持到一个
    永远没有数据的会话上。

  sidecar：会话标题与活跃会话的流式字节都只存在于 db.sqlite，而 PS 5.1 没有
  SQLite provider（DESIGN.md §3.3），由 node sidecar（tps-sidecar.mjs，node:sqlite
  只读轮询）经交换文件 sidecar.json 递过来（DESIGN.md §8 数据契约：titles 全量
  + sessions 活跃集，每项带当前 assistant message 的分类型字节数）；没有 node 或
  sidecar 连续失败时退回 id 前 8 位、估算与并列展示不可用（DESIGN.md §9）。

  速率三层（DESIGN.md §6，诚实度不同，界面上能看出来）：
    L1 在飞状态   日志 started/completed 按 sessionId/parentSpanId 配对，真值；
                  提供状态点、计时（≤1s 刷新）。
    L2 请求真值   rollout 落盘后 outputTokens ÷ durationMs，权威数字。
    L3 在飞估算   sidecar 快照里当前 message 的 reasoning/text 字节增量 × 换算
                  系数 k，5 秒滑动窗口；显示为 ≈N（估算色），窗口内落库不足
                  2 次时不显示——没有依据就不出数字（FR1-4）。k 由最近完成的
                  请求按 usage 真值标定。

  == 为什么不用 ConvertFrom-Json ==
  单条 rollout 记录里 request.messages 带完整对话历史，长会话下单条可达数 MB，
  既超过 PS 5.1 的 MaxJsonLength(2MB) 上限，整体解析也浪费。
  这里只从行首/行尾切片正则提取需要的标量字段。
  依赖的字段顺序（ZCode 内部格式，无官方保证）：
    - durationMs / completedAt / model.modelId 在行首
    - response.usage 是 response 的最后一个键，其后只剩 sessionId/
      querySource/startedAt/traceId/turnId/type 几个短字段，故都在行尾
  任一处取不到时回退到整行匹配。

  用法：
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tps-monitor.ps1
    powershell.exe ... -File tps-monitor.ps1 -Headless -Seconds 10   # 无窗自检，写 status.json
    powershell.exe ... -File tps-monitor.ps1 -SessionId sess_xxx     # 手动钉死某个会话
    powershell.exe ... -File tps-monitor.ps1 -Opacity 0.85   # 窗口不透明度（0.3-1.0，默认 0.85）

  -LogDir / -RolloutDir / -StateDir / -IntentTtlMs 是给受控测试用的隔离与调参开关，
  见 tests\follow-test.ps1；日常运行不要传。
#>
[CmdletBinding()]
param(
  [string]$SessionId,
  [string]$RolloutDir,
  [string]$LogDir,
  [string]$StateDir,
  [switch]$Headless,
  [int]$Seconds = 0,
  [double]$Opacity = 0.85,
  # 用户意图的有效期（毫秒）。默认 10 分钟，与 ZCode 回收空闲会话运行时的
  # resident idle 超时（实测 600000ms）一致：这段时间内该会话仍「活着」，
  # 超过后用户多半已经离开，才允许回落到「谁在生成就显示谁」。
  [int]$IntentTtlMs = 600000,
  # 跳过卸载毒丸（PORTABILITY.md §2 L4-1）。给受控测试用：测试副本放在临时目录
  # 时目录被清会误杀监控。日常运行不要传。
  [switch]$NoWatchdog
)

$ErrorActionPreference = 'Stop'

# 钳制到可用区间：低于 0.3 基本看不清，高于 1.0 非法
$Opacity = [Math]::Min(1.0, [Math]::Max(0.3, $Opacity))

# 受限语言模式探测（PORTABILITY.md §2 L1）：企业策略下 Add-Type 编译被禁，
# 窗口跟随/置顶自愈/不抢焦点都会静默失效。把「静默退化」变成「可见的退化」：
# 界面上标注精简模式。读取本身在 CLM 下允许；连读取都失败时按受限处理。
$script:Restricted = $false
try {
  if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { $script:Restricted = $true }
} catch {
  $script:Restricted = $true
}

# ------------------------------------------------------------------ 配置文件
# 可选 config.json：普通用户改这里，不用碰 hook 命令行（PORTABILITY.md §2 L2）。
# 优先级：命令行显式参数 > 配置文件 > 内置默认。解析失败按无配置处理。
if (-not $StateDir) { $StateDir = Join-Path $env:LOCALAPPDATA 'ZCodeTpsMonitor' }
$PosFile = Join-Path $StateDir 'pos.txt'
$StatusFile = Join-Path $StateDir 'status.json'
$ConfigFile = Join-Path $StateDir 'config.json'
$StopFlag = Join-Path $StateDir 'stop.flag'
$SidecarSnap = Join-Path $StateDir 'sidecar.json'   # node sidecar 写的标题快照（DESIGN.md §8 交换文件）

# 卸载毒丸的判定基准：脚本住在 <插件根>\monitor\ 下，上级就是插件根
# （PORTABILITY.md §2 L4-1）。插件被卸载/缓存被清时该目录消失。
$script:PluginRoot = $null
try { $script:PluginRoot = Split-Path -Parent $PSScriptRoot } catch { }
$script:TearDown = $false            # 毒丸清理后关闭窗口时不再回写 pos.txt

$script:Cfg = @{
  language         = 'auto'      # auto | zh-CN | en-US
  opacity          = $null       # $null = 未配置，用内置默认
  zcodeHome        = ''          # 空 = %USERPROFILE%\.zcode\cli
  windowTitle      = 'ZCode'     # ZCode 主窗口匹配：标题
  windowProcess    = 'ZCode'     # ZCode 主窗口匹配：进程名
  followForeground = $true       # false = ZCode 不在前台也不隐藏小窗
}
try {
  if (Test-Path -LiteralPath $ConfigFile) {
    $raw = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($raw.language) { $script:Cfg.language = [string]$raw.language }
    if ($null -ne $raw.opacity) { $script:Cfg.opacity = [double]$raw.opacity }
    if ($raw.zcodeHome) { $script:Cfg.zcodeHome = [string]$raw.zcodeHome }
    if ($raw.windowTitle) { $script:Cfg.windowTitle = [string]$raw.windowTitle }
    if ($raw.windowProcess) { $script:Cfg.windowProcess = [string]$raw.windowProcess }
    if ($null -ne $raw.followForeground) { $script:Cfg.followForeground = [bool]$raw.followForeground }
  }
} catch { }

# 命令行显式传参优先于配置文件；配置值同样要钳制
if (-not $PSBoundParameters.ContainsKey('Opacity') -and $null -ne $script:Cfg.opacity) {
  $Opacity = [Math]::Min(1.0, [Math]::Max(0.3, $script:Cfg.opacity))
}

$ZCodeHome = Join-Path $env:USERPROFILE '.zcode\cli'
if ($script:Cfg.zcodeHome) { $ZCodeHome = $script:Cfg.zcodeHome }
if (-not $RolloutDir) { $RolloutDir = Join-Path $ZCodeHome 'rollout' }
if (-not $LogDir) { $LogDir = Join-Path $ZCodeHome 'log' }

# ------------------------------------------------------------------ 界面文案 i18n
# 字符串表（PORTABILITY.md §2 L3）：config.language → 系统 UI 文化 → 英文兜底。
# 只做 zh/en 两份，其余 locale 落英文；就是脚本内两个 hashtable，不引资源文件。
$script:StrTables = @{
  zh = @{
    unit       = 'tok/s'
    noRollout  = '未找到 rollout 文件'
    waiting    = '该会话暂无生成数据'
    unreadable = '已读 {0} 行，0 条可识别'
    restricted = '精简模式（系统策略限制）'
    reqFmt     = 'req {0}'
    turnFmt    = '本轮 {0} tok'
    totalFmt   = '累计 {0:N0} tok'
    avgFmt     = '平均 {0}'
    maxFmt     = '最高 {0}'
    idFmt      = 'id {0}'
    noModel    = '等待输出'
    elapsedFmt = '已 {0:N1}s'
    moreFmt    = '+{0}'
    header     = 'ZCode TPS'
  }
  en = @{
    unit       = 'tok/s'
    noRollout  = 'Rollout files not found'
    waiting    = 'No generation data in this session yet'
    unreadable = 'Read {0} lines, 0 recognized'
    restricted = 'Lite mode (system policy)'
    reqFmt     = 'req {0}'
    turnFmt    = 'Turn {0} tok'
    totalFmt   = 'Total {0:N0} tok'
    avgFmt     = 'Avg {0}'
    maxFmt     = 'Peak {0}'
    idFmt      = 'id {0}'
    noModel    = 'Waiting for output'
    elapsedFmt = '{0:N1}s'
    moreFmt    = '+{0}'
    header     = 'ZCode TPS'
  }
}
$script:Lang = 'en'
try {
  $want = $script:Cfg.language
  if ($want -eq 'auto') {
    # auto：系统 UI 语言以 zh 开头（zh-CN/zh-TW…）给中文，否则英文
    $want = 'en'
    if ((Get-UICulture).Name -like 'zh*') { $want = 'zh' }
  }
  elseif ($want -like 'zh*') { $want = 'zh' }
  else { $want = 'en' }
  $script:Lang = $want
} catch { }
$script:Str = $script:StrTables[$script:Lang]

# 首次接入一个 rollout 文件时回看多少字节（行对齐后从这里开始读）
$LookbackBytes = 8388608L

# 首次接入日志文件时回看多少字节，用来找最近一次「用户意图」事件。
# 稳态下每 400ms 增量读取就够了，但刚启动的守护进程只能靠回看：64KB 在繁忙
# 日志里只覆盖几秒，可能错过最后一次 turn.started。回看里读到旧意图不会被
# 误当成刚发生的意图——意图时间取日志行自己的 timestamp（见 Update-DesiredSession）。
$LogAttachLookbackBytes = 1048576L

# 回退到「最新活动文件」时，新文件要比当前目标新这么多才切，避免两个会话交替写入时来回跳
$SwitchHysteresisMs = 2000

# 这些日志事件代表「用户此刻在这个会话里」：
#   turn.started    —— 用户在会话里提交了输入
#   session.resumed —— 恢复「有历史」的会话（实测其 context.appliedMessageCount > 0），
#                      任务系统临时建的会话不会触发
$IntentEvents = @('turn.started', 'session.resumed')

# ------------------------------------------------------------------ 状态

function New-Stats {
  return [ordered]@{
    target         = ''
    source         = ''
    model          = ''
    sessionId      = ''
    turnId         = ''
    lastTps        = $null
    lastOut        = 0
    lastReasoning  = 0
    lastDurationMs = 0
    lastAtUtc      = $null
    turnOut        = 0
    turnMs         = 0.0
    sessOut        = 0
    sessMs         = 0.0
    sessMaxTps     = $null
    requests       = 0
    skipped        = 0
    waiting        = $false
    spark          = @()
    error          = ''
    chartMax       = 0.0
  }
}

$script:Stats = New-Stats
$script:Tail = @{ path = ''; pos = 0L; carry = '' }          # rollout 读取游标
$script:LogTail = @{ path = ''; pos = 0L; carry = '' }        # 日志读取游标
$script:DesiredSession = ''                                    # 用户意图指向的会话（见 $IntentEvents）
$script:IntentAtUtc = [DateTime]::MinValue                     # 该意图的日志时间戳，用来判是否过期
$script:ZCodeHwnd = [IntPtr]::Zero                             # ZCode 主窗口句柄缓存
$script:ZCodeSeen = $false                                     # 是否成功找到过 ZCode 窗口
$script:ZCodeState = 'none'                                    # none / normal / minimized / closed
# 在飞请求表（L1，DESIGN.md §6）：sessionId → @{ utc; span }。v1 只跟踪单个请求，
# 并发多任务各自在飞时只有一个计时；'_' 键承接没有 sessionId 的 started 事件。
$script:ReqStarts = @{}
$script:Hovered = $false                                       # 鼠标是否悬停在小窗上（控制 × 显隐）

# 标题 sidecar（tps-sidecar.mjs）的生命周期状态，重启/放弃策略见 DESIGN.md §9
$script:NodeExe = $null
$script:SidecarProc = $null
$script:SidecarFails = 0        # 连续「无新鲜快照」次数，≥3 放弃，退回 id 短码
$script:SidecarDead = $false
$script:TitleMap = @{}          # sessionId → title，来自 sidecar 快照
$script:SidecarSessions = @()   # DESIGN.md §8 契约的活跃会话数组（含分类型字节）

# L3 在飞估算（DESIGN.md §6）：每个在飞会话的字节采样窗口 + 全局换算系数标定。
# 窗口 7 秒（5s 计算 + 余量），msgId 变了就重开——message 边界处的字节不可比。
$script:EstimWinMs = 7000
$script:EstimWin = @{}          # sessionId → @{ samples=@(); msgId='' }
$script:Calib = @{
  reasoning = @{ samples = @() }   # 元素 @{ tok; bytes }，k = Σtok ÷ Σbytes
  text      = @{ samples = @() }
}
$script:CalibMaxSamples = 8     # 只用最近 N 次配对，模型/语言变化后旧标定自动淡出
$script:CalibBase = @{}         # sessionId → @{ b0r; b0x; msgId; utc }，请求开始时的计数基线
# 计数口径：sidecar 的 part 计数是 UTF-16 码元数（与 SQLite length(text) 同基准），
# 不是 UTF-8 字节。k 的标定与使用都在这个口径上，单位自洽；默认值按「中文/英文
# 混合、JSON 转义膨胀」粗估（中文 1 码元 ≈ 0.5-0.8 tok，英文 ≈ 0.25），首次请求
# 完成后即被真值修正。
$script:CalibDefaultK = 0.35    # 无标定数据时的粗估（tok/码元）

$script:Drag = $false
$script:DragMoved = $false
$script:DragOffX = 0
$script:DragOffY = 0

# ------------------------------------------------------------------ 标题 sidecar 生命周期

function Start-Sidecar {
  # 无头自检/受控测试不碰真实 db、不留子进程
  if ($Headless -or $script:SidecarDead) { return }
  if (-not $script:NodeExe) {
    try {
      $c = Get-Command node -ErrorAction SilentlyContinue
      if ($c -and $c.Source) { $script:NodeExe = $c.Source }
    } catch { }
  }
  if (-not $script:NodeExe) { $script:SidecarDead = $true; return }
  $sc = Join-Path $PSScriptRoot 'tps-sidecar.mjs'
  if (-not (Test-Path -LiteralPath $sc)) { $script:SidecarDead = $true; return }
  try {
    # 用 CreateNoWindow 而不是 Start-Process -WindowStyle Hidden：node 是控制台
    # 程序，后者会闪黑框。PS 5.1 没有 ProcessStartInfo.ArgumentList，手工拼引号。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:NodeExe
    $psi.Arguments = '"{0}" "{1}" "{2}" "{3}" 250' -f $sc, (Join-Path (Join-Path $ZCodeHome 'db') 'db.sqlite'), $SidecarSnap, $PID
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:SidecarProc = [System.Diagnostics.Process]::Start($psi)
  } catch {
    $script:SidecarProc = $null
  }
}

function Update-Sidecar {
  if ($script:SidecarDead) { return }
  # 快照年龄：sidecar 按 4Hz 覆盖写，3s 内算新鲜；文件缺失按无穷大处理。
  # Headless 下不启动 sidecar 进程，但快照照读——受控测试注入假快照用。
  $ageMs = [double]::PositiveInfinity
  try {
    if (Test-Path -LiteralPath $SidecarSnap) {
      $ageMs = ([DateTime]::Now - (Get-Item -LiteralPath $SidecarSnap).LastWriteTime).TotalMilliseconds
    }
  } catch { }
  if ($ageMs -lt 3000) {
    try {
      $snap = Get-Content -LiteralPath $SidecarSnap -Raw -Encoding UTF8 | ConvertFrom-Json
      $map = @{}
      if ($snap -and $snap.titles) {
        foreach ($p in $snap.titles.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
      }
      $script:TitleMap = $map
      # DESIGN.md §8 契约：sessions 数组（活跃会话 + 当前 message 分类型字节）。
      # 旧版快照没有该字段 → 空数组，估算与并列展示退回不可用。
      $list = @()
      if ($snap -and $snap.sessions) {
        foreach ($s in @($snap.sessions)) {
          $parts = $null
          if ($s.parts) {
            $parts = @{
              reasoning = [long]$s.parts.reasoning
              text      = [long]$s.parts.text
              other     = [long]$s.parts.other
            }
          }
          $list += @{
            id           = [string]$s.id
            title        = [string]$s.title
            lastActiveMs = [long]$s.lastActiveMs
            msgId        = [string]$s.msgId
            msgSeq       = $s.msgSeq
            parts        = $parts
          }
        }
      }
      $script:SidecarSessions = $list
      $script:SidecarFails = 0
    } catch { }   # 读到半截：沿用上一份快照（DESIGN.md §9）
    return
  }
  if ($Headless) { return }   # 无头/测试不管理 sidecar 进程
  $procAlive = $false
  try { $procAlive = ($script:SidecarProc -and -not $script:SidecarProc.HasExited) } catch { }
  if ($procAlive -and $ageMs -lt 10000) { return }   # 启动初期的空窗，等下一拍
  # 进程死了，或活着却 10s 无产出：杀掉重启；连续 3 次失败进入精简模式（DESIGN.md §9）
  try { if ($script:SidecarProc -and -not $script:SidecarProc.HasExited) { $script:SidecarProc.Kill() } } catch { }
  $script:SidecarProc = $null
  $script:SidecarFails++
  if ($script:SidecarFails -ge 3) { $script:SidecarDead = $true; return }
  Start-Sidecar
}

function Stop-Sidecar {
  try {
    if ($script:SidecarProc -and -not $script:SidecarProc.HasExited) { $script:SidecarProc.Kill() }
  } catch { }
  $script:SidecarProc = $null
}

# ------------------------------------------------------------------ 日志：判断当前会话

function Resolve-LogFile {
  if (-not (Test-Path -LiteralPath $LogDir)) { return '' }
  $f = Get-ChildItem -LiteralPath $LogDir -Filter 'zcode-*.jsonl' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if ($f) { return $f.FullName }
  return ''
}

function Update-DesiredSession {
  try {
    $path = Resolve-LogFile
    if (-not $path) { return }

    if ($path -ne $script:LogTail.path) {
      $script:LogTail.path = $path
      $script:LogTail.carry = ''
      $len = (Get-Item -LiteralPath $path).Length
      # 回看尾部即可：要的是「最近一次用户意图」，不重放整天的日志
      $script:LogTail.pos = [Math]::Max(0L, $len - $LogAttachLookbackBytes)
    }

    $len = (Get-Item -LiteralPath $path).Length
    if ($len -lt $script:LogTail.pos) {
      $script:LogTail.pos = 0L
      $script:LogTail.carry = ''
    }
    if ($len -le $script:LogTail.pos) { return }

    $buf = $null
    $read = 0
    $fs = New-Object System.IO.FileStream(
      $path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      [void]$fs.Seek($script:LogTail.pos, [System.IO.SeekOrigin]::Begin)
      $buf = New-Object byte[] ($len - $script:LogTail.pos)
      $read = $fs.Read($buf, 0, $buf.Length)
      $script:LogTail.pos += $read
    } finally {
      $fs.Dispose()
    }

    $text = $script:LogTail.carry + [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    $parts = $text -split "`n"
    $script:LogTail.carry = $parts[$parts.Length - 1]

    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
      $line = $parts[$i]
      if (-not $line) { continue }
      $m = [regex]::Match($line, '"event"\s*:\s*"([^"]+)"')
      if (-not $m.Success) { continue }
      # 在飞跟踪（L1，DESIGN.md §6）：started 与 completed 按 sessionId 配对，
      # completed 实测带 parentSpanId = started 的 spanId，作为兜底配对键。
      # completed 可能不带 sessionId，此时只清 '_'（v1 语义：视为当前跟踪请求的
      # 结束）——并发下绝不能因为它清掉别的会话的计时。子代理的请求不触发计时。
      # started 时间取日志行自己的 timestamp——刚启动回看历史日志时，不能把几十秒
      # 前的开始当成刚刚发生。
      if ($m.Groups[1].Value -eq 'model.request.started') {
        $ms = [regex]::Match($line, '"sessionId"\s*:\s*"(sess_[^"]+)"')
        if (-not $ms.Success -or $ms.Groups[1].Value -notlike 'sess_subagent_*') {
          $sid = ''
          if ($ms.Success) { $sid = $ms.Groups[1].Value }
          $at = [DateTime]::UtcNow
          $mt = [regex]::Match($line, '"timestamp"\s*:\s*"([^"]+)"')
          if ($mt.Success) {
            try {
              $at = [DateTimeOffset]::Parse(
                $mt.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
            } catch { }
          }
          $span = ''
          $mspan = [regex]::Match($line, '"spanId"\s*:\s*"([^"]+)"')
          if ($mspan.Success) { $span = $mspan.Groups[1].Value }
          $key = $sid
          if (-not $key) { $key = '_' }
          $script:ReqStarts[$key] = @{ utc = $at; span = $span }
          # L3 标定基线：请求开始时该会话当前 message 的字节（Add-Record 完成时配对）
          $base = $script:CalibBase[$key]
          if (-not $base) {
            $base = @{ b0r = -1L; b0x = -1L; msgId = ''; utc = $at }
            $cur = $null
            foreach ($ss in $script:SidecarSessions) { if ($ss.id -eq $sid) { $cur = $ss; break } }
            if ($cur -and $cur.parts) {
              $base.b0r = [long]$cur.parts.reasoning
              $base.b0x = [long]$cur.parts.text
              $base.msgId = [string]$cur.msgId
            }
            $script:CalibBase[$key] = $base
          }
        }
        continue
      }
      if ($m.Groups[1].Value -eq 'model.request.completed') {
        $ms = [regex]::Match($line, '"sessionId"\s*:\s*"(sess_[^"]+)"')
        $done = $false
        if ($ms.Success) {
          $sid = $ms.Groups[1].Value
          if ($script:ReqStarts.ContainsKey($sid)) { $script:ReqStarts.Remove($sid); $done = $true }
        }
        else {
          # completed.parentSpanId == started.spanId 的兜底配对（实测该字段在）
          $mp = [regex]::Match($line, '"parentSpanId"\s*:\s*"([^"]+)"')
          if ($mp.Success) {
            $hit = $null
            foreach ($k in @($script:ReqStarts.Keys)) {
              if ($k -ne '_' -and $script:ReqStarts[$k].span -eq $mp.Groups[1].Value) { $hit = $k; break }
            }
            if ($hit) { $script:ReqStarts.Remove($hit); $done = $true }
          }
          if (-not $done -and $script:ReqStarts.ContainsKey('_')) {
            $script:ReqStarts.Remove('_'); $done = $true
          }
        }
        continue
      }
      if ($IntentEvents -notcontains $m.Groups[1].Value) { continue }
      # 顶层 sessionId 在 context 之前，取第一个匹配
      $m = [regex]::Match($line, '"sessionId"\s*:\s*"(sess_[^"]+)"')
      if (-not $m.Success) { continue }
      $sid = $m.Groups[1].Value
      # 子代理会话不算「用户所在的会话」
      if ($sid -like 'sess_subagent_*') { continue }
      # 意图时间取日志行自己的 timestamp，而不是读取时刻：回看历史日志（刚启动时）
      # 不能因为「刚读到」就把几十分钟前的旧事件当成刚发生的意图。
      $at = [DateTime]::UtcNow
      $mt = [regex]::Match($line, '"timestamp"\s*:\s*"([^"]+)"')
      if ($mt.Success) {
        try {
          $at = [DateTimeOffset]::Parse(
            $mt.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
        } catch { }
      }
      # 回看/乱序时不接受比当前意图更旧的事件，避免旧事件把新意图顶掉
      if ($at -lt $script:IntentAtUtc) { continue }
      $script:DesiredSession = $sid
      $script:IntentAtUtc = $at
    }
  } catch {
    # 日志只是导航信号，读不到不影响主功能
  }
}

# ------------------------------------------------------------------ rollout：取数与算速率

function Get-RolloutFiles {
  if (-not (Test-Path -LiteralPath $RolloutDir)) { return @() }
  return @(Get-ChildItem -LiteralPath $RolloutDir -Filter 'model-io-*.jsonl' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notlike '*subagent*' })
}

function Resolve-TargetFile {
  # 1) 显式覆盖：手动钉死一个会话，供排查用
  if ($SessionId) {
    $sid = $SessionId
    if ($sid -notlike 'sess_*') { $sid = "sess_$sid" }
    $p = Join-Path $RolloutDir "model-io-$sid.jsonl"
    if (Test-Path -LiteralPath $p) {
      $script:Stats.source = 'override'
      return $p
    }
  }

  $files = Get-RolloutFiles
  if ($files.Count -eq 0) {
    $script:Stats.source = 'none'
    return ''
  }

  $newest = $files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if (-not $newest) { return '' }

  # 2) 用户意图优先：意图还在有效期内就无条件跟随它，别的会话写不写 rollout 都不参与判断。
  #    这里刻意不再有「意图会话的文件比最新写入落后 ≥30s 就否掉意图」的规则：
  #    并发时后台会话每完成一个请求就刷新自己的文件，而用户所在会话在思考期间不写文件，
  #    那条规则必然把显示让给后台会话（实测：切过去后显示别的会话长达 102s / 131s）。
  if ($script:DesiredSession) {
    $ageMs = ([DateTime]::UtcNow - $script:IntentAtUtc).TotalMilliseconds
    if ($ageMs -lt $IntentTtlMs) {
      $wantName = "model-io-$($script:DesiredSession).jsonl"
      $desired = $files | Where-Object { $_.Name -eq $wantName } | Select-Object -First 1
      if ($desired) {
        $script:Stats.source = 'intent'
        return $desired.FullName
      }
      # 意图会话还没有 rollout 文件：刚切过去/刚建会话，或运行时被回收后文件已删除
      # （实测 rollout 文件随会话运行时生灭）。如实显示「该会话暂无生成数据」，
      # 而不是拿别的会话的数字顶上——那正是「切了会话却显示别人的 TPS」的来源。
      $script:Stats.source = 'intent-wait'
      return ''
    }
  }

  # 3) 意图过期或没有意图：回退到最新写入的文件，带迟滞避免来回跳
  $script:Stats.source = 'mtime'
  $cur = $files | Where-Object { $_.FullName -eq $script:Tail.path } | Select-Object -First 1
  if ($cur) {
    $gapMs = ($newest.LastWriteTimeUtc - $cur.LastWriteTimeUtc).TotalMilliseconds
    if ($gapMs -lt $SwitchHysteresisMs) { return $cur.FullName }
  }
  return $newest.FullName
}

# 从 $From 向后找到第一个换行，返回其后的偏移，保证从行首开始读。
function Get-LineStartOffset {
  param([string]$Path, [long]$From)

  $len = (Get-Item -LiteralPath $Path).Length
  if ($From -le 0L) { return 0L }
  if ($From -ge $len) { return $len }

  $chunk = 65536
  $pos = $From
  $fs = New-Object System.IO.FileStream(
    $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    while ($pos -lt $len) {
      $n = [Math]::Min([long]$chunk, $len - $pos)
      $b = New-Object byte[] $n
      [void]$fs.Seek($pos, [System.IO.SeekOrigin]::Begin)
      $r = $fs.Read($b, 0, $n)
      if ($r -le 0) { break }
      for ($i = 0; $i -lt $r; $i++) {
        if ($b[$i] -eq 10) { return ($pos + $i + 1) }
      }
      $pos += $r
    }
  } finally {
    $fs.Dispose()
  }
  return $From
}

function Read-NewRecords {
  param([string]$Path)

  if (-not $Path) { return @() }
  if ($Path -ne $script:Tail.path) {
    # 换会话了：游标归零并清空统计，避免把上一个会话的数混进来。
    # source 是 Resolve-TargetFile 刚刚判定的，要带过来——否则切换那一拍的
    # status.json 会写成空 source，排查「为什么没跟着我切」时正好看到空值。
    $src = $script:Stats.source
    $script:Stats = New-Stats
    $script:Stats.target = $Path
    $script:Stats.source = $src
  }
  return @(Read-TailLines -Tail $script:Tail -Path $Path -Lookback $LookbackBytes)
}

# 通用 rollout 增量读取：首次接入从尾部 $Lookback 字节处行对齐起读，之后只读增量。
# 主游标（$script:Tail）与多行模式每会话的轻量游标共用（DESIGN.md §7.3）。
function Read-TailLines {
  param($Tail, [string]$Path, [long]$Lookback = 0L)

  $out = @()
  if (-not $Path) { return $out }

  if ($Path -ne $Tail.path) {
    $Tail.path = $Path
    $Tail.carry = ''
    $len = (Get-Item -LiteralPath $Path).Length
    $from = [Math]::Max(0L, $len - $Lookback)
    $Tail.pos = Get-LineStartOffset -Path $Path -From $from
  }

  $len = (Get-Item -LiteralPath $Path).Length
  if ($len -lt $Tail.pos) {
    # 文件被截断或轮转
    $Tail.pos = 0L
    $Tail.carry = ''
  }
  if ($len -le $Tail.pos) { return $out }

  $buf = $null
  $read = 0
  $fs = New-Object System.IO.FileStream(
    $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    [void]$fs.Seek($Tail.pos, [System.IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] ($len - $Tail.pos)
    $read = $fs.Read($buf, 0, $buf.Length)
    $Tail.pos += $read
  } finally {
    $fs.Dispose()
  }

  $text = $Tail.carry + [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
  $parts = $text -split "`n"
  $Tail.carry = $parts[$parts.Length - 1]

  for ($i = 0; $i -lt $parts.Length - 1; $i++) {
    $line = $parts[$i].Trim()
    if (-not $line) { continue }
    $out += $line
  }
  return $out
}

# 从一行 rollout 记录里提取需要的字段；不是 model_io 记录或缺 durationMs 时返回 $null。
function Parse-Record {
  param([string]$Line)

  if (-not $Line) { return $null }

  $len = $Line.Length
  $head = $Line
  if ($len -gt 512) { $head = $Line.Substring(0, 512) }
  $tail = $Line
  if ($len -gt 8000) { $tail = $Line.Substring($len - 8000) }

  $m = [regex]::Match($tail, '"type"\s*:\s*"model_io"')
  if (-not $m.Success) { return $null }

  $m = [regex]::Match($head, '"durationMs"\s*:\s*(\d+)')
  if (-not $m.Success) {
    $m = [regex]::Match($Line, '"durationMs"\s*:\s*(\d+)')
    if (-not $m.Success) { return $null }
  }
  $dur = [double]$m.Groups[1].Value

  $usage = [regex]::Match($tail, '"usage"\s*:\s*\{[^{}]*\}')
  if (-not $usage.Success -and $tail.Length -ne $len) {
    $usage = [regex]::Match($Line, '"usage"\s*:\s*\{[^{}]*\}')
  }

  $outTokens = 0
  $reasoning = 0
  if ($usage.Success) {
    $m = [regex]::Match($usage.Value, '"outputTokens"\s*:\s*(\d+)')
    if ($m.Success) { $outTokens = [int]$m.Groups[1].Value }
    $m = [regex]::Match($usage.Value, '"reasoningTokens"\s*:\s*(\d+)')
    if ($m.Success) { $reasoning = [int]$m.Groups[1].Value }
  }

  $sid = ''
  $m = [regex]::Match($tail, '"sessionId"\s*:\s*"([^"]*)"')
  if ($m.Success) { $sid = $m.Groups[1].Value }

  $tid = ''
  $m = [regex]::Match($tail, '"turnId"\s*:\s*"([^"]*)"')
  if ($m.Success) { $tid = $m.Groups[1].Value }

  $model = ''
  $m = [regex]::Match($head, '"modelId"\s*:\s*"([^"]*)"')
  if ($m.Success) { $model = $m.Groups[1].Value }

  # completedAt 在行首（与 durationMs 同排），用来区分「刚完成的请求」和
  # 「启动回看读到的历史记录」——只有前者参与 L3 标定
  $completedAt = $null
  $m = [regex]::Match($head, '"completedAt"\s*:\s*"([^"]+)"')
  if ($m.Success) {
    try {
      $completedAt = [DateTimeOffset]::Parse(
        $m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    } catch { }
  }

  return [ordered]@{
    durationMs      = $dur
    outputTokens    = $outTokens
    reasoningTokens = $reasoning
    sessionId       = $sid
    turnId          = $tid
    model           = $model
    completedAt     = $completedAt
  }
}

function Add-Record {
  param($r)

  if (-not $r) { return }
  if ($r.durationMs -le 0) { return }

  if ($r.turnId -and $r.turnId -ne $script:Stats.turnId) {
    $script:Stats.turnId = $r.turnId
    $script:Stats.turnOut = 0
    $script:Stats.turnMs = 0.0
  }

  $script:Stats.sessOut += $r.outputTokens
  $script:Stats.sessMs += $r.durationMs
  $script:Stats.turnOut += $r.outputTokens
  $script:Stats.turnMs += $r.durationMs
  $script:Stats.requests++
  $script:Stats.lastOut = $r.outputTokens
  $script:Stats.lastReasoning = $r.reasoningTokens
  $script:Stats.lastDurationMs = $r.durationMs
  $script:Stats.lastAtUtc = [DateTime]::UtcNow
  $script:Stats.lastTps = $r.outputTokens / ($r.durationMs / 1000.0)
  if ($null -eq $script:Stats.sessMaxTps -or $script:Stats.lastTps -gt $script:Stats.sessMaxTps) {
    $script:Stats.sessMaxTps = $script:Stats.lastTps
  }
  if ($r.model) { $script:Stats.model = $r.model }
  if ($r.sessionId) { $script:Stats.sessionId = $r.sessionId }

  Invoke-RecordCalib -r $r

  $spark = @($script:Stats.spark)
  $spark += [double]$script:Stats.lastTps
  if ($spark.Count -gt 40) { $spark = $spark[($spark.Count - 40)..($spark.Count - 1)] }
  $script:Stats.spark = $spark
}

function Update-Stats {
  try {
    Update-DesiredSession
    Update-Estimates
    Update-SessionTails
    Get-OverlayRows
    $target = Resolve-TargetFile
    if (-not $target) {
      if ($script:Stats.source -eq 'intent-wait') {
        # 用户意图指向的会话还没有 rollout 文件（刚切过去/刚建会话/运行时被回收）：
        # 清空数字、角标换成该会话、底部显示等待文案。这不是错误，不能走 error 字段；
        # 也绝不能退回显示别的会话的数字。
        $script:Stats = New-Stats
        $script:Stats.sessionId = $script:DesiredSession
        $script:Stats.source = 'intent-wait'
        $script:Stats.waiting = $true
        return
      }
      $script:Stats.error = $script:Str.noRollout
      return
    }
    $script:Stats.error = ''
    $script:Stats.waiting = $false
    $lines = Read-NewRecords -Path $target
    foreach ($line in $lines) {
      $rec = Parse-Record -Line $line
      if ($rec) { Add-Record -r $rec } else { $script:Stats.skipped++ }
    }
  } catch {
    $script:Stats.error = $_.Exception.Message
  }
}

function Get-TurnTps {
  if ($script:Stats.turnMs -gt 0) { return $script:Stats.turnOut / ($script:Stats.turnMs / 1000.0) }
  return $null
}

function Get-SessTps {
  if ($script:Stats.sessMs -gt 0) { return $script:Stats.sessOut / ($script:Stats.sessMs / 1000.0) }
  return $null
}

# ------------------------------------------------------------------ L3 在飞估算（DESIGN.md §6）
# 数据来自 sidecar 快照里当前 message 的 reasoning/text 字节。DB 落库是中位 3.5s
# 一次的跳跃补齐（§3.1），所以速率必须走滑动窗口，且窗口内落库不足 2 次不显示——
# 没有依据就不出数字（FR1-4）。换算系数 k 由已完成的请求按 usage 真值标定。

function Get-CalibK {
  param([string]$Type)
  $c = $script:Calib[$Type]
  if ($c -and $c.samples.Count -gt 0) {
    $tok = 0.0
    $bytes = 0.0
    foreach ($s in $c.samples) { $tok += $s.tok; $bytes += $s.bytes }
    if ($bytes -gt 0) { return $tok / $bytes }
  }
  return $script:CalibDefaultK
}

function Add-CalibSample {
  param([string]$Type, [double]$Tok, [double]$Bytes)
  if ($Tok -le 0 -or $Bytes -le 0) { return }
  $c = $script:Calib[$Type]
  $c.samples += @{ tok = $Tok; bytes = $Bytes }
  if ($c.samples.Count -gt $script:CalibMaxSamples) {
    $c.samples = @($c.samples | Select-Object -Skip ($c.samples.Count - $script:CalibMaxSamples))
  }
}

function Test-SessionInFlight {
  param([string]$SessionId)
  # '_' 承接无 sessionId 的 started：视为当前显示会话在飞（v1 语义）
  if ($script:ReqStarts.ContainsKey('_')) { return $true }
  if ($SessionId -and $script:ReqStarts.ContainsKey($SessionId)) { return $true }
  return $false
}

function Get-InFlightElapsed {
  param([string]$SessionId)
  # 返回该会话在飞已进行的秒数；不在飞返回 $null。优先精确匹配本会话的请求
  $e = $null
  if ($SessionId -and $script:ReqStarts.ContainsKey($SessionId)) { $e = $script:ReqStarts[$SessionId] }
  elseif ($script:ReqStarts.ContainsKey('_')) { $e = $script:ReqStarts['_'] }
  if (-not $e) { return $null }
  return ([DateTime]::UtcNow - $e.utc).TotalSeconds
}

function Update-Estimates {
  # 每拍调用（在 Update-DesiredSession 之后）：给每个在飞会话推一个字节采样。
  # 顺带清理：completed 丢失（回看截断/日志轮转）的在飞条目按 10 分钟兜底删除，
  # 未配对成功的标定基线同理。
  try {
    $nowUtc = [DateTime]::UtcNow
    foreach ($key in @($script:ReqStarts.Keys)) {
      if (($nowUtc - $script:ReqStarts[$key].utc).TotalSeconds -gt 600) { $script:ReqStarts.Remove($key) }
    }
    foreach ($key in @($script:CalibBase.Keys)) {
      if (($nowUtc - $script:CalibBase[$key].utc).TotalSeconds -gt 600) { $script:CalibBase.Remove($key) }
    }
    foreach ($key in @($script:ReqStarts.Keys)) {
      if ($key -eq '_') { continue }
      $cur = $null
      foreach ($ss in $script:SidecarSessions) { if ($ss.id -eq $key) { $cur = $ss; break } }
      if (-not $cur -or -not $cur.parts) { continue }
      $win = $script:EstimWin[$key]
      if (-not $win -or $win.msgId -ne [string]$cur.msgId) {
        # 换了 message（新请求开始写新的 assistant message）：字节从零起算，
        # 跨 message 的字节数不可比，窗口重开
        $win = @{ samples = @(); msgId = [string]$cur.msgId }
        $script:EstimWin[$key] = $win
      }
      $win.samples += @{
        t = $nowUtc
        r = [long]$cur.parts.reasoning
        x = [long]$cur.parts.text
      }
      $cutoff = $nowUtc.AddMilliseconds(-$script:EstimWinMs)
      while ($win.samples.Count -gt 0 -and $win.samples[0].t -lt $cutoff) {
        $win.samples = @($win.samples | Select-Object -Skip 1)
      }
    }
    # 不再在飞的会话窗口随手清掉，不积累
    foreach ($sid in @($script:EstimWin.Keys)) {
      if (-not $script:ReqStarts.ContainsKey($sid)) { $script:EstimWin.Remove($sid) }
    }
  } catch { }
}

function Get-EstimTps {
  param([string]$SessionId)
  # 5 秒滑动窗口的字节增量 × k；窗口内落库不足 2 次或取不到增量时返回 $null
  $win = $script:EstimWin[$SessionId]
  if (-not $win -or $win.samples.Count -lt 2) { return $null }
  $samples = $win.samples
  $changes = 0
  for ($i = 1; $i -lt $samples.Count; $i++) {
    if (($samples[$i].r + $samples[$i].x) -ne ($samples[$i - 1].r + $samples[$i - 1].x)) { $changes++ }
  }
  if ($changes -lt 2) { return $null }
  $first = $samples[0]
  $last = $samples[$samples.Count - 1]
  $dt = ($last.t - $first.t).TotalSeconds
  if ($dt -le 0) { return $null }
  # 字节理论上只增；窗口重开/异常快照的防御性钳制
  $dR = [Math]::Max(0L, ([long]$last.r - [long]$first.r))
  $dX = [Math]::Max(0L, ([long]$last.x - [long]$first.x))
  if (($dR + $dX) -le 0) { return $null }
  $rate = $dR * (Get-CalibK -Type 'reasoning') + $dX * (Get-CalibK -Type 'text')
  $rate = $rate / $dt
  if ($rate -le 0) { return $null }
  return $rate
}

function Invoke-RecordCalib {
  param($r)
  # 请求完成落盘（Add-Record）时，用 usage 真值修正换算系数（DESIGN.md §6 L2）。
  # 只在主 Stats 路径调用：并发行各自的 tail 不标定，避免同一请求重复配对。
  $sid = $script:Stats.sessionId
  if (-not $sid) { return }
  # 只认刚完成的请求：启动回看会读到历史记录，它们的字节早就与基线对不上，
  # 若让它们消费基线，真实的在飞请求完成时反而无基线可配
  if ($null -eq $r.completedAt -or
    ([DateTime]::UtcNow - $r.completedAt).TotalSeconds -gt 30) { return }
  $base = $script:CalibBase[$sid]
  if (-not $base -or $base.b0r -lt 0) { return }
  $cur = $null
  foreach ($ss in $script:SidecarSessions) { if ($ss.id -eq $sid) { $cur = $ss; break } }
  if (-not $cur -or -not $cur.parts) { return }
  # 基线与完成时必须是同一个 message，否则这轮字节归不到这次请求
  if ([string]$cur.msgId -ne [string]$base.msgId) { return }
  $dR = [long]$cur.parts.reasoning - [long]$base.b0r
  $dX = [long]$cur.parts.text - [long]$base.b0x
  # 小样本噪声大：增量计数低于阈值不标定。基线只在真正配对成功后才消费——
  # 启动回读的历史记录（字节与基线无增量）不构成有效配对，不能把基线吃掉，
  # 否则真实的在飞请求完成时反而无基线可配（600s 兜底清理防残留）。
  $added = $false
  if ($dR -ge 300) {
    Add-CalibSample -Type 'reasoning' -Tok ([double]$r.reasoningTokens) -Bytes ([double]$dR)
    $added = $true
  }
  if ($dX -ge 300) {
    # outputTokens 含工具调用 token 而 tool part 不参与换算，text 类系数会略偏高；
    # A4（±20%）门槛下可接受，DESIGN.md §12 已记录
    Add-CalibSample -Type 'text' -Tok ([double]($r.outputTokens - $r.reasoningTokens)) -Bytes ([double]$dX)
    $added = $true
  }
  if ($added) { $script:CalibBase.Remove($sid) }
}

# ------------------------------------------------------------------ 多会话并列数据层（DESIGN.md §7.2/§7.3）
# 「猜一个」改成「全都列出来」：活跃会话各行并列、在飞行置顶高亮、上限 5 行折叠。
# 单会话/无 sidecar 时退回 v1 紧凑卡片。每行的速率来自各会话自己的 rollout tail。

$script:ActiveWindowMs = 300000    # 活跃窗口：session.time_updated 在最近 5 分钟内
$script:MaxRows = 5                # 行数上限，超出折叠为 +N
$script:SessionTails = @{}         # sessionId → 轻量游标与统计（非主目标的活跃会话）
$script:OverlayRows = @()          # 每拍组装的行数据（渲染与 status.json 共用）
$script:MoreRows = 0               # 被折叠的行数

function Get-ActiveSessions {
  $out = @()
  $cutoff = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $script:ActiveWindowMs
  foreach ($s in $script:SidecarSessions) {
    if ($s.id -like 'sess_subagent_*') { continue }   # sidecar 已滤，双保险
    if ($s.lastActiveMs -lt $cutoff) { continue }
    $out += $s
  }
  return $out
}

function Update-SessionTails {
  # 活跃会话各自的 rollout tail：多行模式下空闲行的 L2 真值来源（§7.3）。
  # 主 Stats 会话照旧走单游标，这里只管其余行。文件随会话运行时生灭：
  # 消失时重置游标与统计，不残留旧数字。
  try {
    $keep = @{}
    foreach ($s in @(Get-ActiveSessions)) {
      $sid = $s.id
      if ($sid -eq $script:Stats.sessionId) { continue }   # 主会话的行用主 Stats，不重复 tail
      $keep[$sid] = $true
      $t = $script:SessionTails[$sid]
      if (-not $t) {
        $t = @{ path = ''; pos = 0L; carry = ''; lastTps = $null; lastAtUtc = $null; sessOut = 0; sessMs = 0.0; requests = 0; model = '' }
        $script:SessionTails[$sid] = $t
      }
      $path = Join-Path $RolloutDir ("model-io-$sid.jsonl")
      if (-not (Test-Path -LiteralPath $path)) {
        $t.path = ''
        $t.pos = 0L
        $t.carry = ''
        $t.lastTps = $null
        $t.lastAtUtc = $null
        continue
      }
      foreach ($line in @(Read-TailLines -Tail $t -Path $path -Lookback $LookbackBytes)) {
        $rec = Parse-Record -Line $line
        if (-not $rec -or $rec.durationMs -le 0) { continue }
        $t.lastTps = $rec.outputTokens / ($rec.durationMs / 1000.0)
        $t.lastAtUtc = [DateTime]::UtcNow
        $t.sessOut += $rec.outputTokens
        $t.sessMs += $rec.durationMs
        $t.requests++
        if ($rec.model) { $t.model = $rec.model }
      }
    }
    foreach ($sid in @($script:SessionTails.Keys)) {
      if (-not $keep.ContainsKey($sid)) { $script:SessionTails.Remove($sid) }
    }
  } catch { }
}

function Get-OverlayRows {
  # 行数据：在飞行置顶（后开始的在前），空闲行按 lastActiveMs 降序；超出 $MaxRows 折叠。
  # 主目标会话保证在场（哪怕 sidecar 活跃窗口没罩住它）——显示目标可核对是 FR2-3。
  $script:OverlayRows = @()
  $script:MoreRows = 0
  try {
    $mainSid = $script:Stats.sessionId
    if (-not $mainSid -and $script:DesiredSession) { $mainSid = $script:DesiredSession }
    $cands = @()
    $hasMain = $false
    foreach ($s in @(Get-ActiveSessions)) {
      if ($s.id -eq $mainSid) { $hasMain = $true }
      $cands += $s
    }
    if ($mainSid -and -not $hasMain) {
      $t = ''
      try { $t = [string]$script:TitleMap[$mainSid] } catch { }
      $cands += @{ id = $mainSid; title = $t; lastActiveMs = 0; msgId = ''; parts = $null }
    }

    $rows = @()
    foreach ($s in $cands) {
      $sid = [string]$s.id
      if (-not $sid) { continue }
      $tps = $null
      $tpsAt = $null
      $out = 0
      if ($sid -eq $script:Stats.sessionId) {
        $tps = $script:Stats.lastTps
        $tpsAt = $script:Stats.lastAtUtc
        $out = $script:Stats.sessOut
      }
      else {
        $t = $script:SessionTails[$sid]
        if ($t) { $tps = $t.lastTps; $tpsAt = $t.lastAtUtc; $out = $t.sessOut }
      }
      $inFl = Test-SessionInFlight -SessionId $sid
      $elapsed = $null
      $estim = $null
      if ($inFl) {
        $elapsed = Get-InFlightElapsed -SessionId $sid
        $estim = Get-EstimTps -SessionId $sid
      }
      $title = [string]$s.title
      if (-not $title) {
        try { $title = [string]$script:TitleMap[$sid] } catch { }
      }
      $rows += @{
        sid          = $sid
        title        = $title
        lastActiveMs = [long]$s.lastActiveMs
        tps          = $tps
        tpsAt        = $tpsAt
        out          = $out
        inFlight     = $inFl
        elapsed      = $elapsed
        estim        = $estim
      }
    }

    $inFlightRows = @($rows | Where-Object { $_.inFlight } | Sort-Object { $_.elapsed })
    $idleRows = @($rows | Where-Object { -not $_.inFlight } | Sort-Object lastActiveMs -Descending)
    $ordered = @($inFlightRows) + @($idleRows)
    if ($ordered.Count -gt $script:MaxRows) {
      $script:MoreRows = $ordered.Count - $script:MaxRows
      $ordered = @($ordered[0..($script:MaxRows - 1)])
    }
    $script:OverlayRows = $ordered
  } catch {
    $script:OverlayRows = @()
    $script:MoreRows = 0
  }
}

function Get-ShortSessionId {
  # 会话短码：FR1-5 要求显示目标可核对。标题 sidecar（tps-sidecar.mjs）取到
  # 人能读懂的标题时显示标题，这里只在 sidecar 不可用（无 node / 连续失败）时兜底。
  param([string]$Sid = '')
  if (-not $Sid) { $Sid = $script:Stats.sessionId }
  if (-not $Sid) { return '' }
  $Sid = $Sid -replace '^sess_', ''
  if ($Sid.Length -gt 8) { return $Sid.Substring(0, 8) }
  return $Sid
}

function Get-SessionTitle {
  # 当前显示会话的标题（sidecar 快照）。取不到返回空串，由调用方回退 id 短码。
  $sid = $script:Stats.sessionId
  if (-not $sid) { return '' }
  $t = $null
  try { $t = $script:TitleMap[$sid] } catch { return '' }
  if ($t) { return [string]$t }
  return ''
}

function Write-Status {
  # status.json 只是排查用的旁路产物：写不进去绝不能影响监控本身，
  # 所以整个函数吞掉异常。
  try {
    $lastAt = $null
    if ($script:Stats.lastAtUtc) { $lastAt = $script:Stats.lastAtUtc.ToString('o') }
    # 意图的时间戳与剩余有效期：排查「显示为什么没跟着我切」时先看这两个
    $intentAt = $null
    $intentAgeMs = $null
    if ($script:IntentAtUtc -gt [DateTime]::MinValue) {
      $intentAt = $script:IntentAtUtc.ToString('o')
      $intentAgeMs = [int](([DateTime]::UtcNow - $script:IntentAtUtc).TotalMilliseconds)
    }
    $sidecarState = 'off'
    if (-not $Headless) {
      if ($script:SidecarDead) { $sidecarState = 'dead' }
      else { $sidecarState = 'ok' }
    }
    $snapshot = [ordered]@{
      target              = $script:Stats.target
      source              = $script:Stats.source
      zcodeWin            = $script:ZCodeState
      pluginRoot          = $script:PluginRoot
      desiredSession      = $script:DesiredSession
      intentAtUtc         = $intentAt
      intentAgeMs         = $intentAgeMs
      intentTtlMs         = $IntentTtlMs
      sidecar             = $sidecarState
      inFlight            = (Test-SessionInFlight -SessionId $script:Stats.sessionId)
      inFlightElapsedSec  = (Get-InFlightElapsed -SessionId $script:Stats.sessionId)
      estimTps            = (Get-EstimTps -SessionId $script:Stats.sessionId)
      calibReasoningK     = (Get-CalibK -Type 'reasoning')
      calibTextK          = (Get-CalibK -Type 'text')
      calibReasoningN     = $script:Calib.reasoning.samples.Count
      calibTextN          = $script:Calib.text.samples.Count
      activeSessions      = @($script:SidecarSessions).Count
      rows                = @($script:OverlayRows | ForEach-Object {
          [ordered]@{
            sessionId  = $_.sid
            title      = $_.title
            tps        = $_.tps
            inFlight   = $_.inFlight
            elapsedSec = $_.elapsed
            estimTps   = $_.estim
          }
        })
      moreRows            = $script:MoreRows
      model               = $script:Stats.model
      sessionId           = $script:Stats.sessionId
      sessionTitle        = (Get-SessionTitle)
      turnId              = $script:Stats.turnId
      requests            = $script:Stats.requests
      skipped             = $script:Stats.skipped
      waiting             = $script:Stats.waiting
      lastTps             = $script:Stats.lastTps
      lastOutputTokens    = $script:Stats.lastOut
      lastReasoningTokens = $script:Stats.lastReasoning
      lastDurationMs      = $script:Stats.lastDurationMs
      lastAtUtc           = $lastAt
      turnTps             = (Get-TurnTps)
      turnOutputTokens    = $script:Stats.turnOut
      sessionTps          = (Get-SessTps)
      sessionMaxTps       = $script:Stats.sessMaxTps
      sessionOutputTokens = $script:Stats.sessOut
      error               = $script:Stats.error
      writtenAtUtc        = [DateTime]::UtcNow.ToString('o')
    }
    if (-not (Test-Path -LiteralPath $StateDir)) {
      [void](New-Item -ItemType Directory -Path $StateDir -Force)
    }
    $json = $snapshot | ConvertTo-Json -Depth 4
    # 先写临时文件再覆盖过去。用 File::Copy 而不是 Move-Item -Force：
    # Move-Item 覆盖时需要目标文件的 DELETE 权限，别的进程正在读 status.json 时
    # 会抛 IOException；File::Copy 只写，不需要删除权限。
    $tmp = "$StatusFile.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::Copy($tmp, $StatusFile, $true)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  } catch {
  }
}

# ------------------------------------------------------------------ 单实例

if (-not $Headless) {
  $createdNew = $false
  $script:Mutex = [System.Threading.Mutex]::new($true, 'Local\ZCodeTpsMonitor', [ref]$createdNew)
  if (-not $createdNew) {
    # 已经有一个监控在跑，交给它
    exit 0
  }
}

# ------------------------------------------------------------------ 无头自检

if ($Headless) {
  $deadline = [DateTime]::MaxValue
  if ($Seconds -gt 0) { $deadline = (Get-Date).AddSeconds($Seconds) }
  while ((Get-Date) -lt $deadline) {
    Update-Sidecar   # 无头不启动 sidecar，但读快照：受控测试注入假快照用
    Update-Stats
    Write-Status
    Start-Sleep -Milliseconds 400
  }
  Update-Sidecar
  Update-Stats
  Write-Status
  exit 0
}

# ------------------------------------------------------------------ 界面

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# DPI 感知必须在创建任何窗口之前设置。否则 Windows 会把整个窗口当位图整体放大，
# 在 200% 缩放下字会糊成一片——这是「数字非常模糊」的根因。
try {
  Add-Type -Namespace ZCodeNative -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int value);
'@
  $ok = [ZCodeNative.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4))   # PER_MONITOR_AWARE_V2
  if (-not $ok) { [void][ZCodeNative.Dpi]::SetProcessDPIAware() }
} catch {
  try { [void][ZCodeNative.Dpi]::SetProcessDPIAware() } catch { }
}

[void][System.Windows.Forms.Application]::EnableVisualStyles()

# 布局按 96 DPI 设计，实际按屏幕缩放因子放大；字号用 pt，GDI+ 会自己按 DPI 放大。
$script:Scale = 1.0
try {
  $screenGfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
  if ($screenGfx.DpiX -gt 0) { $script:Scale = $screenGfx.DpiX / 96.0 }
  $screenGfx.Dispose()
} catch { }
if ($script:Scale -lt 1.0) { $script:Scale = 1.0 }
if ($script:Scale -gt 4.0) { $script:Scale = 4.0 }

function Px {
  param([double]$v)
  return [single]($v * $script:Scale)
}

$W = [int](Px 216)
$H = [int](Px 140)

# 多行模式（DESIGN.md §7.2）尺寸：宽一点给标题留位置，高度随行数自适应；
# 单会话/无 sidecar 时退回 v1 紧凑卡片（$W×$H 不变）
$script:SingleW = $W
$script:SingleH = $H
$script:MultiW = [int](Px 300)
$script:MultiHeaderH = [int](Px 24)
$script:RowHIdle = [int](Px 26)
$script:RowHActive = [int](Px 42)
$script:MultiPadB = [int](Px 8)
$script:MultiMode = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ZCode TPS'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.ClientSize = New-Object System.Drawing.Size($W, $H)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(26, 29, 34)   # surface #1A1D22（VISUAL.md 3.1）
$form.Opacity = $Opacity

$dbProp = $form.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
if ($dbProp) { $dbProp.SetValue($form, $true) }

# 圆角（单卡/多行切换会重建窗口尺寸，Region 要跟着重画）
function Set-OverlayRegion {
  param([int]$w, [int]$h)
  $rad = Px 6
  $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
  $gp.AddArc(0, 0, $rad, $rad, 180, 90)
  $gp.AddArc(($w - $rad), 0, $rad, $rad, 270, 90)
  $gp.AddArc(($w - $rad), ($h - $rad), $rad, $rad, 0, 90)
  $gp.AddArc(0, ($h - $rad), $rad, $rad, 90, 90)
  $gp.CloseFigure()
  $old = $form.Region
  $form.Region = New-Object System.Drawing.Region($gp)
  if ($old) { $old.Dispose() }
}
Set-OverlayRegion -w $W -h $H

# 单卡 ↔ 多行切换：只在实际变化时动 ClientSize（每拍调用，避免布局抖动）
function Update-OverlayShape {
  param([bool]$Multi, [int]$VisualRows)
  $w = $script:SingleW
  $h = $script:SingleH
  if ($Multi) {
    $w = $script:MultiW
    $h = $script:MultiHeaderH + $script:MultiPadB
    for ($i = 0; $i -lt $VisualRows; $i++) {
      if ($script:OverlayRows[$i] -and $script:OverlayRows[$i].inFlight) { $h += $script:RowHActive }
      else { $h += $script:RowHIdle }
    }
  }
  if ($script:MultiMode -ne $Multi -or $form.ClientSize.Width -ne $w -or $form.ClientSize.Height -ne $h) {
    $script:MultiMode = $Multi
    $form.ClientSize = New-Object System.Drawing.Size($w, $h)
    Set-OverlayRegion -w $w -h $h
    # 变大后可能出屏：钳回虚拟屏
    try {
      $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
      $form.Location = New-Object System.Drawing.Point(
        [Math]::Max($vs.Left, [Math]::Min($form.Left, $vs.Right - $w)),
        [Math]::Max($vs.Top, [Math]::Min($form.Top, $vs.Bottom - $h)))
    } catch { }
  }
}

# 位置：优先上次，其次右下角
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$px = $vs.Right - $W - [int](Px 24)
$py = $vs.Bottom - $H - [int](Px 64)
if (Test-Path -LiteralPath $PosFile) {
  try {
    $parts = (Get-Content -LiteralPath $PosFile -Raw).Trim() -split ','
    if ($parts.Count -eq 2) { $px = [int]$parts[0]; $py = [int]$parts[1] }
  } catch { }
}
$px = [Math]::Max($vs.Left, [Math]::Min($px, $vs.Right - $W))
$py = [Math]::Max($vs.Top, [Math]::Min($py, $vs.Bottom - $H))
$form.Location = New-Object System.Drawing.Point($px, $py)

# 主数字用等宽字体：数字每 400ms 刷新一次，比例字宽会让数字和后面的单位左右跳。
# GDI+ 不支持 OpenType 的 tabular figures，等宽是拿到表格数字的唯一途径；
# 优先 Cascadia Mono（Windows Terminal 自带），没有则回退 Consolas。
$heroFamily = 'Consolas'
$heroStyle = [System.Drawing.FontStyle]::Bold
try {
  $installed = [System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name }
  foreach ($cand in @('Cascadia Mono SemiBold', 'Cascadia Mono', 'Cascadia Code')) {
    if ($installed -contains $cand) {
      $heroFamily = $cand
      # SemiBold 是独立家族名，再叠 Bold 会过重
      if ($cand -like '*SemiBold') { $heroStyle = [System.Drawing.FontStyle]::Regular }
      break
    }
  }
} catch { }

$script:Fonts = @{
  hero     = New-Object System.Drawing.Font($heroFamily, 30, $heroStyle)
  unit     = New-Object System.Drawing.Font('Segoe UI', 8.5)
  stat     = New-Object System.Drawing.Font('Segoe UI', 8)
  rowTitle = New-Object System.Drawing.Font('Segoe UI', 8.5)          # 多行模式会话标题（VISUAL.md §3.2）
  rowNum   = New-Object System.Drawing.Font($heroFamily, 9)           # 多行模式行内速率（等宽右对齐可扫读）
}
# 色彩只编码状态：数字只有白/灰，彩色仅在表达状态时出现，同一时刻最多一种彩
# 色在场（VISUAL.md 3.1）
$script:Brushes = @{
  ink     = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(242, 244, 247))   # 在飞主数字
  sub     = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(154, 161, 171))   # 单位/元信息/空闲主数字
  faint   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(92, 100, 112))    # 历史柱/次要元信息
  live    = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(52, 211, 153))    # 在飞状态点 + 最新柱
  estim   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(229, 181, 103))   # 估算速率的 ≈（v2 L3，DESIGN.md §6）
  error   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(229, 72, 77))     # 错误状态点与错误文案
  idleDot = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(74, 80, 88))      # 空闲状态点
  rowHi   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(35, 40, 48))       # 多行模式在飞行高亮条（surface 提亮一档）
}
$script:Pens = @{
  track = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(38, 43, 50)), 1
}

function Save-Pos {
  try {
    # 毒丸清理后不再回写：卸载要的是状态文件消失，不是换个位置重建
    if ($script:TearDown) { return }
    if (-not (Test-Path -LiteralPath $StateDir)) {
      [void](New-Item -ItemType Directory -Path $StateDir -Force)
    }
    [System.IO.File]::WriteAllText($PosFile, "$($form.Left),$($form.Top)")
  } catch { }
}

# 只设 Form.TopMost 不足以保证置顶：实测窗口建出来时 WS_EX_TOPMOST 仍为假，
# 于是会被普通窗口（浏览器等）盖住。这里直接断言并周期性自愈。
function Assert-TopMost {
  try {
    if (-not $form.IsHandleCreated) { return }
    # 必须「关掉再打开」：Form.TopMost 的 setter 在值没变时是空操作，而我们在构造时
    # 已经把它设成 true 了，所以再设一次 true 不会让 WinForms 重新应用。关一次再打开
    # 才会真正走一遍置顶。
    # 注意：不能拿 GetWindowLong 读 WS_EX_TOPMOST 当开关——实测该位为假时窗口确实被
    # 盖住，但 SetWindowPos(HWND_TOPMOST) 调用返回成功却读不回该位，用位做判断会让
    # 断言永远被跳过。所以这里无条件执行。
    $form.TopMost = $false
    $form.TopMost = $true
    # HWND_TOPMOST=-1, SWP_NOSIZE|SWP_NOMOVE|SWP_NOACTIVATE|SWP_SHOWWINDOW
    [void][ZCodeNative.Dpi]::SetWindowPos($form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x0053)
  } catch { }
}

# ------------------------------------------------------------------ 跟随 ZCode 主窗口

function Find-ZCodeWindow {
  try {
    # 不能用 FindWindow 按标题搜：ZCode 是 Electron 窗口（类 Chrome_WidgetWin_1），
    # 实测 FindWindow/FindWindowEx 都搜不到它，只有 EnumWindows 能枚举到。
    $script:ZCodeFound = [IntPtr]::Zero
    $cb = [ZCodeNative.Dpi+EnumWindowsProc]{
      param($h, $l)
      $sb = New-Object System.Text.StringBuilder 64
      [void][ZCodeNative.Dpi]::GetWindowText($h, $sb, 64)
      if ($sb.ToString() -ne $script:Cfg.windowTitle) { return $true }  # 标题先过滤，命中才查进程（贵）
      [uint32]$p = 0
      [void][ZCodeNative.Dpi]::GetWindowThreadProcessId($h, [ref]$p)
      $proc = Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue
      if ($proc -and $proc.ProcessName -eq $script:Cfg.windowProcess -and [ZCodeNative.Dpi]::IsWindowVisible($h)) {
        $script:ZCodeFound = $h
        return $false                                       # 找到即停
      }
      return $true
    }
    $script:EnumWndDelegate = $cb                           # 持住引用，防 EnumWindows 回调期间被回收
    [void][ZCodeNative.Dpi]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:ZCodeFound
  } catch {
    return [IntPtr]::Zero
  }
}

# ZCode 关闭 → 小窗退出；最小化/窗口隐藏 → 小窗收起；不在前台 → 小窗隐藏；回到前台 → 恢复显示。
# 从未找到过 ZCode 窗口（如手动裸跑脚本）时不做任何动作，避免误关。
function Update-ZCodeFollow {
  try {
    $h = $script:ZCodeHwnd
    if ($h -eq [IntPtr]::Zero -or -not [ZCodeNative.Dpi]::IsWindow($h)) {
      $h = Find-ZCodeWindow
      if ($h -ne [IntPtr]::Zero) {
        $script:ZCodeHwnd = $h
      }
      elseif ($script:ZCodeSeen) {
        # 之前找到过，现在句柄失效且重找无果 → ZCode 窗口已关闭
        $script:ZCodeState = 'closed'
        $form.Close()
        return
      }
      else {
        return
      }
    }
    $script:ZCodeSeen = $true
    if ([ZCodeNative.Dpi]::IsIconic($h) -or -not [ZCodeNative.Dpi]::IsWindowVisible($h)) {
      $script:ZCodeState = 'minimized'
      if ($form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
      }
      return
    }
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
      $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
      Assert-TopMost
    }
    # 前台判定：ZCode 主窗口自身，或同一进程的其他顶层窗口（如弹出的对话框）都算在前台
    $fg = [ZCodeNative.Dpi]::GetForegroundWindow()
    $isFg = ($fg -eq $h)
    if (-not $isFg -and $fg -ne [IntPtr]::Zero) {
      [uint32]$fp = 0
      [void][ZCodeNative.Dpi]::GetWindowThreadProcessId($fg, [ref]$fp)
      $fgProc = Get-Process -Id ([int]$fp) -ErrorAction SilentlyContinue
      if ($fgProc -and $fgProc.ProcessName -eq $script:Cfg.windowProcess) { $isFg = $true }
    }
    if ($isFg) {
      $script:ZCodeState = 'normal'
      if (-not $form.Visible) { $form.Show() }
    }
    elseif ($script:Cfg.followForeground -and -not $script:Drag) {
      # ZCode 不在前台：隐藏小窗（config.followForeground 可关）。拖动进行中暂缓一轮。
      $script:ZCodeState = 'hidden'
      if ($form.Visible) { $form.Hide() }
    }
  } catch { }
}

function Draw-Right {
  # 右对齐画一行小字：$rightX 是右边缘
  param($g, $text, $font, $brush, [single]$rightX, [single]$y)
  $w = $g.MeasureString($text, $font).Width
  $g.DrawString($text, $font, $brush, ($rightX - $w), $y)
}

function Draw-MultiRows {
  # 多行并列（DESIGN.md §7.2）：头部 + 每活跃会话一行，在飞行置顶并带高亮条与计时，
  # 空闲行单行；速率列右对齐（估算 ≈ 琥珀、在飞真值亮白、空闲真值灰、无数据 —）。
  param($g)

  $rows = @($script:OverlayRows)
  $anyInFlight = $false
  foreach ($r in $rows) { if ($r.inFlight) { $anyInFlight = $true } }
  $hasError = [bool]$script:Stats.error

  # ---- 头部：全局状态点 + 窗口名 + × ----
  $dotBrush = $script:Brushes.idleDot
  if ($hasError) { $dotBrush = $script:Brushes.error }
  elseif ($anyInFlight) { $dotBrush = $script:Brushes.live }
  $g.FillEllipse($dotBrush, (Px 12), (Px 9), (Px 7), (Px 7))
  $g.DrawString($script:Str.header, $script:Fonts.stat, $script:Brushes.sub, (Px 26), (Px 5))
  if ($script:Hovered) {
    $g.DrawString('×', $script:Fonts.unit, $script:Brushes.sub, ($script:MultiW - (Px 20)), (Px 4))
  }

  # ---- 行区 ----
  $y = [single]$script:MultiHeaderH
  $i = 0
  foreach ($r in $rows) {
    $i++
    $rowH = $script:RowHIdle
    if ($r.inFlight) {
      $rowH = $script:RowHActive
      $g.FillRectangle($script:Brushes.rowHi, [single](Px 6), ($y - [single](Px 2)),
        [single]($script:MultiW - (Px 12)), [single]($rowH - (Px 3)))
    }
    # 速率列（右对齐）：先定位，标题的可用宽度要让位给它
    $rateText = '—'
    $rateBrush = $script:Brushes.faint
    if ($null -ne $r.estim) {
      $rateText = '≈{0:N0}' -f [double]$r.estim
      $rateBrush = $script:Brushes.estim
    }
    elseif ($null -ne $r.tps) {
      $rateText = '{0:N1}' -f [double]$r.tps
      if ($r.inFlight) { $rateBrush = $script:Brushes.ink }
      else { $rateBrush = $script:Brushes.sub }
    }
    $rateSize = $g.MeasureString($rateText, $script:Fonts.rowNum)
    $unitSize = $g.MeasureString($script:Str.unit, $script:Fonts.unit)
    $unitRight = [single]$script:MultiW - (Px 12)
    $rateRight = $unitRight - $unitSize.Width - (Px 2)
    $g.DrawString($rateText, $script:Fonts.rowNum, $rateBrush, ($rateRight - $rateSize.Width), ($y + (Px 1)))
    $g.DrawString($script:Str.unit, $script:Fonts.unit, $script:Brushes.faint, ($unitRight - $unitSize.Width), ($y + (Px 4)))

    # 标题（截断加省略号；取不到标题时回退短码）
    $title = [string]$r.title
    if (-not $title) { $title = 'id ' + (Get-ShortSessionId -Sid $r.sid) }
    $titleBrush = $script:Brushes.sub
    if ($r.inFlight) { $titleBrush = $script:Brushes.ink }
    $cap = ($rateRight - $rateSize.Width - (Px 8)) - (Px 30)
    if ($cap -lt (Px 30)) { $cap = Px 30 }
    while ($title.Length -gt 1 -and $g.MeasureString($title, $script:Fonts.rowTitle).Width -gt $cap) {
      $title = $title.Substring(0, $title.Length - 1)
    }
    $g.DrawString($title, $script:Fonts.rowTitle, $titleBrush, (Px 30), ($y + (Px 2)))

    # 在飞行第二行：计时 + 该会话累计输出
    if ($r.inFlight) {
      $e = 0.0
      if ($r.elapsed) { $e = [double]$r.elapsed }
      $g.DrawString(($script:Str.elapsedFmt -f $e), $script:Fonts.stat, $script:Brushes.sub, (Px 30), ($y + (Px 18)))
      Draw-Right -g $g -text ($script:Str.totalFmt -f [long]$r.out) -font $script:Fonts.stat `
        -brush $script:Brushes.faint -rightX ($script:MultiW - (Px 12)) -y ($y + (Px 18))
    }
    $y += $rowH
  }

  if ($script:MoreRows -gt 0) {
    $g.DrawString(($script:Str.moreFmt -f $script:MoreRows), $script:Fonts.stat, $script:Brushes.faint, (Px 30), ($y + (Px 2)))
  }
}

$form.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # 分层窗口（Opacity<1）没有不透明底色，ClearType 按透明底混合会出彩边，
    # 退回灰度抗锯齿；完全不透明时仍用 ClearType 保持锐利
    if ($form.Opacity -lt 1) {
      $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    }
    else {
      $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    }

    # ---- 多行模式：并列展示活跃会话（DESIGN.md §7.2），单卡逻辑不参与 ----
    if ($script:MultiMode) {
      Draw-MultiRows -g $g
      return
    }

    # ---- 状态判定 ----
    # 在飞：日志里有 started 未配对 completed 的请求（L1）。rollout 的 lastAt 只在
    # 请求结束时更新，长请求期间靠它判断「在不在跑」会在 2.5s 后误判为空闲。
    $inFlight = $false
    $elapsedSec = 0.0
    $elapsedSec = Get-InFlightElapsed -SessionId $script:Stats.sessionId
    if ($null -ne $elapsedSec -and $elapsedSec -le 600) {
      $inFlight = $true
    }
    else {
      $elapsedSec = 0.0   # 超时条目 Update-Estimates 已清，这里只防渲染残留
    }
    $recent = $false
    if ($script:Stats.lastAtUtc) {
      $recent = (([DateTime]::UtcNow - $script:Stats.lastAtUtc).TotalSeconds -lt 2.5)
    }
    $live = $inFlight -or $recent
    $hasError = [bool]$script:Stats.error
    $hasData = ($null -ne $script:Stats.lastTps)

    # ---- 状态点 ----
    $dotBrush = $script:Brushes.idleDot
    if ($hasError) { $dotBrush = $script:Brushes.error }
    elseif ($live) { $dotBrush = $script:Brushes.live }
    $g.FillEllipse($dotBrush, (Px 12), (Px 15), (Px 7), (Px 7))

    # ---- 主数字 + 单位 ----
    $numBrush = $script:Brushes.sub
    if ($live -and -not $hasError) { $numBrush = $script:Brushes.ink }
    $txt = '—'
    if ($hasData -and -not $hasError) { $txt = '{0:N1}' -f $script:Stats.lastTps }
    # 在飞且估算在场（L3，DESIGN.md §6）：主数字让位给 ≈估算（琥珀色），
    # 真值在请求结束落盘后回落覆盖。窗口内落库不足 2 次时估算为空，只留计时。
    if ($inFlight -and -not $hasError) {
      $estimMain = Get-EstimTps -SessionId $script:Stats.sessionId
      if ($null -ne $estimMain) {
        $txt = '≈{0:N0}' -f $estimMain
        $numBrush = $script:Brushes.estim
      }
    }
    $numX = Px 26; $numY = Px 0
    $g.DrawString($txt, $script:Fonts.hero, $numBrush, $numX, $numY)
    $numSize = $g.MeasureString($txt, $script:Fonts.hero)
    $unitY = $numY + $numSize.Height - (Px 16)
    $g.DrawString($script:Str.unit, $script:Fonts.unit, $script:Brushes.sub, ($numX + $numSize.Width + (Px 2)), $unitY)
    # ---- 右上角：生成中是 L1 计时；空闲/等待时让给会话短码（FR1-5 归属可核对） ----
    if ($inFlight) {
      Draw-Right -g $g -text ('{0:N1}s' -f $elapsedSec) -font $script:Fonts.unit `
        -brush $script:Brushes.sub -rightX ($W - (Px 12)) -y (Px 16)
    }
    else {
      $short = Get-ShortSessionId
      if ($short) {
        Draw-Right -g $g -text ($script:Str.idFmt -f $short) -font $script:Fonts.stat `
          -brush $script:Brushes.faint -rightX ($W - (Px 12)) -y (Px 17)
      }
    }
    if ($script:Hovered) {
      $g.DrawString('×', $script:Fonts.unit, $script:Brushes.sub, ($W - (Px 20)), (Px 0))
    }

    # ---- 迷你柱状图。纵轴迟滞：新高立即采用，之后每帧只许缓慢衰减，
    #      否则每次刷出新高整图瞬间重缩放，看起来在「呼吸」 ----
    $spark = @($script:Stats.spark)
    $x0 = Px 12; $y0 = Px 60; $bw = Px 192; $bh = Px 26
    $g.DrawLine($script:Pens.track, $x0, ($y0 + $bh), ($x0 + $bw), ($y0 + $bh))
    if ($spark.Count -gt 0) {
      $dataMax = ($spark | Measure-Object -Maximum).Maximum
      if ($dataMax -le 0) { $dataMax = 1.0 }
      if ($dataMax -gt $script:Stats.chartMax) { $script:Stats.chartMax = [double]$dataMax }
      else { $script:Stats.chartMax = [Math]::Max($dataMax, $script:Stats.chartMax * 0.997) }
      $slots = 40.0
      $step = $bw / $slots
      $n = $spark.Count
      for ($i = 0; $i -lt $n; $i++) {
        $v = [double]$spark[$i]
        $h = [Math]::Max([double](Px 2), ($v / $script:Stats.chartMax) * $bh)
        $x = $x0 + ($i * $step)
        $barW = [single][Math]::Max([double](Px 2), $step - (Px 1))
        if (($i -eq $n - 1) -and $live) {
          $g.FillRectangle($script:Brushes.live, [single]$x, [single]($y0 + $bh - $h), $barW, [single]$h)
        }
        else {
          $g.FillRectangle($script:Brushes.faint, [single]$x, [single]($y0 + $bh - $h), $barW, [single]$h)
        }
      }
    }

    # ---- 元信息三行（等待/出错时换成状态文案）。
    #      左列是对象与累计，右列是速率口径，全部同字号——层级靠主数字的
    #      体量与颜色对比表达，不靠删信息（FR1-5/6/7 的数据全保留） ----
    $metaY1 = Px 92; $metaY2 = Px 107; $metaY3 = Px 122
    if ($script:Stats.waiting) {
      $g.DrawString($script:Str.waiting, $script:Fonts.stat, $script:Brushes.sub, (Px 12), $metaY1)
    }
    elseif ($hasError) {
      $g.DrawString($script:Stats.error, $script:Fonts.stat, $script:Brushes.error, (Px 12), $metaY1)
    }
    elseif ($script:Stats.requests -eq 0 -and $script:Stats.skipped -gt 0) {
      $g.DrawString(($script:Str.unreadable -f $script:Stats.skipped), $script:Fonts.stat, $script:Brushes.sub, (Px 12), $metaY1)
    }
    else {
      $model = $script:Stats.model
      if (-not $model) { $model = $script:Str.noModel }
      # 右列：受限模式标注 > 会话标题（FR1-5 人能读懂的归属）> req 计数。
      # 标题在场时 req 退到 status.json 可查（req 本就不是 FR1 条目）。
      $rightText = $script:Str.restricted
      if (-not $script:Restricted) {
        $title = Get-SessionTitle
        if ($title) {
          $rightText = $title
          # 标题最长 60 字符，先按半窗截断，给左列的模型名留位置
          $cap = $W * 0.55
          while ($rightText.Length -gt 1 -and $g.MeasureString($rightText, $script:Fonts.stat).Width -gt $cap) {
            $rightText = $rightText.Substring(0, $rightText.Length - 1)
          }
          if ($rightText -ne $title) { $rightText += '…' }
        }
        else { $rightText = $script:Str.reqFmt -f $script:Stats.requests }
      }
      $rightW = $g.MeasureString($rightText, $script:Fonts.stat).Width
      $avail = ($W - (Px 12) - $rightW - (Px 10)) - (Px 12)
      while ($model.Length -gt 1 -and $g.MeasureString($model, $script:Fonts.stat).Width -gt $avail) {
        $model = $model.Substring(0, $model.Length - 1)
      }
      if ($script:Stats.model -and $model -ne $script:Stats.model) { $model += '…' }
      $g.DrawString($model, $script:Fonts.stat, $script:Brushes.sub, (Px 12), $metaY1)
      Draw-Right -g $g -text $rightText -font $script:Fonts.stat `
        -brush $script:Brushes.faint -rightX ($W - (Px 12)) -y $metaY1

      $turnText = '—'
      if ($script:Stats.turnOut -gt 0) { $turnText = '{0:N0}' -f $script:Stats.turnOut }
      $avgText = '—'
      $avgTps = Get-SessTps
      if ($null -ne $avgTps) { $avgText = '{0:N1}' -f $avgTps }
      $maxText = '—'
      if ($null -ne $script:Stats.sessMaxTps) { $maxText = '{0:N1}' -f $script:Stats.sessMaxTps }
      $g.DrawString(($script:Str.turnFmt -f $turnText), $script:Fonts.stat, $script:Brushes.sub, (Px 12), $metaY2)
      # 会话合计口径（Σ tokens ÷ Σ time）即当前会话的平均速率
      Draw-Right -g $g -text ($script:Str.avgFmt -f $avgText) -font $script:Fonts.stat `
        -brush $script:Brushes.faint -rightX ($W - (Px 12)) -y $metaY2

      $g.DrawString(($script:Str.totalFmt -f $script:Stats.sessOut), $script:Fonts.stat, $script:Brushes.sub, (Px 12), $metaY3)
      Draw-Right -g $g -text ($script:Str.maxFmt -f $maxText) -font $script:Fonts.stat `
        -brush $script:Brushes.faint -rightX ($W - (Px 12)) -y $metaY3
    }
  })

$form.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $script:Drag = $true
      $script:DragMoved = $false
      $script:DragOffX = $e.X
      $script:DragOffY = $e.Y
    }
  })

$form.Add_MouseMove({
    param($sender, $e)
    if ($script:Drag) {
      $p = [System.Windows.Forms.Cursor]::Position
      $form.Location = New-Object System.Drawing.Point(($p.X - $script:DragOffX), ($p.Y - $script:DragOffY))
      $script:DragMoved = $true
    }
  })

$form.Add_MouseUp({
    param($sender, $e)
    $wasDrag = $script:DragMoved
    $script:Drag = $false
    $script:DragMoved = $false
    if ($wasDrag) { Save-Pos; return }
    # 命中区按当前窗口宽度算：多行模式下宽度与 × 的位置都变了
    $curW = $form.ClientSize.Width
    if ($e.X -ge ($curW - (Px 34)) -and $e.Y -le (Px 28)) { $form.Close() }
  })

# 关闭钮平时不画（chrome 为零），悬停时才出现；命中区不变
$form.Add_MouseEnter({
    $script:Hovered = $true
    $form.Invalidate()
  })
$form.Add_MouseLeave({
    $script:Hovered = $false
    $form.Invalidate()
  })

# 提前创建句柄并设 WS_EX_NOACTIVATE：小窗永不成为前台窗口，显示/点击/拖动都不抢
# ZCode 的焦点。必须发生在首次显示之前——否则启动显示会激活自己；拖动时若小窗被
# 点击激活成前台，还会出现「拖完→ZCode 失去前台→小窗被隐藏」的坏体验。
# （实测在 HandleCreated 事件里设不生效，所以这里直接强制创建句柄后设。）
try {
  [void]$form.Handle
  $ex = [ZCodeNative.Dpi]::GetWindowLong($form.Handle, -20)
  [void][ZCodeNative.Dpi]::SetWindowLong($form.Handle, -20, ($ex -bor 0x08000000))
} catch { }

$form.Add_Shown({ Assert-TopMost })
$form.Add_FormClosing({ Save-Pos })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$script:TickCount = 0
$timer.Add_Tick({
    if ($form.IsDisposed) { return }
    $script:TickCount++
    # —— 生命周期看门狗（PORTABILITY.md §2 L4）——
    # /tps stop 的哨兵文件：删掉它并退出。文件是最低公分母的 IPC。
    if (Test-Path -LiteralPath $StopFlag -PathType Leaf) {
      Remove-Item -LiteralPath $StopFlag -Force -ErrorAction SilentlyContinue
      $form.Close()
      return
    }
    # 插件被卸载/缓存被清（脚本所在插件根目录消失）：退出并清掉状态文件，不留残留。
    # 每 5 个 tick（2s）查一次目录存在性，代价可忽略。
    if (-not $NoWatchdog -and ($script:TickCount % 5) -eq 0 -and $script:PluginRoot -and
      -not (Test-Path -LiteralPath $script:PluginRoot)) {
      $script:TearDown = $true
      Remove-Item -LiteralPath $PosFile, $StatusFile, $ConfigFile, $SidecarSnap -Force -ErrorAction SilentlyContinue
      $form.Close()
      return
    }
    Update-ZCodeFollow
    if ($form.IsDisposed) { return }   # 本轮跟随把窗口关了
    Update-Sidecar
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -or -not $form.Visible) {
      # 收起/隐藏状态：不置顶、不重绘（SetWindowPos 的 SHOWWINDOW 会把窗口顶回来），
      # 但统计照常，保持 status.json 新鲜
      Update-Stats
      Write-Status
      return
    }
    if (($script:TickCount % 5) -eq 0) { Assert-TopMost }
    Update-Stats
    # 单卡 ↔ 多行切换（行数据刚在 Update-Stats 里组装好；≥2 行并列，单行退回紧凑卡片）
    $visRows = @($script:OverlayRows).Count + $(if ($script:MoreRows -gt 0) { 1 } else { 0 })
    Update-OverlayShape -Multi:($visRows -ge 2) -VisualRows $visRows
    Write-Status
    $form.Invalidate()
  })
$timer.Start()

Start-Sidecar
Update-Stats
Write-Status
[void][System.Windows.Forms.Application]::Run($form)
Stop-Sidecar
