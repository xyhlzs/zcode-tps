## 改了什么

<!-- 一句话说清这个 PR 解决了什么问题。 -->

## 为什么

<!-- 如果修的是 bug，写清根因；如果加的是功能，写清使用场景。 -->

## 自查

- [ ] 本地跑过 `zcode-tps\tests\follow-test.ps1`，退出码 0
- [ ] 本地跑过 `tools\check-bom.ps1`，退出码 0
- [ ] 新增 / 修改的 `.ps1` 是 **UTF-8 with BOM**（PS 5.1 无 BOM 会把中文按 ANSI 解析）
- [ ] 改了行为的话，同步更新了 `CHANGELOG.md`
- [ ] 改了版本的话，`marketplace.json` 与 `zcode-tps/.zcode-plugin/plugin.json` 两处一致

## 影响面

- [ ] 只改文档 / 仓库工程（不影响插件运行时行为）
- [ ] 改了小窗显示或数据管线（说明怎么验证的）
- [ ] 改了会话跟随判定（必须跑回归测试，并在下面贴结果）
