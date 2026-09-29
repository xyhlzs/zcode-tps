#Requires -Version 5.1
<#
  ZCode TPS · 会话跟随回归测试

  用合成的日志/rollout 驱动一个 -Headless 监控进程，逐阶段断言 status.json 里的
  归属判定。不依赖真实 ZCode 数据，也不碰用户的真实状态目录（-StateDir 指向临时目录）。

  覆盖：
    1  turn.started 指向 A → 显示 A（source=intent）
    2  【核心回归】A 在生成中（rollout 文件持续刷新），用户切到 B（B 的文件是
       5 分钟前的旧文件）→ 必须切到 B 并显示 B 的数字。
       旧逻辑以「落后最新写入 ≥30s」否掉用户意图，会一直显示 A。
    3  幽灵会话（只有 session_create/bootstrap、永远没有对话）不得改变显示目标
    4  切到还没有 rollout 文件的会话 → 等待态（数字清空、id 换成该会话）；
       在此期间别的会话持续生成也不得顶上来（不再「时不时弹出」）
    5  子代理的 turn.started 不得改变显示目标
    6  意图过期（-IntentTtlMs 调小）→ 回落到「最新写入的会话」

  用法：powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\follow-test.ps1
  退出码：0 = 全部通过，1 = 有失败。
#>
[CmdletBinding()]
param(
  # 意图有效期，调小以便在几秒内覆盖「过期回落」路径
  [int]$IntentTtlMs = 12000
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Monitor = Join-Path $RepoRoot 'monitor\tps-monitor.ps1'
if (-not (Test-Path -LiteralPath $Monitor)) { throw "找不到监控脚本：$Monitor" }

$Root = Join-Path $env:TEMP ('zcode-tps-follow-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$LogDir = Join-Path $Root 'log'
$RolloutDir = Join-Path $Root 'rollout'
$StateDir = Join-Path $Root 'state'
$LogFile = Join-Path $LogDir 'zcode-test.jsonl'
$StatusFile = Join-Path $StateDir 'status.json'
foreach ($d in @($Root, $LogDir, $RolloutDir, $StateDir)) {
  [void](New-Item -ItemType Directory -Path $d -Force)
}

$SidA = 'sess_aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
$SidB = 'sess_bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'
$SidGhost = 'sess_ghost000-3333-4333-8333-000000000000'
$SidNew = 'sess_new00000-4444-4444-8444-000000000000'
$SidSub = 'sess_subagent_agent_5555-5555-4555-8555-555555555555'

$script:Fail = 0
$script:Pass = 0

function Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) {
    Write-Host ("  PASS  " + $Name)
    $script:Pass++
  }
  else {
    Write-Host ("  FAIL  " + $Name + $(if ($Detail) { "   <- $Detail" } else { '' }))
    $script:Fail++
  }
}

function Add-LogEvent {
  param([string]$Event, [string]$Session)
  $line = '{"timestamp":"' + [DateTime]::UtcNow.ToString('o') + '","level":"info","event":"' +
    $Event + '","module":"test","message":"test event","sessionId":"' + $Session + '"}'
  [System.IO.File]::AppendAllText($LogFile, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

# 合成一条 rollout 记录。字段位置必须满足 tps-monitor 的正则假设：
# durationMs/modelId 在行首、usage/sessionId/turnId 在行尾、type=model_io 在尾部。
function Add-Rollout {
  param(
    [string]$Session,
    [int]$OutTokens = 100,
    [int]$DurationMs = 2000,
    [int]$AgeSeconds = 0
  )
  $line = '{"completedAt":"' + [DateTime]::UtcNow.ToString('o') + '","durationMs":' + $DurationMs +
    ',"model":{"modelId":"test-model"},"response":{"usage":{"outputTokens":' + $OutTokens +
    ',"reasoningTokens":0}},"type":"model_io","sessionId":"' + $Session +
    '","turnId":"turn_test","querySource":"main_turn"}'
  $p = Join-Path $RolloutDir ("model-io-$Session.jsonl")
  [System.IO.File]::AppendAllText($p, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
  if ($AgeSeconds -gt 0) {
    (Get-Item -LiteralPath $p).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-$AgeSeconds)
  }
}

function Get-Status {
  if (-not (Test-Path -LiteralPath $StatusFile)) { return $null }
  # status.json 是无 BOM 的 UTF-8：PS 5.1 不带 -Encoding 时按系统 ANSI 读
  try { return (Get-Content -LiteralPath $StatusFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Wait-Status {
  param([scriptblock]$Cond, [int]$TimeoutMs = 6000)
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    $s = Get-Status
    if ($s -and (& $Cond $s)) { return $s }
    Start-Sleep -Milliseconds 150
  }
  return $null
}

function Show-Status {
  param($s)
  if (-not $s) { return 'status.json 还没写出来' }
  return ('source=' + $s.source + ' sessionId=' + $s.sessionId + ' target=' +
    $(if ($s.target) { Split-Path -Leaf $s.target } else { '(空)' }) +
    ' waiting=' + $s.waiting + ' lastTps=' + $s.lastTps)
}

# ---------------------------------------------------------------- 初始数据
# A：有数据（100 tok / 2s = 50 tok/s）
Add-Rollout -Session $SidA -OutTokens 100 -DurationMs 2000
Add-Rollout -Session $SidA -OutTokens 100 -DurationMs 2000
# B：也有数据（200 tok / 2s = 100 tok/s），但文件是 5 分钟前的旧文件
Add-Rollout -Session $SidB -OutTokens 200 -DurationMs 2000 -AgeSeconds 300
# 用户刚在 A 里提交过
Add-LogEvent -Event 'turn.started' -Session $SidA

$mon = $null
try {
  Write-Host ''
  Write-Host "临时目录：$Root"
  Write-Host ("启动监控（-Headless，IntentTtlMs={0}ms）..." -f $IntentTtlMs)

  $mon = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Monitor,
    '-Headless', '-Seconds', '120',
    '-LogDir', $LogDir, '-RolloutDir', $RolloutDir, '-StateDir', $StateDir,
    '-IntentTtlMs', $IntentTtlMs
  )

  # ------------------------------------------------------------ 阶段 1
  Write-Host ''
  Write-Host '阶段 1：意图指向 A → 显示 A 的数据'
  $s = Wait-Status -Cond { param($x) $x.source -eq 'intent' -and $x.sessionId -eq $SidA } -TimeoutMs 10000
  Check '归属切到 A（source=intent）' ($null -ne $s) (Show-Status (Get-Status))
  if ($s) {
    Check '显示的是 A 的 rollout 文件' ($s.target -like "*model-io-$SidA.jsonl")
    Check '速率取自 A 的记录（100/2s = 50）' ([math]::Abs([double]$s.lastTps - 50.0) -lt 0.01) ('lastTps=' + $s.lastTps)
  }

  # ------------------------------------------------------------ 阶段 2（核心回归）
  Write-Host ''
  Write-Host '阶段 2【核心回归】：A 持续生成时用户切到 B → 必须跟随 B'
  Add-LogEvent -Event 'turn.started' -Session $SidB
  $switched = $null
  $samples = @()
  $bounced = 0
  for ($i = 0; $i -lt 6; $i++) {
    # 模拟「后台会话 A 每完成一个请求就刷新自己的 rollout 文件」
    Add-Rollout -Session $SidA -OutTokens 100 -DurationMs 2000
    Start-Sleep -Milliseconds 400
    $cur = Get-Status
    $samples += (Show-Status $cur)
    if ($cur -and $cur.sessionId -eq $SidB) {
      if (-not $switched) { $switched = $cur }
    }
    elseif ($switched) {
      $bounced++   # 已经切到 B 之后又回跳了
    }
  }
  Check '切到 B（不再被 A 的持续写入否决）' ($null -ne $switched) ($samples -join ' | ')
  Check '切到 B 后不再回跳（A 仍在持续写入）' ($switched -and $bounced -eq 0) ('回跳次数=' + $bounced)
  if ($switched) {
    Check '显示的是 B 的 rollout 文件' ($switched.target -like "*model-io-$SidB.jsonl")
    Check '速率取自 B 的记录（200/2s = 100）' ([math]::Abs([double]$switched.lastTps - 100.0) -lt 0.01) ('lastTps=' + $switched.lastTps)
    Check '归属来源是意图而不是 mtime 兜底' ($switched.source -eq 'intent') ('source=' + $switched.source)
  }

  # ------------------------------------------------------------ 阶段 3
  Write-Host ''
  Write-Host '阶段 3：幽灵会话（只有 create/bootstrap）不得改变显示目标'
  Add-LogEvent -Event 'bootstrap.app.startup.started' -Session $SidGhost
  Add-LogEvent -Event 'zcode_protocol.session_create.completed' -Session $SidGhost
  Start-Sleep -Milliseconds 1200
  $cur = Get-Status
  Check '仍然显示 B' ($cur -and $cur.sessionId -eq $SidB) (Show-Status $cur)

  # ------------------------------------------------------------ 阶段 4
  Write-Host ''
  Write-Host '阶段 4：切到还没有 rollout 文件的会话 → 等待态，且不被别的会话顶掉'
  Add-LogEvent -Event 'turn.started' -Session $SidNew
  $s = Wait-Status -Cond { param($x) $x.source -eq 'intent-wait' } -TimeoutMs 5000
  Check '进入等待态（source=intent-wait）' ($null -ne $s) (Show-Status (Get-Status))
  if ($s) {
    Check 'id 已换成新会话' ($s.sessionId -eq $SidNew) ('sessionId=' + $s.sessionId)
    Check '没有拿别的会话的数字顶上' ($s.target -eq '' -and $null -eq $s.lastTps) (Show-Status $s)
  }
  $stable = $true
  $bad = ''
  for ($i = 0; $i -lt 8; $i++) {
    # B 与 A 都在生成（刷新各自的文件），等待态必须稳住，不能时不时弹出别人的 TPS
    Add-Rollout -Session $SidA -OutTokens 100 -DurationMs 2000
    Add-Rollout -Session $SidB -OutTokens 200 -DurationMs 2000
    Start-Sleep -Milliseconds 400
    $cur = Get-Status
    if (-not $cur -or $cur.source -ne 'intent-wait' -or $cur.sessionId -ne $SidNew) {
      $stable = $false
      $bad = Show-Status $cur
      break
    }
  }
  Check '等待态期间显示目标不抖动（约 3s 内 8 次采样）' $stable $bad

  # ------------------------------------------------------------ 阶段 5
  Write-Host ''
  Write-Host '阶段 5：子代理的 turn.started 不得改变显示目标'
  Add-LogEvent -Event 'turn.started' -Session $SidSub
  Start-Sleep -Milliseconds 800
  $cur = Get-Status
  Check '仍然停在等待态的新会话上' ($cur -and $cur.source -eq 'intent-wait' -and $cur.sessionId -eq $SidNew) (Show-Status $cur)

  # ------------------------------------------------------------ 阶段 6
  Write-Host ''
  Write-Host ('阶段 6：意图过期（{0}ms）→ 回落到最新写入的会话' -f $IntentTtlMs)
  # 持续刷新 A 的文件，让它稳定成为「最新写入的会话」。注意 mtime 兜底带 2 秒迟滞
  # （避免两个会话交替写入时来回跳），所以要等 A 比 B 新出 2 秒以上才真正切过去。
  $s = $null
  $deadline = (Get-Date).AddMilliseconds($IntentTtlMs + 15000)
  while ((Get-Date) -lt $deadline) {
    Add-Rollout -Session $SidA -OutTokens 100 -DurationMs 2000
    Start-Sleep -Milliseconds 500
    $cur = Get-Status
    if ($cur -and $cur.source -eq 'mtime' -and $cur.sessionId -eq $SidA) { $s = $cur; break }
  }
  Check '回落到最新写入的 A（source=mtime）' ($null -ne $s) (Show-Status (Get-Status))
}
finally {
  if ($mon -and -not $mon.HasExited) { Stop-Process -Id $mon.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 200
  Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("结果：通过 {0}，失败 {1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
