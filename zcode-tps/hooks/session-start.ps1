#Requires -Version 5.1
<#
  SessionStart hook：确保 TPS 监控守护进程在跑。
  单实例由守护进程自己用命名互斥体保证，这里重复启动是安全的（多起一个进程立刻退出）。
  必须立刻返回，所以用 Start-Process 脱离父进程后再 exit。

  注意：这里刻意不传 -SessionId。
  守护进程是常驻的、单实例的，一旦把目标钉死在 SessionStart 时那个会话，之后切换会话
  就不会跟随了。传会话 id 只适合手动排查。跟随逻辑见 tps-monitor.ps1 的 Resolve-TargetFile。

  -WindowStyle Hidden 作为 powershell.exe 自身的参数传入（而不是 Start-Process 的开关），
  这样只隐藏控制台，WinForms 窗口照常显示，也避开 STARTUPINFO 首次 ShowWindow 的覆盖。
#>
$ErrorActionPreference = 'SilentlyContinue'

$root = $env:CLAUDE_PLUGIN_ROOT
if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
$monitor = Join-Path $root 'monitor\tps-monitor.ps1'
if (-not (Test-Path -LiteralPath $monitor)) { exit 0 }

$argLine = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$monitor`""

Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine
exit 0
