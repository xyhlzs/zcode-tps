#Requires -Version 5.1
<#
  SessionStart hook：确保 TPS 监控守护进程在跑。
  单实例由守护进程自己用命名互斥体保证，这里重复启动是安全的（多起一个进程立刻退出）。
  必须立刻返回，所以用 Start-Process 脱离父进程后再 exit。

  注意：这里刻意不传 -SessionId。
  守护进程是常驻的、单实例的，一旦把目标钉死在 SessionStart 时那个会话，之后切换会话
  就不会跟随了。传会话 id 只适合手动排查。跟随逻辑见 tps-monitor.ps1 的 Resolve-TargetFile。

  拉起必须用 CreateNoWindow（CREATE_NO_WINDOW），不能用 Start-Process：
  后者走 ShellExecute，控制台先以可见状态创建、等 PS 启动后才被 -WindowStyle Hidden
  藏起来——每个会话启动都会闪一次黑框。CREATE_NO_WINDOW 从创建起就无窗口，
  也不写 STARTUPINFO 的 wShowWindow，WinForms 小窗首次 Show 不受影响；
  -WindowStyle Hidden 参数保留作兜底。
#>
$ErrorActionPreference = 'SilentlyContinue'

# 非 Windows 静默退出：监控是 WinForms + user32 实现，跨平台明确不支持
# （PORTABILITY.md §1.1）。hook 报错会打扰每个会话启动，所以必须无声。
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { exit 0 }

$root = $env:CLAUDE_PLUGIN_ROOT
if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
$monitor = Join-Path $root 'monitor\tps-monitor.ps1'
if (-not (Test-Path -LiteralPath $monitor)) { exit 0 }

$argLine = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$monitor`""

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = $argLine
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
[void][System.Diagnostics.Process]::Start($psi)
exit 0
