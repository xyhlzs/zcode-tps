#Requires -Version 5.1
<#
  ZCode TPS · 主题解析测试（VISUAL.md §8）

  用 -Headless 监控子进程断言 status.json 的 theme 字段（生效主题）：
    1  命令行 -Theme 优先于 config.theme
    2  config.theme = dark / light 原样生效
    3  auto（无配置）读系统注册表 AppsUseLightTheme，与本测试独立读到的
       系统值一致——即"跟随系统深浅色"的判定正确
    4  config.theme 非法值回落 auto（与 Opacity 钳制同一哲学）

  测试不写注册表：auto 场景的期望值由测试自己读注册表得出，两边比对。

  用法：powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\theme-test.ps1
  退出码：0 = 全部通过，1 = 有失败。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Monitor = Join-Path $RepoRoot 'monitor\tps-monitor.ps1'
$Root = Join-Path $env:TEMP ('zcode-tps-theme-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$LogDir = Join-Path $Root 'log'; $RolloutDir = Join-Path $Root 'rollout'
foreach ($d in @($LogDir, $RolloutDir)) { [void](New-Item -ItemType Directory -Path $d -Force) }
$NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Fail = 0
$script:Pass = 0

function Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) { Write-Host ('  PASS  ' + $Name); $script:Pass++ }
  else { Write-Host ('  FAIL  ' + $Name + $(if ($Detail) { "   <- $Detail" } else { '' })); $script:Fail++ }
}

function Get-SystemTheme {
  # 与 tps-monitor.ps1 的 Get-SystemThemeName 同一判据，独立实现一遍：
  # 测试的意义就在于两边互证，而不是引用被测代码
  try {
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
      'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize')
    if ($k) {
      $v = $k.GetValue('AppsUseLightTheme')
      $k.Close()
      if ($v -is [int] -and $v -eq 1) { return 'light' }
    }
  } catch { }
  return 'dark'
}

function Invoke-MonitorRun {
  # 跑一次 -Seconds 1 的无头监控，返回写出的 status.json（等进程退出后读，值已定稿）
  param([string]$StateDir, [string]$ConfigJson = '', [string[]]$ExtraArgs = @())

  [void](New-Item -ItemType Directory -Path $StateDir -Force)
  if ($ConfigJson) {
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'config.json'), $ConfigJson, $NoBom)
  }
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Monitor,
    '-Headless', '-Seconds', '1', '-LogDir', $LogDir, '-RolloutDir', $RolloutDir,
    '-StateDir', $StateDir) + $ExtraArgs
  $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList $argv
  if (-not $p.WaitForExit(30000)) { $p.Kill(); return $null }
  $path = Join-Path $StateDir 'status.json'
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

try {
  Write-Host ''
  Write-Host "临时目录：$Root"
  $sysTheme = Get-SystemTheme
  Write-Host "系统当前主题（测试独立读取）：$sysTheme"

  Write-Host ''
  Write-Host '场景 1：命令行 -Theme 优先于 config.theme'
  $s = Invoke-MonitorRun -StateDir (Join-Path $Root 'cli-overrides-config') `
    -ConfigJson '{"theme":"dark"}' -ExtraArgs @('-Theme', 'light')
  Check 'status.json 已写出' ($null -ne $s)
  Check '生效主题为 light（命令行胜出）' ($s -and $s.theme -eq 'light') ('theme=' + $s.theme)

  Write-Host ''
  Write-Host '场景 2：config.theme 显式值原样生效'
  $s = Invoke-MonitorRun -StateDir (Join-Path $Root 'cfg-dark') -ConfigJson '{"theme":"dark"}'
  Check 'config dark → dark' ($s -and $s.theme -eq 'dark') ('theme=' + $s.theme)
  $s = Invoke-MonitorRun -StateDir (Join-Path $Root 'cfg-light') -ConfigJson '{"theme":"light"}'
  Check 'config light → light' ($s -and $s.theme -eq 'light') ('theme=' + $s.theme)

  Write-Host ''
  Write-Host '场景 3：auto 跟随系统注册表'
  $s = Invoke-MonitorRun -StateDir (Join-Path $Root 'auto')
  Check 'status.json 已写出' ($null -ne $s)
  Check "auto → 系统当前值（$sysTheme）" ($s -and $s.theme -eq $sysTheme) ('theme=' + $s.theme)

  Write-Host ''
  Write-Host '场景 4：非法值回落 auto'
  $s = Invoke-MonitorRun -StateDir (Join-Path $Root 'cfg-bogus') -ConfigJson '{"theme":"midnight"}'
  Check "config 'midnight' → 回落 auto（$sysTheme）" ($s -and $s.theme -eq $sysTheme) ('theme=' + $s.theme)

  Write-Host ''
  Write-Host "通过 $($script:Pass)，失败 $($script:Fail)"
} finally {
  Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:Fail -gt 0) { exit 1 }
exit 0
