---
description: 启动或停止 ZCode TPS 监控小窗
argument-hint: start | stop
allowed-tools: Bash
---

用 Bash 工具执行 PowerShell，管理 TPS 监控守护进程。状态目录固定为
`$env:LOCALAPPDATA\ZCodeTpsMonitor`。用户参数：$ARGUMENTS

按参数执行；不带参数时按 start 处理。

## start

1. 读状态目录下 `status.json` 的 `pluginRoot` 字段；存在且该目录仍在时，
   监控脚本就是 `<pluginRoot>\monitor\tps-monitor.ps1`。
2. `status.json` 不存在或 `pluginRoot` 失效时，在
   `$env:USERPROFILE\.zcode\cli\plugins\cache` 下递归查找插件 `zcode-tps` 的
   `monitor\tps-monitor.ps1`，取找到的路径。
3. 用脱离当前会话的方式启动（守护进程自带命名互斥体单实例保证，重复启动无害，
   多起的进程会立刻自灭）：

   ```powershell
   Start-Process powershell.exe -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File','<脚本路径>'
   ```

正常情况下无需手动 start：SessionStart hook 会在首个会话启动时自动拉起监控。

## stop

写哨兵文件，监控在下一个刷新周期（≤400ms）自行退出并删除该文件：

```powershell
New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCALAPPDATA 'ZCodeTpsMonitor') | Out-Null
Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'ZCodeTpsMonitor\stop.flag') -Value stop
```

退出是异步的，不要用杀进程的方式停止。停止后再 start 会恢复显示、沿用上次窗口位置。

## 其他参数

向用户说明用法：`/tps start` 启动监控小窗，`/tps stop` 停止。
