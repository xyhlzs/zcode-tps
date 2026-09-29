#Requires -Version 5.1
<#
  生成 README 用的小窗截图（开发工具，位于插件目录之外，不随插件分发）。

  做法：用合成数据起一个 -Opacity 1 的监控实例，再把小窗单独抓成 PNG。
  两点刻意的选择：

    * 抓取走 PrintWindow（按窗口句柄渲染），不是抓屏幕——所以截图里不会带进
      宿主窗口、桌面或任何真实内容。合成数据本身也是编的（会话 id 是 sess_deadbeef…），
      可以安全地进公开仓库。
    * 合成数据里留一个未配对的 model.request.started，让截图落在「在飞」状态：
      绿点 + 计时走动 + 数字亮白，这是小窗信息量最大的样子。

  config.json 把 windowTitle 指到一个不存在的窗口，监控因此不做任何跟随动作、
  窗口稳定可见（PORTABILITY.md 验收矩阵 P8 的场景），截图不会因为前台切换而抓空。

  用法：powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\capture-overlay.ps1
  产物：docs\images\overlay-zh.png、docs\images\overlay-en.png
#>
[CmdletBinding()]
param(
  # 输出目录，默认仓库根的 docs\images
  [string]$OutDir,
  # 每张截图前等待窗口画完的毫秒数
  [int]$SettleMs = 3000
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Monitor = Join-Path $RepoRoot 'zcode-tps\monitor\tps-monitor.ps1'
if (-not (Test-Path -LiteralPath $Monitor)) { throw "找不到监控脚本：$Monitor" }
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'docs\images' }
[void](New-Item -ItemType Directory -Path $OutDir -Force)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# 截图进程必须与监控进程一样是 DPI 感知的，否则 GetWindowRect 拿到的物理像素
# 与 Bitmap 的尺寸对不上（200% 缩放下会只抓到左上四分之一）。
Add-Type -Namespace TpsShot -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
public delegate bool EnumProc(IntPtr h, IntPtr p);
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
[void][TpsShot.Native]::SetProcessDPIAware()

# 按标题找小窗。这里刻意不用 FindWindow：PowerShell 把 $null 绑定到 string 形参时
# 传的是空串而不是 NULL，FindWindow(null, title) 会去找「类名为空」的窗口，恒返回 0
# （2026-09-29 实测）。EnumWindows + GetWindowText 精确比较没有这个坑。
function Find-TpsWindow {
  param([string]$Title)
  $script:FoundHwnd = [IntPtr]::Zero
  $cb = [TpsShot.Native+EnumProc] {
    param([IntPtr]$h, [IntPtr]$p)
    $sb = New-Object System.Text.StringBuilder 256
    [void][TpsShot.Native]::GetWindowText($h, $sb, 256)
    if ($sb.ToString() -eq $Title) { $script:FoundHwnd = $h; return $false }
    return $true
  }
  [void][TpsShot.Native]::EnumWindows($cb, [IntPtr]::Zero)
  return $script:FoundHwnd
}

# PrintWindow 会把窗口 Region 之外（四个圆角）的像素画成不透明黑。把圆角外的像素
# 置为全透明，README 在浅色主题下才不会出现四个黑角。半径从截图像素宽度反推，
# 不写死数字：小窗圆角是 Px 6，Px 按 DpiX/96 缩放，所以 432px 宽的截图半径是 12。
function Set-RoundedAlpha {
  param([System.Drawing.Bitmap]$Bitmap)
  $rad = 6.0 * ($Bitmap.Width / 216.0)
  $w = $Bitmap.Width
  $h = $Bitmap.Height
  $r = [int][Math]::Ceiling($rad)
  $clear = [System.Drawing.Color]::FromArgb(0, 0, 0, 0)
  $cornerX = @(0, ($w - $r))
  $cornerY = @(0, ($h - $r))
  foreach ($cx in $cornerX) {
    foreach ($cy in $cornerY) {
      for ($y = 0; $y -lt $r; $y++) {
        for ($x = 0; $x -lt $r; $x++) {
          $px = $cx + $x
          $py = $cy + $y
          $ox = ($px + 0.5) - ($w - $rad)
          $oy = ($py + 0.5) - ($h - $rad)
          if ($cx -eq 0) { $ox = $rad - ($px + 0.5) }
          if ($cy -eq 0) { $oy = $rad - ($py + 0.5) }
          if ($ox -gt 0 -and $oy -gt 0 -and ($ox * $ox + $oy * $oy) -gt ($rad * $rad)) {
            $Bitmap.SetPixel($px, $py, $clear)
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------- 合成数据
$Root = Join-Path $env:TEMP ('zcode-tps-shot-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$LogDir = Join-Path $Root 'log'
$RolloutDir = Join-Path $Root 'rollout'
$StateDir = Join-Path $Root 'state'
foreach ($d in @($Root, $LogDir, $RolloutDir, $StateDir)) {
  [void](New-Item -ItemType Directory -Path $d -Force)
}

$Sid = 'sess_deadbeef-0000-4000-8000-000000000000'
$NoBom = New-Object System.Text.UTF8Encoding($false)

# 34 条历史记录，速率在 40–95 之间起伏，让柱状图铺满且有形状。
# 最后 5 条换成另一个 turnId：turnOut 在 turnId 变化时归零（tps-monitor.ps1
# 的 Add-Record），这样截图里的「本轮」小于「累计」，一眼能看出两行不是同一个数。
# 字段顺序必须满足 tps-monitor 的切片正则（见 tests\follow-test.ps1 的说明）。
$rolloutPath = Join-Path $RolloutDir "model-io-$Sid.jsonl"
$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 34; $i++) {
  $tps = 40 + 28 * [Math]::Sin($i / 3.1) + 18 * [Math]::Sin($i / 1.7) + (($i * 7) % 11)
  $dur = 1800 + (($i * 137) % 1400)
  $out = [int]($tps * $dur / 1000)
  $at = [DateTime]::UtcNow.AddSeconds(-($i + 1) * 21)
  $turn = 'turn_demo_prev'
  if ($i -ge 29) { $turn = 'turn_demo_live' }
  [void]$sb.AppendLine(
    '{"completedAt":"' + $at.ToString('o') + '","durationMs":' + $dur +
    ',"model":{"modelId":"GLM-5.3-Flash"},"response":{"usage":{"outputTokens":' + $out +
    ',"reasoningTokens":0}},"type":"model_io","sessionId":"' + $Sid +
    '","turnId":"' + $turn + '","querySource":"main_turn"}')
}
[System.IO.File]::WriteAllText($rolloutPath, $sb.ToString(), $NoBom)
(Get-Item -LiteralPath $rolloutPath).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(-40)

$logPath = Join-Path $LogDir 'zcode-demo.jsonl'
$logLines = New-Object System.Collections.Generic.List[string]
# 用户意图：让归属稳定落在 $Sid 上（否则会走 mtime 兜底，source 不同但显示一样）
$logLines.Add('{"timestamp":"' + [DateTime]::UtcNow.AddSeconds(-45).ToString('o') +
  '","level":"info","event":"turn.started","module":"demo","message":"demo","sessionId":"' + $Sid + '"}')
# 在飞：只有 started 没有配对的 completed → 绿点 + 计时走动
$logLines.Add('{"timestamp":"' + [DateTime]::UtcNow.AddSeconds(-4.5).ToString('o') +
  '","level":"info","event":"model.request.started","module":"demo","message":"demo","sessionId":"' + $Sid + '"}')
[System.IO.File]::WriteAllText($logPath, ($logLines -join "`n") + "`n", $NoBom)

# 合成一个 ZCode 数据目录，只放 db/db.sqlite。两个作用：
#   1. config.zcodeHome 指向它，标题 sidecar（tps-sidecar.mjs）读的是这份假库，
#      截图里不会出现你真实的会话标题；
#   2. 截图能落在「元信息首行右列显示会话标题」的样子，而不是无 node 时的 req 计数兜底。
# 没有 node 时跳过：标题取不到，截图自动退回 req 计数，工具仍然可用。
$ZHome = Join-Path $Root 'zcode'
$DbDir = Join-Path $ZHome 'db'
[void](New-Item -ItemType Directory -Path $DbDir -Force)
$DbPath = Join-Path $DbDir 'db.sqlite'
$DemoTitle = '实时显示 TPS 小窗'
$nodeOk = $false
try {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($node) {
    $mk = @"
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(process.argv[1]);
db.exec('CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, time_updated INTEGER)');
const ins = db.prepare('INSERT INTO session (id, title, time_updated) VALUES (?, ?, ?)');
ins.run(process.argv[2], process.argv[3], Date.now());
ins.run('sess_00000000-0000-4000-8000-000000000001', '另一条演示会话', Date.now() - 600000);
"@
    & node -e $mk $DbPath $Sid $DemoTitle 2>&1 | Out-Null
    $nodeOk = (Test-Path -LiteralPath $DbPath)
  }
}
catch { $nodeOk = $false }
if ($nodeOk) { Write-Host "  合成 db.sqlite：标题「$DemoTitle」" }
else { Write-Host '  没找到可用的 node（或 node:sqlite 不可用）：截图将显示 req 计数兜底' }

function Save-Shot {
  param([string]$Language, [string]$Path)

  # 语言走 config.json（监控启动时读，见 PORTABILITY.md §2 L2）；
  # windowTitle 指向不存在的窗口 → 不跟随、不隐藏，截图稳定；
  # zcodeHome 指向合成目录 → 标题 sidecar 读假库，不碰真实数据。
  $cfg = @{
    language         = $Language
    windowTitle      = '___zcode_tps_screenshot_no_such_window___'
    followForeground = $false
    zcodeHome        = $ZHome
  } | ConvertTo-Json
  [System.IO.File]::WriteAllText((Join-Path $StateDir 'config.json'), $cfg, $NoBom)

  $mon = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Monitor,
    '-Opacity', '1', '-NoWatchdog',
    '-LogDir', $LogDir, '-RolloutDir', $RolloutDir, '-StateDir', $StateDir
  )
  try {
    $hwnd = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
      $hwnd = Find-TpsWindow -Title 'ZCode TPS'
      if ($hwnd -ne [IntPtr]::Zero) { break }
      Start-Sleep -Milliseconds 200
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw "没等到小窗（语言 $Language）" }

    # 等第一轮数据解析 + 在飞计时走起来
    Start-Sleep -Milliseconds $SettleMs

    $r = New-Object -TypeName 'TpsShot.Native+RECT'
    if (-not [TpsShot.Native]::GetWindowRect($hwnd, [ref]$r)) { throw 'GetWindowRect 失败' }
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { throw "窗口尺寸异常：${w}x${h}" }

    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
      $hdc = $g.GetHdc()
      try {
        # PW_RENDERFULLCONTENT(2)：走 DWM 取窗口自身内容，不抓桌面
        $ok = [TpsShot.Native]::PrintWindow($hwnd, $hdc, 2)
      }
      finally { $g.ReleaseHdc($hdc) }
      if (-not $ok) {
        # 退化路径：PrintWindow 被拒时抓屏幕。窗口是 topmost，正常情况下不会被遮。
        $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
      }
    }
    finally { $g.Dispose() }

    Set-RoundedAlpha -Bitmap $bmp
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("  写出 {0}  ({1}x{2})" -f (Split-Path -Leaf $Path), $w, $h)
  }
  finally {
    # 用哨兵文件正常退出（README「启停与卸载」的路径），杀进程只是兜底
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'stop.flag'), 'stop', $NoBom)
    if (-not $mon.WaitForExit(4000)) {
      Stop-Process -Id $mon.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 300
  }
}

try {
  Write-Host "临时目录：$Root"
  Save-Shot -Language 'zh-CN' -Path (Join-Path $OutDir 'overlay-zh.png')
  Save-Shot -Language 'en-US' -Path (Join-Path $OutDir 'overlay-en.png')
}
finally {
  Start-Sleep -Milliseconds 300
  Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host '完成。'
