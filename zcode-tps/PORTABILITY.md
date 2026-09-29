# 可迁移性设计：让别的用户下载即用

目标：另一个用户在他的 Windows 机器上通过 marketplace 安装本插件后，
不需要改任何代码、不需要中文系统环境，就能获得与本机一致的行为；
卸载插件后机器上不留活进程。

非目标：跨平台（macOS/Linux 的 ZCode 不支持 WinForms 小窗，明确不支持）；
自动更新（交给 marketplace 机制）；兼容 ZCode 未发布版本的内部格式变更
（只保证**优雅降级**，不保证功能不坏）。

本文档只写结论和方案，实现拆解放最后。标注「实测」的已有依据；没标注的是推断。

---

## 1. 迁移面盘点：换一台机器，什么会变

### 1.1 环境类

| 变量 | 现状假设 | 会怎么坏 |
|---|---|---|
| 操作系统 | WinForms + user32 P/Invoke，**仅 Windows** | macOS 的 ZCode 触发 hook 后 powershell.exe 不存在（或跑不起来），hook 报错 |
| PowerShell 语言模式 | `Add-Type` 编译 C#（DPI/窗口 API） | 企业环境的**受限语言模式（CLM）**下 Add-Type 被禁：置顶断言、窗口跟随、WS_EX_NOACTIVATE 全部失效，但脚本不崩（都有 try/catch）——小窗会出现但行为退化，用户不知道为什么 |
| 执行策略 | `-ExecutionPolicy Bypass` 已处理 | 下载带来的 MOTW（Mark of the Web）在 Bypass 下可跑，一般无碍；企业杀软拦 `powershell -File` 时无解，文档写明即可 |
| 系统语言 | 全部界面文案是中文硬编码 | 英文用户看到中文小窗；可接受但不像「给用户用」的产品 |
| 字体 | Segoe UI + 中文回退雅黑（系统自带）、Cascadia → Consolas 回退链已实现 | 无需处理 |
| DPI / 多屏 | PER_MONITOR_AWARE_V2 + Px() 缩放已实现 | 无需处理 |
| 数字格式 | `{0:N1}` 等用当前文化 | 各 locale 显示各自的小数/分组符，**是正确行为**，但解析 status.json 的工具要注意（旁路产物，可不管） |

### 1.2 安装与生命周期类

| 变量 | 现状行为 | 问题 |
|---|---|---|
| 插件缓存路径 | 脚本用 `${CLAUDE_PLUGIN_ROOT}`（有 `$PSScriptRoot` 兜底），路径带空格/中文用户名时参数已加引号 | 基本无碍 |
| **卸载残留** | 监控是脱离父进程的常驻守护，`SessionStart` 只管拉起 | **用户卸载插件后，监控还活着**，直到 ZCode 窗口关闭才退出。这是当前最大的迁移缺陷：装的时候无感，卸的时候甩不掉 |
| 无 hook 触发的场景 | 无 | 用户手动禁用了 hook、或 ZCode 版本不触发 SessionStart 时，没有任何手动启动入口 |
| 用户偏好 | `-Opacity` 只能改命令行（hook 里写死） | 普通用户没有改 hook 参数的途径；语言、主题同理 |

### 1.3 ZCode 侧

| 变量 | 现状假设 | 会怎么坏 |
|---|---|---|
| ZCode 数据目录 | 写死 `%USERPROFILE%\.zcode\cli` | 若 ZCode 提供 `ZCODE_HOME` 类环境变量或自定义安装，rollout/log 就找不到——监控永远显示「未找到 rollout 文件」 |
| 窗口识别 | 标题 == `ZCode` 且进程名 == `ZCode`，取第一个可见命中 | 进程名随安装渠道（安装器/便携 zip/包管理器）可能不同；未来版本改标题即失效。失效后果是温和的（跟随不动、不误关），但「跟随 ZCode」这一卖点直接消失 |
| rollout / log 内部格式 | 正则切片依赖字段顺序，注释已声明「无官方保证」 | ZCode 更新后解析失败 → 界面显示「已读 N 行，0 条可识别」，不崩。已有降级，补一条**版本适配声明**（README 记录实测通过的 ZCode 版本）即可 |
| 多个 ZCode 窗口 | 取第一个可见命中 | 实测单窗口；多开（若未来支持）跟随语义未定义，风险记录在案 |

---

## 2. 方案

### L1 环境守门与降级声明

1. **OS 守门**：`session-start.ps1` 开头判平台，非 Windows 静默 `exit 0`（不报错、不弹窗——hook 报错会打扰每个会话启动）。
2. **CLM 探测**：监控启动时 `$ExecutionContext.SessionState.LanguageMode` 检测；受限模式下照常跑（纯 .NET 调用大多可用），但小窗页脚显示「精简模式（系统策略限制）」，README 说明此时窗口跟随/置顶自愈不可用。把「静默退化」变成「可见的退化」。
3. README 增加最小环境声明：Windows 10+、PowerShell 5.1+、已实测的 ZCode 版本号。

### L2 配置文件

新增 `%LOCALAPPDATA%\ZCodeTpsMonitor\config.json`（监控启动时读，命令行参数**优先于**配置文件，便于排查时覆盖）：

```json
{
  "language": "auto",          // auto | zh-CN | en-US
  "opacity": 0.85,             // 0.3-1.0
  "zcodeHome": "",             // 空 = 默认 %USERPROFILE%\.zcode\cli
  "windowTitle": "ZCode",      // ZCode 窗口匹配（标题）
  "windowProcess": "ZCode",    // ZCode 窗口匹配（进程名）
  "followForeground": true     // false = ZCode 不在前台也不隐藏小窗
}
```

原则：**只放「不同用户会真的不同」的项**。主题（深色）是设计决定，不开放；
位置已有 pos.txt；轮询间隔之类调参项走命令行（测试用），不进配置。

### L3 界面文案 i18n

界面字符串共约 12 条（页脚状态文案、单位标签、错误前缀）。收进一张字符串表，
按优先级取：config.language → `Get-UICulture` → en 兜底。只做 zh-CN / en-US
两份；其他 locale 落到英文。字符串表就是脚本内两个 hashtable，不引入资源文件。

### L4 生命周期补全（本方案的重点）

1. **卸载毒丸**：监控启动时记录自己的插件根目录（`$PSScriptRoot` 的上级），
   之后每 2s 检查一次该目录是否还存在——**目录消失（插件被卸载/缓存被清）→
   监控退出并清掉 pos.txt/status.json/config.json**。
   - 只在 GUI 模式启用（`-Headless` 关闭），受控测试用 `-NoWatchdog` 开关豁免，
     避免测试副本目录被清导致用例误杀。
   - 已解析的脚本不依赖文件句柄，目录删除不会让运行中的 PS 报错，实测风险低。
2. **手动启动/停止入口**：插件增加 slash command `/tps`（子命令 `start` / `stop`）：
   - `start`：同 hook 的拉起逻辑（互斥体保证幂等）；
   - `stop`：写哨兵文件 `%LOCALAPPDATA%\ZCodeTpsMonitor\stop.flag`，监控每 tick
     检查到即退出并删除该文件。避免引入命名事件/IPC——文件就是最低公分母的 IPC。
   - 实现时需用 plugin-creator 核对 plugin.json 的 commands 字段格式（当前清单只有 hooks）。

### L5 打包与分发

1. **真实 marketplace**：仓库根的 `marketplace.json` 目前是本地测试用
   （`name: dev-zcode-tps-local`，source 指相对目录）。发布 = 把仓库推到 GitHub，
   marketplace.json 补上仓库地址后，其他用户「添加 marketplace → 安装」两步完成。
   版本号随每次变更递增，changelog 记在 RELEASES 或 README。
2. **编码红线**：所有 .ps1 必须保持 **UTF-8 with BOM**（PS 5.1 无 BOM 时中文注释
   和字符串会按 ANSI 解析，直接乱码）。 marketplace 打包走 zip 时字节原样保留，
   但任何「在网页上复制脚本」的安装方式都会坏——README 明确只支持 marketplace 安装。
3. **双语 README**：顶部加英文 Quickstart（安装两步 + 截图），正文维持中文。
   截图由 `tools/capture-overlay.ps1` 用合成数据生成（`-Opacity 1` + PrintWindow
   按窗口句柄抓取，不抓桌面，所以不会带进宿主窗口内容）。
4. **清单字段**：`plugin.json` / `marketplace.json` 的官方规范（plugin-creator 的
   plugin-json-spec.md）只定义了 `name` / `version` / `description` / `author` /
   `skills` / `commands` / `hooks` / `mcpServers`，以及市场条目的
   `displayName` / `displayName_i18n` / `description_i18n` / `category`。
   **没有 `license` / `keywords` / `repository` 字段**，本机也没有 zcode CLI 可以
   验证未知字段是否被接受。因此没有往清单里塞这些字段——许可证放在仓库根的
   `LICENSE`（MIT），由 GitHub 识别；宁缺勿滥，避免未知字段让清单校验失败。

---

## 3. 验收矩阵

状态标注为 2026-09-29 本机（Win11、200% DPI、zh-CN、ZCode 运行中）实测结果：

| # | 场景 | 验收 | 状态 |
|---|---|---|---|
| P1 | 全新 Win11 + zh-CN，marketplace 安装 | 装完首个会话启动即出现小窗，零手工步骤 | ✅ 链路实测：hook 拉起 0→1，stop.flag 收尾 1→0（DPI 2.0 下渲染锐利） |
| P2 | en-US 系统 | 界面文案为英文；数字格式随 locale | ✅ `config.language=en` 冒烟截图核对 |
| P3 | 100% / 150% / 200% DPI | 数字锐利、布局无重叠（现有能力回归） | ✅ 本机 200% 实测；100%/150% 靠同一套缩放代码，未逐档实测 |
| P4 | 受限语言模式（CLM） | 不崩；小窗标注精简模式；数据功能正常 | ⚠️ **本机无法模拟**：PS 5.1 只随 WDAC 策略启用 CLM，`__PSLockdownPolicy` 环境变量被忽略（实测 Mode 仍为 FullLanguage）。检测与降级逻辑已实现但未在真 CLM 下验证 |
| P5 | 卸载插件 | ≤5s 内监控进程消失，`%LOCALAPPDATA%\ZCodeTpsMonitor` 清空 | ✅ 副本目录删除后 ≤4s 退出，状态文件清空 |
| P6 | `/tps stop` | 监控退出；再 `/tps start` 恢复 | ✅ stop.flag 路径实测（命令 Markdown 本体需安装后人工验证） |
| P7 | ZCode 窗口标题/进程名与预期不符（config 改写后） | 跟随恢复 | ✅ 错标题 → `zcodeWin=none`（不跟随不误关）；正确标题 → 正常跟随 |
| P8 | 无 ZCode 裸跑监控 | 不误退出、不误关（现有行为回归） | ✅ 同 P7 错标题场景（从未找到窗口时不动作） |
| P9 | 脚本被下载后带 MOTW | 可运行（Bypass） | ✅ 带 Zone.Identifier 的副本正常跑完自检 |
| P10 | 仓库工程化：清单可解析、版本号两处一致、`.ps1` 带 BOM | CI 全绿 | ✅ 规则已落到 `.github/workflows/ci.yml`；本机 `tools\check-bom.ps1` 与回归测试均通过 |

---

## 4. 实现拆解（按提交切）

1. `session-start.ps1` OS 守门 + CLM 探测与「精简模式」标注（L1）。
2. config.json 读取与参数合并逻辑（L2），`-Opacity` 等改从合并后取值。
3. 字符串表 + 语言选择（L3）。
4. 毒丸与 stop.flag（L4-1），`-NoWatchdog` 开关。
5. `/tps` command（L4-2，manifest 字段先经 plugin-creator 核对）。
6. README 双语 quickstart + 环境声明 + ZCode 版本适配记录（L5）。
7. marketplace.json 发布化（L5，配合仓库公开）——**未做**：需要仓库的真实 GitHub
   地址，见 CONTRIBUTING.md 的「首次发布到 GitHub」。
8. 仓库工程化（在 L1–L5 之外补的一层，让仓库本身可协作）：
   `.gitattributes`（LF 统一 + `*.ps1 -text` 保住 BOM）、`.gitignore`、`LICENSE`、
   根 `README.md`、`CHANGELOG.md`、`CONTRIBUTING.md`、`.editorconfig`、
   `.github/workflows/ci.yml`、issue / PR 模板、`tools/capture-overlay.ps1`
   （README 截图）、`tools/check-bom.ps1`（BOM 守卫）。

每步独立可回退；1–4 不改任何现有默认行为，P1 场景在每步后必须保持通过。

## 5. 风险与开放问题

| 风险 | 处置 |
|---|---|
| 毒丸误杀：脚本放在可被清理的临时目录时（本仓冒烟测试即如此）监控会退出 | `-NoWatchdog` 豁免；README 写明「常驻运行请走 marketplace 安装路径」 |
| ZCode 是否有官方的数据目录环境变量未考证 | 有则 config.zcodeHome 默认值改为读它；没有则保持默认路径 |
| commands 字段的 manifest 语法未验证 | 已按 plugin-creator 规范核对（Markdown + frontmatter，`$ARGUMENTS`）；**运行时行为仍需安装后人工验证** |
| en 文案在 8pt 下的宽度与 zh 不同 | 已实测：en 冒烟截图无重叠（最长串 `No generation data in this session yet` 在元信息行宽内） |
| CLM 下的探测本身可用性 | `LanguageMode` 读取在 CLM 下允许；若连检测都失败按「受限」处理 |
| **CLM 降级深度被低估**：§2 L1 假设「纯 .NET 调用大多可用」，但真 CLM 的类型白名单可能连 `FileStream`/`Mutex` 都拦，降级会比设计更深（数据管线也可能失效） | P4 本机无法模拟（见验收矩阵）。若真机验证发现数据管线失效，精简模式的含义要扩大，届时重新评估 |
| 测试脚本自身踩了 BOM 坑（无 BOM 的 .ps1 含中文在 PS5.1 下乱码断串，2026-09-29 实测撞上） | 插件自带的 .ps1 全部已带 BOM（已核对）；`.gitattributes` 的 `*.ps1 -text` + `tools\check-bom.ps1` + CI 三重守卫，给仓库外发脚本时保持 BOM 是硬约束 |
| 仓库尚无 GitHub remote，README 徽章、issue 模板里的链接、`marketplace.json` 的市场名都还指向本地形态 | 已在 CONTRIBUTING.md 写清「首次发布到 GitHub」清单（改分支名、加 remote、补徽章、改市场名）；发布前一次改到位 |
| 清单的 `license` / `keywords` / `repository` 字段无官方规范可依，本机也无 zcode CLI 可验证未知字段是否被接受 | 不塞未知字段（见 §2 L5.4）；许可证只放仓库根 `LICENSE`，待能验证后再补清单字段 |
