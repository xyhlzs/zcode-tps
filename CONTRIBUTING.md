# 贡献指南

这是一个 ZCode 插件：`SessionStart` hook 拉起一个常驻 PowerShell 守护进程，读 ZCode
落盘的 rollout / log 文件算 token 速率，画在一个置顶小窗上。

## 开发环境

| 需要 | 说明 |
|---|---|
| Windows 10+ | 小窗是 WinForms + user32 P/Invoke，只能在 Windows 上跑 |
| Windows PowerShell 5.1 | 系统自带。**不要**用 PowerShell 7 的 `pwsh` 验收——目标运行时是 5.1 |
| ZCode | 用来端到端验证跟随行为（版本记录在 [README 的环境表](README.md#环境与兼容性)） |
| Node.js | 可选，只用于插件脚手架脚本 |

## 目录结构

```
marketplace.json              本地/发布用插件市场清单（source 指向 zcode-tps/）
zcode-tps/                    插件本体，整个目录随 marketplace 分发
  .zcode-plugin/plugin.json   插件清单
  hooks/hooks.json            SessionStart hook 声明
  hooks/session-start.ps1     hook 入口：拉起守护进程后立刻返回
  monitor/tps-monitor.ps1     守护进程本体（约 1200 行，数据管线 + 小窗绘制）
  commands/tps.md             /tps start|stop 命令
  tests/follow-test.ps1       会话跟随回归测试
  README.md                   用户手册
  REQUIREMENTS.md             需求基线与验收标准
  DESIGN.md                   技术设计与实测依据
  VISUAL.md                   小窗视觉方案
  PORTABILITY.md              可迁移性设计与验收矩阵
tools/                        开发工具，不随插件分发
  capture-overlay.ps1         用合成数据生成 README 截图
  check-bom.ps1               .ps1 的 BOM 守卫
docs/images/                  README 截图
```

## 本地开发循环

改 `tps-monitor.ps1` 后要重启监控才生效（守护进程常驻，不会热加载）：

```powershell
# 1. 停掉在跑的实例（写哨兵文件，一个刷新周期内自己退出）
New-Item -ItemType Directory -Force -Path "$env:LOCALAPPDATA\ZCodeTpsMonitor" | Out-Null
Set-Content -LiteralPath "$env:LOCALAPPDATA\ZCodeTpsMonitor\stop.flag" -Value stop

# 2. 带窗口跑，方便看效果
powershell.exe -NoProfile -ExecutionPolicy Bypass -File zcode-tps\monitor\tps-monitor.ps1
```

排查时常用参数：`-Headless -Seconds 10`（无窗自检，写 `status.json`）、
`-SessionId sess_xxxx`（钉死某个会话）、`-LogDir` / `-RolloutDir` / `-StateDir`
（指向合成数据目录做受控测试）、`-NoWatchdog`（跳过卸载毒丸，用于临时副本）。

## 测试

```powershell
# 会话跟随回归测试：6 个场景 15 项断言，退出码 0 即全部通过
powershell.exe -NoProfile -ExecutionPolicy Bypass -File zcode-tps\tests\follow-test.ps1

# .ps1 的 BOM 守卫
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\check-bom.ps1
```

改了 `Resolve-TargetFile` 附近的归属判定，必须跑回归测试并在 PR 里贴结果。
回归测试用合成日志/rollout 驱动一个隔离的 `-Headless` 监控进程，不碰你的真实数据。

CI（[.github/workflows/ci.yml](.github/workflows/ci.yml)）在 windows-latest 上跑
清单 JSON 校验、版本号一致性、BOM 守卫和这个回归测试。

## 编码约定

- **`.ps1` 必须保持 UTF-8 with BOM**。这是硬约束：PS 5.1 读无 BOM 的脚本时按 ANSI
  解析，中文注释和字符串会乱码甚至断串。`.gitattributes` 的 `*.ps1 -text` 让 git 不改写
  这些字节，`.editorconfig` 和 `tools\check-bom.ps1` 负责拦住漏网的文件。
- **行尾 LF**，UTF-8，文件末尾留一个换行。
- 注释写「为什么」，不写「做了什么」——尤其是实测结论、被否决的方案、以及反直觉的
  取舍（例如为什么意图带 10 分钟有效期）。项目里大量注释是实测依据，改动时别顺手删。
- 界面文案走 `tps-monitor.ps1` 里的字符串表（zh-CN / en-US 两份），不要在绘制代码里
  写死中文。新增文案要同时补两个语言。
- 不引入新的外部依赖。目标运行时是系统自带的 PowerShell 5.1，没有包管理器。

## 提交约定

历史提交用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 前缀，
类型与作用域举例：

```
feat(portability): L2 config.json——语言/不透明度/窗口匹配可配置
fix(follow): 并发下按「用户意图 + 有效期」归属会话
docs: add portability design (PORTABILITY.md)
feat(ui): 按 VISUAL.md 重设计小窗
```

一个提交只做一件事。改行为的提交要同时更新 `CHANGELOG.md` 的 `Unreleased` 段。

## 版本与发布清单

版本号写在两处，**必须一致**（CI 会校验）：

- `zcode-tps/.zcode-plugin/plugin.json` 的 `version`
- `marketplace.json` 的 `plugins[0].version`

发一个版本：

1. 把 `CHANGELOG.md` 的 `Unreleased` 段改成新版本号加日期，并补上 compare 链接。
2. 两处 `version` 同步递增。
3. 提交，打 tag：`git tag v0.3.0 && git push origin main --tags`。
4. 用 GitHub 的 release 页面把 `CHANGELOG.md` 对应段落粘成 release notes。

## 首次发布到 GitHub

仓库目前只有本地 `main` 分支、没有 remote。要对外发布：

```bash
git remote add origin git@github.com:<owner>/zcode-tps.git
git push -u origin main
```

（本地分支已从 `master` 改名为 `main`，与 GitHub 默认分支名对齐。）

推送后别人「添加市场」时粘贴的就是仓库地址。ZCode 把它记在
`~/.zcode/cli/config.json` 的 `plugins.extraKnownMarketplaces` 下，GitHub 来源的形态是
`{"source": {"source": "github", "repo": "<owner>/<repo>"}}`——发布后可以拿它核对市场
有没有被正确识别。

推送后补两处，它们都需要仓库的真实地址：

- 根 `README.md` 顶部加 CI 徽章：
  `![CI](https://github.com/<owner>/zcode-tps/actions/workflows/ci.yml/badge.svg)`
- `.github/ISSUE_TEMPLATE/bug_report.yml` 里的排查指引改成指向本仓库 README。

`marketplace.json` 的 `name` 是 `zcode-tps`（与仓库名和插件名一致），用户添加市场后
在市场列表里看到的就是它。**发布后不要再改**：改名等于换了一个市场，已安装的用户
需要重新添加。如果以后这个仓库要托管多个插件，再考虑换成更宽泛的名字。
