> 2026-09-28 后续状态：新的 `cc-switch-isolated.ps1` 免安装隔离入口已经完成原生 GUI 保存与跨会话恢复测试（菜单 10 → 6）。本文普通 wrapper / 旧 Launch 未开放的结论属于早期路径；当前边界与验收以 [CC-Switch原生接入验收.md](CC-Switch原生接入验收.md) 为准。

# CC Switch 便携接入核查

## 结果

模块固定到 CC Switch `v3.20.4` Windows x64 Portable ZIP。官方发布页提供该 ZIP 的 SHA-256；本地下载和展开包使用同一个固定校验值。仓库许可证是 MIT。接入脚本的 `Prepare` 只接受这份固定版本、固定哈希和固定 ZIP 成员名，不运行安装器或 GUI，也不导入 provider 数据。

当前状态是 **`BlockedPortableIsolation`**。`portable.ini` 本身不证明配置便携。官方 Windows portable data-isolation PR #5373 已关闭但未合并；固定版本源码提供 `CC_SWITCH_TEST_HOME` 测试/调试覆盖以及应用目录设置。后续标准 Windows profile 结构的实测已修正早期推断：进程私有环境可让 RoamingAppData 和 LocalAppData 解析到受管目录，不能再声称 Tauri Store 必然留在宿主原目录。独立适配仍是可行候选，详见 `CC-Switch隔离验证.md`。

`Launch` 目前仍拒绝启动，准确原因是：尚未完成官方 GUI 各正常入口实际写入范围的验证，不能确认其只修改 U 盘 harness。路径计划、合成探针和配置导入验证均不能代替完整 GUI 验收。固定版本适配可以使用已核实的环境接口，但每次上游升级须重新检查，不能假定测试变量永远稳定。

便携 ZIP 的实际内容只有 `cc-switch.exe` 与 `portable.ini`，没有预建 `data` 子目录。CC Switch 自身数据目录与被管理工具的目录是两回事；固定版本设置支持 Claude Code、Codex、Gemini、Grok Build、OpenCode、OpenClaw、Hermes、Pi 的配置目录覆盖，适配层可以按源码格式在启动前预置。Claude Desktop 与 MiniMax Code 不在这组覆盖字段中，其他后端入口也需逐项核验。因此预置目录只表示准备了候选配置，不表示所有工具写入均已隔离。

## 官方来源

- [v3.20.4 Release Notes：Windows x64/ARM64 portable 下载](https://github.com/farion1231/cc-switch/blob/main/docs/release-notes/v3.20.4-en.md)
- [v3.20.4 官方发布资产与 SHA-256](https://github.com/farion1231/cc-switch/releases/expanded_assets/v3.20.4)
- [仓库 LICENSE（MIT）](https://github.com/farion1231/cc-switch/blob/main/LICENSE)
- [Windows portable data isolation PR #5373（关闭、未合并）](https://github.com/farion1231/cc-switch/pull/5373)
- [官方 README：默认数据位置与工具目录覆盖](https://github.com/farion1231/cc-switch/blob/main/README.md)
- [官方路径解析源码：Windows home 与 app config 根目录](https://github.com/farion1231/cc-switch/blob/main/src-tauri/src/config.rs)
- [官方 Tauri Store 源码：app config directory override](https://github.com/farion1231/cc-switch/blob/main/src-tauri/src/app_store.rs)
- [官方设置源码：设备级 config directory 字段](https://github.com/farion1231/cc-switch/blob/main/src-tauri/src/settings.rs)
- [官方设置界面源码：目录覆盖项](https://github.com/farion1231/cc-switch/blob/main/src/components/settings/DirectorySettings.tsx)
- [官方 provider 导入说明：Deep Link 或 SQL 数据库备份](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/en/2-providers/2.1-add.md)
- [官方设置说明：桌面应用的 SQL 数据库导出](https://github.com/farion1231/cc-switch/blob/main/docs/user-manual/en/1-getting-started/1.5-settings.md)
- [官方 Claude Desktop 配置实现（Claude JSON `env` 字段）](https://github.com/farion1231/cc-switch/blob/main/src-tauri/src/claude_desktop_config.rs)

## 固定版本

| 项目 | 值 |
| --- | --- |
| 上游项目 | `farion1231/cc-switch` |
| 版本 / 架构 | `3.20.4` / Windows x64 |
| 官方下载 | `https://github.com/farion1231/cc-switch/releases/download/v3.20.4/CC-Switch-v3.20.4-Windows-Portable.zip` |
| 发布资产校验页 | `https://github.com/farion1231/cc-switch/releases/expanded_assets/v3.20.4` |
| 官方 SHA-256 | `227288532bfd4f3894d7d9916a8cf340d49957618d8e520229d30bdcc9f5b5d3` |
| 许可证 | MIT |
| 本地位置 | `tools\cc-switch\CC-Switch-v3.20.4-Windows-Portable.zip` |
| 校验后的展开位置 | `tools\cc-switch\app\` |

下载包旁的 `tools\cc-switch\metadata.json` 保存上游 URL、版本、许可证、SHA-256 和核验时间。展开程序不执行。ZIP 与展开程序属于第三方二进制，不将其当作本工具的脚本源代码。

## PowerShell 接口

所有 PowerShell 文件带 UTF-8 BOM，兼容 Windows PowerShell 5.1。

```powershell
# 查询版本、SHA 与隔离状态；会明确返回 BlockedPortableIsolation。
& .\scripts\cc-switch.ps1 -Action Status `
  -PackageRoot .\tools\cc-switch `
  -SessionRoot <本次会话临时目录> `
  -DataRoot <候选 CC Switch 数据目录>

# 仅校验固定的 v3.20.4 ZIP，并在 app 目录不存在时展开已校验的文件。
& .\scripts\cc-switch.ps1 -Action Prepare `
  -PackageRoot .\tools\cc-switch `
  -ArchivePath .\tools\cc-switch\CC-Switch-v3.20.4-Windows-Portable.zip `
  -SessionRoot <本次会话临时目录> `
  -DataRoot <候选 CC Switch 数据目录>

# 当前一定拒绝启动；不会调用 Start-Process 或触碰宿主工具配置。
& .\scripts\cc-switch.ps1 -Action Launch -SessionRoot <本次会话临时目录> -DataRoot <候选 CC Switch 数据目录>

# 用户显式选一个 JSON 文件和本地标签；返回 SecureString 密钥给保险箱调用方。
$profile = & .\scripts\cc-switch.ps1 -Action ReadClaudeProfile `
  -ProfilePath <用户选择的 Claude settings.json> `
  -ProfileName 'My provider'
```

`Prepare` 以官方 release SHA-256 校验 ZIP、要求条目严格为 `cc-switch.exe` 和 `portable.ini`，只在 app 目录缺失时展开。`Status` 和 `Prepare` 都会核对解压后的文件长度及 SHA-256 是否与已验证 ZIP 内成员一致，`ExtractedFilesVerified` 表示该检查结果。发现改动后的程序、未知 app 内容或不匹配的已有 metadata 时拒绝覆盖。它不会创建或写入 provider 凭据，也不会搜索用户配置路径。

`ReadClaudeProfile` 只读调用者明确给出的文件，不遍历或扫描宿主目录。文件必须小于等于 1 MiB，文件及其父路径不能经过 reparse point，必须是 Claude Code 的 JSON 根对象并包含 `env` 对象。返回对象只有 `Name`、`BaseUrl`、`Secret` 和 `Models`；`Secret` 为 `SecureString`，`Models` 只包含以下允许的字符串字段：

- `ANTHROPIC_MODEL`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_OPUS_MODEL`
- `ANTHROPIC_REASONING_MODEL`

来源 JSON 需要恰有一个 `ANTHROPIC_AUTH_TOKEN` 或 `ANTHROPIC_API_KEY`。空值、`PROXY_MANAGED` 和占位值被拒绝。URL 必须是 HTTP(S)，且不允许 userinfo、query、fragment、localhost 或 loopback IP。未识别字段会忽略，不会回传权限、hooks、MCP 等配置。函数不会落盘保存凭据；调用者应把 SecureString 直接交给保险箱导入层，不打印或序列化整个对象。

## Provider 文件边界

桌面 CC Switch 的官方“Export”是 SQL 数据库备份，涵盖多种工具、全部供应商与其他数据；官方批量导入会覆盖数据库。Deep Link 是另一种受确认的应用内导入通道。此适配器不读取 SQL、不执行任何 SQL、不打开 `ccswitch://` URL，也不解析数据库。官方独立 CC Switch CLI 的 `provider export` 是另一个产品接口；本集成不依赖它。

Claude Code 当前 live `settings.json` 是 JSON，CC Switch 使用其 `env` 字段写入 Claude URL、认证字段和可选模型字段；该文件可以由用户显式选作单个 profile 的来源。启用 CC Switch 本地路由时，live 文件可能只有 `127.0.0.1` 和 `PROXY_MANAGED` 占位值，因此解析器拒绝它，不能从此文件推断上游凭据。live 文件通常也没有 CC Switch provider ID；profile label 由调用者提供，provider ID 由保险箱包装层生成。

本模块的解析器只是数据读取边界：它不将密钥写入 U 盘或其他文件。导入、命名、provider 元数据、vault 持久化与孤立 vault 条目恢复由主控的保险箱层负责。

## 测试

`scripts\test-cc-switch.ps1` 使用合成 Claude 配置检查 allowlist、SecureString、占位凭据、地址限制、通用解析错误、拒绝 GUI 启动和拒绝未验证 ZIP。测试另外核对本地固定官方 ZIP 哈希；不启动 CC Switch、不触碰真实配置、不使用真实凭据。

新增 `test-cc-write-scope.ps1` 使用合成 U 盘与宿主目录，验证导入仅写盘内供应商元数据和保险箱；输入中的宿主目录覆盖、hooks 不会被导入，盘内 harness 目录若经目录联接指向外部则拒绝写入。该测试覆盖导入适配层，不能证明官方 GUI 的所有功能均已隔离。最新需求与原生 GUI 待验收项见 `便携生命周期验收标准.md`、`CC-Switch隔离验证.md`。
