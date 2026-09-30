#Requires -Version 5.1
<#
  ZCode TPS · L3 在飞估算 + 多会话并列数据层测试（DESIGN.md §6/§7.2）

  用合成的 rollout/日志/假 sidecar 快照驱动一个 -Headless 监控进程，断言 status.json：
    1  在飞期间快照计数增长（窗口内落库 ≥2 次）→ 出现估算 estimTps（FR1-3）
    2  请求完成（completed + rollout 落盘）→ 换算系数被真值标定（calibN ≥ 1），
       在飞估算随之消失（不在飞不出估算），主数字回落真值
    3  多会话并列：两个活跃会话各成一行，空闲行的速率来自它自己的 rollout tail
    4  无依据不出数字：计数恒定（没有落库）的会话在飞也不显示估算（FR1-4）
    5  标定基线失配被丢弃：捕获竞态留下的旧 message 基线不滞留，下个请求
       重新捕获并标定成功（calibN 继续增长）

  用法：powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\estim-test.ps1
  退出码：0 = 全部通过，1 = 有失败。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Monitor = Join-Path $RepoRoot 'monitor\tps-monitor.ps1'
$Root = Join-Path $env:TEMP ('zcode-tps-estim-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$LogDir = Join-Path $Root 'log'; $RolloutDir = Join-Path $Root 'rollout'; $StateDir = Join-Path $Root 'state'
foreach ($d in @($LogDir, $RolloutDir, $StateDir)) { [void](New-Item -ItemType Directory -Path $d -Force) }
$LogFile = Join-Path $LogDir 'zcode-test.jsonl'
$SidA = 'sess_aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
$SidB = 'sess_bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'
$script:Fail = 0
$script:Pass = 0

function Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) { Write-Host ('  PASS  ' + $Name); $script:Pass++ }
  else { Write-Host ('  FAIL  ' + $Name + $(if ($Detail) { "   <- $Detail" } else { '' })); $script:Fail++ }
}

function Add-Log {
  param([string]$Event, [string]$Session)
  $line = '{"timestamp":"' + [DateTime]::UtcNow.ToString('o') + '","level":"info","event":"' + $Event +
    '","sessionId":"' + $Session + '"}'
  [System.IO.File]::AppendAllText($LogFile, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Add-Rollout {
  param([string]$Session, [int]$Out, [int]$Ms, [int]$Reasoning = 0)
  $line = '{"completedAt":"' + [DateTime]::UtcNow.ToString('o') + '","durationMs":' + $Ms +
    ',"model":{"modelId":"test-model"},"response":{"usage":{"outputTokens":' + $Out +
    ',"reasoningTokens":' + $Reasoning + '}},"type":"model_io","sessionId":"' + $Session +
    '","turnId":"turn_x"}'
  [System.IO.File]::AppendAllText((Join-Path $RolloutDir ('model-io-' + $Session + '.jsonl')),
    $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Snap {
  param([long]$rA, [long]$xA, [long]$rB, [long]$xB, [string]$MsgA = 'msg_a')
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $snap = @{
    t        = $now
    titles   = @{ $SidA = '合成会话A'; $SidB = '并发会话B' }
    sessions = @(
      @{ id = $SidA; title = '合成会话A'; lastActiveMs = $now; msgId = $MsgA; msgSeq = 1;
         parts = @{ reasoning = $rA; text = $xA; other = 100 } },
      @{ id = $SidB; title = '并发会话B'; lastActiveMs = $now; msgId = 'msg_b'; msgSeq = 2;
         parts = @{ reasoning = $rB; text = $xB; other = 0 } }
    )
  }
  [System.IO.File]::WriteAllText((Join-Path $StateDir 'sidecar.json'),
    ($snap | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Status {
  $p = Join-Path $StateDir 'status.json'
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  # status.json 是无 BOM 的 UTF-8：PS 5.1 的 Get-Content 不带 -Encoding 时按系统
  # ANSI 读，中文标题会乱码
  try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Wait-Status {
  param([scriptblock]$Cond, [int]$TimeoutMs = 6000)
  $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
  while ((Get-Date) -lt $deadline) {
    $s = Get-Status
    if ($s -and (& $Cond $s)) { return $s }
    Start-Sleep -Milliseconds 200
  }
  return $null
}

function Show-Status {
  param($s)
  if (-not $s) { return 'status.json 还没写出来' }
  $estim = '—'
  if ($null -ne $s.estimTps) { $estim = [math]::Round([double]$s.estimTps, 1) }
  return ('source=' + $s.source + ' inFlight=' + $s.inFlight + ' lastTps=' + $s.lastTps +
    ' estim=' + $estim + ' calibN=' + $s.calibTextN + '/' + $s.calibReasoningN +
    ' rows=' + @($s.rows).Count)
}

# ---------------------------------------------------------------- 初始数据
# A：请求已在飞（started 未配对 completed），rollout 已有一条历史真值（100/2s = 50）
Add-Rollout -Session $SidA -Out 100 -Ms 2000 -Reasoning 30
# B：只有一条历史真值（200/2s = 100），不在飞
Add-Rollout -Session $SidB -Out 200 -Ms 2000
Add-Log 'turn.started' $SidA
Add-Log 'model.request.started' $SidA
Write-Snap 1000 500 800 300                     # A 的计数基线（started 时记录）

$mon = $null
try {
  Write-Host ''
  Write-Host "临时目录：$Root"
  $mon = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Monitor,
    '-Headless', '-Seconds', '120', '-LogDir', $LogDir, '-RolloutDir', $RolloutDir, '-StateDir', $StateDir)

  # ------------------------------------------------------------ 场景 1
  Write-Host ''
  Write-Host '场景 1：快照计数两次增长 → 在飞估算出现（FR1-3）'
  Start-Sleep -Milliseconds 1500
  Write-Snap 1400 900 800 300                   # 落库 +1 次
  Start-Sleep -Milliseconds 1500
  Write-Snap 1900 1500 800 300                  # 落库 +2 次，窗口满足 ≥2 变化
  $s = Wait-Status { param($x) $null -ne $x.estimTps } -TimeoutMs 8000
  Check '在飞估算出现（estimTps 非空）' ($null -ne $s) (Show-Status (Get-Status))
  if ($s) {
    Check '估算为正数' ([double]$s.estimTps -gt 0) ('estimTps=' + $s.estimTps)
    Check '在飞状态成立（L1）' ($s.inFlight -eq $true) ('inFlight=' + $s.inFlight)
    Check '尚未标定（请求没完成，k 用默认值）' ($s.calibTextN -eq 0) ('calibTextN=' + $s.calibTextN)
  }

  # ------------------------------------------------------------ 场景 2
  Write-Host ''
  Write-Host '场景 2：请求完成 → 真值标定系数，估算消失'
  Write-Snap 2400 2200 800 300                  # 最终计数（与基线差 >300，可标定）
  Add-Log 'model.request.completed' $SidA
  Add-Rollout -Session $SidA -Out 300 -Ms 2000 -Reasoning 100   # 真值：300/2s = 150
  $s = Wait-Status { param($x) $x.calibTextN -ge 1 } -TimeoutMs 8000
  Check '换算系数被真值标定（calibTextN ≥ 1）' ($null -ne $s) (Show-Status (Get-Status))
  if ($s) {
    Check 'reasoning 类也标定（calibReasoningN ≥ 1）' ($s.calibReasoningN -ge 1) ('N=' + $s.calibReasoningN)
    Check '标定后 k 仍为正' ([double]$s.calibTextK -gt 0) ('k=' + $s.calibTextK)
    Check '不在飞后估算消失' ($null -eq $s.estimTps) ('estimTps=' + $s.estimTps)
    Check 'A 的真值回落到最新请求（300/2s = 150）' ([math]::Abs([double]$s.lastTps - 150.0) -lt 0.01) ('lastTps=' + $s.lastTps)
  }

  # ------------------------------------------------------------ 场景 3
  Write-Host ''
  Write-Host '场景 3：多会话并列——两行各带各自的数据'
  $s = Wait-Status { param($x) @($x.rows).Count -ge 2 } -TimeoutMs 8000
  Check '两行并列（A + B）' ($null -ne $s) ('rows=' + @((Get-Status).rows).Count)
  if ($s) {
    $rowB = @($s.rows) | Where-Object { $_.sessionId -eq $SidB }
    $rowA = @($s.rows) | Where-Object { $_.sessionId -eq $SidA }
    Check 'B 行标题来自快照' ($rowB -and $rowB.title -eq '并发会话B') ($rowB.title)
    Check 'B 行速率来自它自己的 rollout tail（200/2s = 100）' `
      ($rowB -and $null -ne $rowB.tps -and [math]::Abs([double]$rowB.tps - 100.0) -lt 0.01) ('tps=' + $rowB.tps)
    Check 'A 行不在飞（请求已完成）' ($rowA -and $rowA.inFlight -eq $false) ('inFlight=' + $rowA.inFlight)
    Check '行序稳定（A 前 B 后，按首现顺序）' `
      (@($s.rows)[0].sessionId -eq $SidA -and @($s.rows)[1].sessionId -eq $SidB) `
      ('rows[0]=' + @($s.rows)[0].sessionId + ' rows[1]=' + @($s.rows)[1].sessionId)
  }

  # ------------------------------------------------------------ 场景 4
  Write-Host ''
  Write-Host '场景 4：B 在飞但计数恒定 → 无依据不出估算（FR1-4）'
  Add-Log 'model.request.started' $SidB
  # 快照持续刷新（时间戳变新）但 B 的计数不变——没有落库就没有估算依据
  for ($i = 0; $i -lt 8; $i++) { Write-Snap 2400 2200 800 300; Start-Sleep -Milliseconds 500 }
  $s = Get-Status
  $rowB = @($s.rows) | Where-Object { $_.sessionId -eq $SidB }
  Check 'B 在飞（L1 计时工作）' ($rowB -and $rowB.inFlight -eq $true) ('inFlight=' + $rowB.inFlight)
  Check 'B 无估算（计数恒定，落库 0 次）' ($rowB -and $null -eq $rowB.estimTps) ('estim=' + $rowB.estimTps)
  # 在飞且无估算时行内显示 ≈近期均值（§3.1 修订：请求中途无数据源，旧真值
  # 亮白会被读成实时速率）。B 的会话均值 = 200 tok ÷ 2s = 100。
  Check 'B 行近期均值（200/2s = 100，在飞行显示 ≈100）' `
    ($rowB -and $null -ne $rowB.avgTps -and [math]::Abs([double]$rowB.avgTps - 100.0) -lt 0.01) `
    ('avgTps=' + $rowB.avgTps)
  # 稳定行序（用户反馈）：B 在飞也不重排——在飞只走高亮 + 计时，行序保持首现顺序
  Check 'B 在飞不改变行序（仍 A 前 B 后）' `
    (@($s.rows)[0].sessionId -eq $SidA -and @($s.rows)[1].sessionId -eq $SidB) `
    ('rows[0]=' + @($s.rows)[0].sessionId)

  # ------------------------------------------------------------ 场景 5
  Write-Host ''
  Write-Host '场景 5：基线失配被丢弃——下个请求重新捕获并标定成功'
  # 复现捕获竞态：started 时快照还停在上一条 message（msgId 不同，字节也对不上）。
  # 旧实现把失配基线留到 600s 兜底清理，message id 不会重复出现，期间该会话
  # 所有请求都配不上（calibN 冻结）。新实现基线一次性消费：失配即丢弃。
  Write-Snap 3000 2000 800 300 -MsgA 'msg_old'
  Add-Log 'model.request.started' $SidA          # 捕获基线（msg_old，字节 3000/2000）
  Start-Sleep -Milliseconds 600
  Write-Snap 4000 2500 800 300 -MsgA 'msg_new'   # 新 message 落库（msgId 变了）
  Add-Log 'model.request.completed' $SidA        # msgId 失配 → 基线被丢弃
  Add-Rollout -Session $SidA -Out 300 -Ms 2000 -Reasoning 100
  Start-Sleep -Milliseconds 600
  Write-Snap 4000 2500 800 300 -MsgA 'msg_new'   # 保持 msg_new 不变
  Add-Log 'model.request.started' $SidA          # 重新捕获（msg_new，字节 4000/2500）
  Start-Sleep -Milliseconds 600
  Write-Snap 4500 3000 800 300 -MsgA 'msg_new'   # 生成中，字节增长
  Start-Sleep -Milliseconds 600
  Add-Log 'model.request.completed' $SidA        # 同 msgId，增量 500 ≥ 300 → 标定
  Add-Rollout -Session $SidA -Out 300 -Ms 2000 -Reasoning 100
  $s = Wait-Status { param($x) $x.calibTextN -ge 2 } -TimeoutMs 8000
  Check '失配基线被丢弃后重新捕获并标定（calibTextN ≥ 2）' ($null -ne $s) `
    (Show-Status (Get-Status))
}
finally {
  if ($mon -and -not $mon.HasExited) { Stop-Process -Id $mon.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 200
  Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('结果：通过 {0}，失败 {1}' -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
