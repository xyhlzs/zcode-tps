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
    powershell.exe ... -File tps-monitor.ps1 -Opacity 0.8   # 窗口不透明度（0.3-1.0，默认 0.8）
#>
[CmdletBinding()]
param(
  [string]$SessionId,
  [string]$RolloutDir,
  [string]$LogDir,
  [switch]$Headless,
  [int]$Seconds = 0,
  [double]$Opacity = 0.8
)

$ErrorActionPreference = 'Stop'

# 钳制到可用区间：低于 0.3 基本看不清，高于 1.0 非法
$Opacity = [Math]::Min(1.0, [Math]::Max(0.3, $Opacity))

$ZCodeHome = Join-Path $env:USERPROFILE '.zcode\cli'
if (-not $RolloutDir) { $RolloutDir = Join-Path $ZCodeHome 'rollout' }
if (-not $LogDir) { $LogDir = Join-Path $ZCodeHome 'log' }

$StateDir = Join-Path $env:LOCALAPPDATA 'ZCodeTpsMonitor'
$PosFile = Join-Path $StateDir 'pos.txt'
$StatusFile = Join-Path $StateDir 'status.json'

# 首次接入一个 rollout 文件时回看多少字节（行对齐后从这里开始读）
$LookbackBytes = 8388608L

# 日志事件指定的会话，若落后最新活动超过这个毫秒数，就认为用户跑到别的会话去了
$DesiredStaleMs = 30000

# 回退到「最新活动文件」时，新文件要比当前目标新这么多才切，避免两个会话交替写入时来回跳
$SwitchHysteresisMs = 2000

# 这些日志事件代表「某个会话刚刚被激活 / 用户刚在这个会话里提交了输入」
$ActivationEvents = @(
  'turn.started',
  'session.resumed',
  'zcode_protocol.session_create.completed',
  'bootstrap.app.startup.started'
)

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
  }
}

$script:Stats = New-Stats
$script:Tail = @{ path = ''; pos = 0L; carry = '' }          # rollout 读取游标
$script:LogTail = @{ path = ''; pos = 0L; carry = '' }        # 日志读取游标
$script:DesiredSession = ''                                    # 日志事件给出的目标会话
$script:ZCodeHwnd = [IntPtr]::Zero                             # ZCode 主窗口句柄缓存
$script:ZCodeSeen = $false                                     # 是否成功找到过 ZCode 窗口
$script:ZCodeState = 'none'                                    # none / normal / minimized / closed

$script:Drag = $false
$script:DragMoved = $false
$script:DragOffX = 0
$script:DragOffY = 0

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
      # 回看尾部即可：要的是「最近一次会话激活」，不重放整天的日志
      $script:LogTail.pos = [Math]::Max(0L, $len - 65536)
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
      if ($ActivationEvents -notcontains $m.Groups[1].Value) { continue }
      # 顶层 sessionId 在 context 之前，取第一个匹配
      $m = [regex]::Match($line, '"sessionId"\s*:\s*"(sess_[^"]+)"')
      if (-not $m.Success) { continue }
      $sid = $m.Groups[1].Value
      # 子代理会话不算「用户所在的会话」
      if ($sid -like 'sess_subagent_*') { continue }
      $script:DesiredSession = $sid
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

  # 2) 日志事件指定的会话优先。它反映「用户刚切过去 / 刚敲了回车」，
  #    比 rollout 落盘及时得多；但若它已明显落后最新活动，说明用户在别处干活，跟过去。
  if ($script:DesiredSession) {
    $wantName = "model-io-$($script:DesiredSession).jsonl"
    $desired = $files | Where-Object { $_.Name -eq $wantName } | Select-Object -First 1
    if ($desired) {
      if ($newest.FullName -eq $desired.FullName) {
        $script:Stats.source = 'log'
        return $desired.FullName
      }
      $gapMs = ($newest.LastWriteTimeUtc - $desired.LastWriteTimeUtc).TotalMilliseconds
      if ($gapMs -lt $DesiredStaleMs) {
        $script:Stats.source = 'log'
        return $desired.FullName
      }
    }
    else {
      # 归属指向一个还没有 rollout 文件的会话（用户刚切过去、它从未生成过）。
      # 若此刻别的会话正在生成（最近 5 秒内有写入），视为日志信号已过期，
      # 继续显示正在生成的会话；否则返回空，由调用方进入等待态显示。
      $idleMs = ([DateTime]::UtcNow - $newest.LastWriteTimeUtc).TotalMilliseconds
      if ($idleMs -ge 5000) {
        $script:Stats.source = 'log-empty'
        return ''
      }
    }
  }

  # 3) 回退：最新写入的文件，带迟滞避免来回跳
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

  $out = @()
  if (-not $Path) { return $out }

  if ($Path -ne $script:Tail.path) {
    # 换会话了：游标归零并清空统计，避免把上一个会话的数混进来
    $script:Tail.path = $Path
    $script:Tail.carry = ''
    $script:Stats = New-Stats
    $script:Stats.target = $Path
    $len = (Get-Item -LiteralPath $Path).Length
    $from = [Math]::Max(0L, $len - $LookbackBytes)
    $script:Tail.pos = Get-LineStartOffset -Path $Path -From $from
  }

  $len = (Get-Item -LiteralPath $Path).Length
  if ($len -lt $script:Tail.pos) {
    # 文件被截断或轮转
    $script:Tail.pos = 0L
    $script:Tail.carry = ''
  }
  if ($len -le $script:Tail.pos) { return $out }

  $buf = $null
  $read = 0
  $fs = New-Object System.IO.FileStream(
    $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    [void]$fs.Seek($script:Tail.pos, [System.IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] ($len - $script:Tail.pos)
    $read = $fs.Read($buf, 0, $buf.Length)
    $script:Tail.pos += $read
  } finally {
    $fs.Dispose()
  }

  $text = $script:Tail.carry + [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
  $parts = $text -split "`n"
  $script:Tail.carry = $parts[$parts.Length - 1]

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

  return [ordered]@{
    durationMs      = $dur
    outputTokens    = $outTokens
    reasoningTokens = $reasoning
    sessionId       = $sid
    turnId          = $tid
    model           = $model
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

  $spark = @($script:Stats.spark)
  $spark += [double]$script:Stats.lastTps
  if ($spark.Count -gt 40) { $spark = $spark[($spark.Count - 40)..($spark.Count - 1)] }
  $script:Stats.spark = $spark
}

function Update-Stats {
  try {
    Update-DesiredSession
    $target = Resolve-TargetFile
    if (-not $target) {
      if ($script:Stats.source -eq 'log-empty') {
        # 归属已切到一个还没有生成数据的会话：清空数字、角标换成新会话、
        # 底部显示等待文案。这不是错误，不能走 error 字段。
        $script:Stats = New-Stats
        $script:Stats.sessionId = $script:DesiredSession
        $script:Stats.source = 'log-empty'
        $script:Stats.waiting = $true
        return
      }
      $script:Stats.error = '未找到 rollout 文件'
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

function Get-ShortSessionId {
  $sid = $script:Stats.sessionId
  if (-not $sid) { return '' }
  $sid = $sid -replace '^sess_', ''
  if ($sid.Length -gt 8) { return $sid.Substring(0, 8) }
  return $sid
}

function Write-Status {
  # status.json 只是排查用的旁路产物：写不进去绝不能影响监控本身，
  # 所以整个函数吞掉异常。
  try {
    $lastAt = $null
    if ($script:Stats.lastAtUtc) { $lastAt = $script:Stats.lastAtUtc.ToString('o') }
    $snapshot = [ordered]@{
      target              = $script:Stats.target
      source              = $script:Stats.source
      zcodeWin            = $script:ZCodeState
      desiredSession      = $script:DesiredSession
      model               = $script:Stats.model
      sessionId           = $script:Stats.sessionId
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
    Update-Stats
    Write-Status
    Start-Sleep -Milliseconds 400
  }
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

$W = [int](Px 240)
$H = [int](Px 190)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ZCode TPS'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.ClientSize = New-Object System.Drawing.Size($W, $H)
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(249, 250, 251)
$form.Opacity = $Opacity

$dbProp = $form.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
if ($dbProp) { $dbProp.SetValue($form, $true) }

# 圆角
$rad = Px 8
$gp = New-Object System.Drawing.Drawing2D.GraphicsPath
$gp.AddArc(0, 0, $rad, $rad, 180, 90)
$gp.AddArc(($W - $rad), 0, $rad, $rad, 270, 90)
$gp.AddArc(($W - $rad), ($H - $rad), $rad, $rad, 0, 90)
$gp.AddArc(0, ($H - $rad), $rad, $rad, 90, 90)
$gp.CloseFigure()
$form.Region = New-Object System.Drawing.Region($gp)

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

$script:Fonts = @{
  label = New-Object System.Drawing.Font('Segoe UI', 8)
  big   = New-Object System.Drawing.Font('Segoe UI', 26, [System.Drawing.FontStyle]::Bold)
  unit  = New-Object System.Drawing.Font('Segoe UI', 9)
  stat  = New-Object System.Drawing.Font('Segoe UI', 8)
}
$script:Brushes = @{
  text   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(17, 24, 39))
  muted  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(107, 114, 128))
  faint  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(156, 163, 175))
  accent = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0, 120, 212))
  bar    = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(140, 0, 120, 212))
  barDim = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(48, 0, 120, 212))
  live   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(16, 185, 129))
  idle   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(209, 213, 219))
}
$script:Pens = @{
  border = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(229, 231, 235)), 1
  track  = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(243, 244, 246)), 1
}

function Save-Pos {
  try {
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
      if ($sb.ToString() -ne 'ZCode') { return $true }      # 标题先过滤，命中才查进程（贵）
      [uint32]$p = 0
      [void][ZCodeNative.Dpi]::GetWindowThreadProcessId($h, [ref]$p)
      $proc = Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue
      if ($proc -and $proc.ProcessName -eq 'ZCode' -and [ZCodeNative.Dpi]::IsWindowVisible($h)) {
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
      if ($fgProc -and $fgProc.ProcessName -eq 'ZCode') { $isFg = $true }
    }
    if ($isFg) {
      $script:ZCodeState = 'normal'
      if (-not $form.Visible) { $form.Show() }
    }
    elseif (-not $script:Drag) {
      # ZCode 不在前台：隐藏小窗。拖动进行中暂缓一轮，拖完再隐藏。
      $script:ZCodeState = 'hidden'
      if ($form.Visible) { $form.Hide() }
    }
  } catch { }
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

    $g.DrawString('ZCode TPS', $script:Fonts.label, $script:Brushes.muted, (Px 12), (Px 9))

    $live = $false
    if ($script:Stats.lastAtUtc) {
      $live = (([DateTime]::UtcNow - $script:Stats.lastAtUtc).TotalSeconds -lt 2.5)
    }
    $dotY = Px 13
    $dotS = Px 7
    if ($live) { $g.FillEllipse($script:Brushes.live, (Px 78), $dotY, $dotS, $dotS) }
    else { $g.FillEllipse($script:Brushes.idle, (Px 78), $dotY, $dotS, $dotS) }

    # 会话短码：确认当前数字属于哪个会话
    $short = Get-ShortSessionId
    if ($short) {
      $sidText = "id $short"
      $sidW = $g.MeasureString($sidText, $script:Fonts.stat).Width
      $g.DrawString($sidText, $script:Fonts.stat, $script:Brushes.faint, ($W - $sidW - (Px 30)), (Px 9))
    }

    $g.DrawString('×', $script:Fonts.unit, $script:Brushes.faint, ($W - (Px 22)), (Px 8))

    $txt = '—'
    if ($null -ne $script:Stats.lastTps) { $txt = '{0:N1}' -f $script:Stats.lastTps }
    $g.DrawString($txt, $script:Fonts.big, $script:Brushes.accent, (Px 10), (Px 24))
    $w = $g.MeasureString($txt, $script:Fonts.big).Width
    $g.DrawString('tok/s', $script:Fonts.unit, $script:Brushes.muted, ((Px 10) + $w + (Px 4)), (Px 46))

    # 迷你柱状图
    $spark = @($script:Stats.spark)
    $x0 = Px 12; $y0 = Px 82; $bw = Px 216; $bh = Px 22
    $g.DrawLine($script:Pens.track, $x0, ($y0 + $bh), ($x0 + $bw), ($y0 + $bh))
    if ($spark.Count -gt 0) {
      $max = ($spark | Measure-Object -Maximum).Maximum
      if ($max -le 0) { $max = 1 }
      $slots = 40.0
      $step = $bw / $slots
      $n = $spark.Count
      for ($i = 0; $i -lt $n; $i++) {
        $v = [double]$spark[$i]
        $h = [Math]::Max([double](Px 2), ($v / $max) * $bh)
        $x = $x0 + ($i * $step)
        $barW = [single][Math]::Max([double](Px 2), $step - (Px 1.5))
        if ($i -eq $n - 1) {
          $g.FillRectangle($script:Brushes.bar, [single]$x, [single]($y0 + $bh - $h), $barW, [single]$h)
        }
        else {
          $g.FillRectangle($script:Brushes.barDim, [single]$x, [single]($y0 + $bh - $h), $barW, [single]$h)
        }
      }
    }

    $turnTps = Get-TurnTps
    $sessTps = Get-SessTps
    $maxTps = $script:Stats.sessMaxTps
    $turnText = '—'
    if ($null -ne $turnTps) { $turnText = '{0:N1}' -f $turnTps }
    $sessText = '—'
    if ($null -ne $sessTps) { $sessText = '{0:N1}' -f $sessTps }
    $maxText = '—'
    if ($null -ne $maxTps) { $maxText = '{0:N1}' -f $maxTps }

    $g.DrawString(('本轮  {0} tok/s  {1:N0} tok' -f $turnText, $script:Stats.turnOut), $script:Fonts.stat, $script:Brushes.text, (Px 12), (Px 112))
    # 会话合计口径（Σ tokens ÷ Σ time）即当前会话的平均速率
    $g.DrawString(('平均  {0} tok/s  {1:N0} tok' -f $sessText, $script:Stats.sessOut), $script:Fonts.stat, $script:Brushes.muted, (Px 12), (Px 128))
    $g.DrawString(('最高  {0} tok/s' -f $maxText), $script:Fonts.stat, $script:Brushes.muted, (Px 12), (Px 144))

    $foot = ''
    if ($script:Stats.waiting) {
      $foot = '该会话暂无生成数据'
    }
    elseif ($script:Stats.error) {
      $foot = $script:Stats.error
    }
    elseif ($script:Stats.requests -eq 0 -and $script:Stats.skipped -gt 0) {
      $foot = '已读 {0} 行，0 条可识别' -f $script:Stats.skipped
    }
    else {
      $model = $script:Stats.model
      if (-not $model) { $model = '等待输出' }
      $ago = ''
      if ($script:Stats.lastAtUtc) {
        $s = [int]([DateTime]::UtcNow - $script:Stats.lastAtUtc).TotalSeconds
        $ago = "  ${s}s 前"
      }
      $foot = '{0}  {1} req{2}' -f $model, $script:Stats.requests, $ago
    }
    $g.DrawString($foot, $script:Fonts.stat, $script:Brushes.faint, (Px 12), (Px 160))

    $g.DrawRectangle($script:Pens.border, 0, 0, ($W - 1), ($H - 1))
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
    if ($e.X -ge ($W - (Px 34)) -and $e.Y -le (Px 28)) { $form.Close() }
  })

$form.Add_HandleCreated({
    # WS_EX_NOACTIVATE：小窗永不成为前台窗口，创建/显示/点击都不抢 ZCode 的焦点。
    # 必须在句柄创建后、首次显示前设好；没有它，「显示→抢焦点→ZCode 失去前台→
    # 又被隐藏」会来回震荡，而且启动时会吃掉用户敲进 ZCode 的头几个键。
    try {
      $ex = [ZCodeNative.Dpi]::GetWindowLong($form.Handle, -20)
      [void][ZCodeNative.Dpi]::SetWindowLong($form.Handle, -20, ($ex -bor 0x08000000))
    } catch { }
  })

$form.Add_Shown({ Assert-TopMost })
$form.Add_FormClosing({ Save-Pos })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$script:TickCount = 0
$timer.Add_Tick({
    if ($form.IsDisposed) { return }
    $script:TickCount++
    Update-ZCodeFollow
    if ($form.IsDisposed) { return }   # 本轮跟随把窗口关了
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -or -not $form.Visible) {
      # 收起/隐藏状态：不置顶、不重绘（SetWindowPos 的 SHOWWINDOW 会把窗口顶回来），
      # 但统计照常，保持 status.json 新鲜
      Update-Stats
      Write-Status
      return
    }
    if (($script:TickCount % 5) -eq 0) { Assert-TopMost }
    Update-Stats
    Write-Status
    $form.Invalidate()
  })
$timer.Start()

Update-Stats
Write-Status
[void][System.Windows.Forms.Application]::Run($form)
