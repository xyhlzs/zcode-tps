#Requires -Version 5.1
<#
  守卫硬约束：所有 .ps1 必须是 UTF-8 with BOM。

  PS 5.1 读无 BOM 的 .ps1 时按 ANSI（中文系统上是 GBK）解析，中文注释和字符串会
  乱码甚至断串——PORTABILITY.md §2 L5.2 把「保持 BOM」列为硬约束，§5 记了实际踩坑。
  .gitattributes 里的 `*.ps1 -text` 保证 git 不改写这些字节，这个脚本负责拦住
  「文件本身就没 BOM」以及被编辑器悄悄去 BOM 的情况。

  用法：powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\check-bom.ps1
  退出码：0 = 全部合规，1 = 有文件缺 BOM。
#>
[CmdletBinding()]
param(
  # 扫描根目录，默认仓库根
  [string]$Root
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$bad = @()
$files = Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.ps1' -File |
  Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' }

foreach ($f in $files) {
  $fs = [System.IO.File]::OpenRead($f.FullName)
  try {
    $b = New-Object byte[] 3
    $n = $fs.Read($b, 0, 3)
  }
  finally { $fs.Dispose() }
  if (-not ($n -eq 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
    $bad += $f.FullName
  }
}

if ($bad.Count -gt 0) {
  Write-Host "以下 $($bad.Count) 个 .ps1 缺少 UTF-8 BOM："
  $bad | ForEach-Object { Write-Host ('  ' + $_) }
  Write-Host ''
  Write-Host '修法（PowerShell）：'
  Write-Host '  $p = ''<路径>'''
  Write-Host '  [System.IO.File]::WriteAllText($p, [System.IO.File]::ReadAllText($p), (New-Object System.Text.UTF8Encoding($true)))'
  exit 1
}

Write-Host ("OK：{0} 个 .ps1 全部是 UTF-8 with BOM。" -f $files.Count)
exit 0
