# CC Switch 统一入口实施状态与升级边界

核验日期：2026-09-29。本文区分已实现、真实验收、合成测试覆盖和仍未完成的事项。用户已设置主密码，迁移并核验工具箱 provider，随后成功启用统一配置入口。三份旧明文恢复文件已核验并于本轮删除；USB 上 CC Switch 与 harness 的原生升级仍在集成验证中。

## 已实现并验证

- 统一模式由 `config/settings.json` 中两个布尔标记共同约束。统一标记开启时，启动器不读取 `harness/providers.json`；下一窗口从已解锁会话取得当前 Claude provider、凭据和完整 Claude 配置文件快照。broker 锁定或读取失败会停止启动，不回退到旧供应商来源。
- 启动器只在独立的会话 ConfigDir 写入 CC Switch 提供的 Claude settings/launch files。单窗口环境变量仍按启动快照设置，后续供应商切换只影响新窗口。
- `test-launch-unified-settings-race.ps1` 动态执行实际 `Save-UserSettings` AST，在模拟另一窗口刚激活统一模式后提交旧窗口改动，确认共享模式和 provider 来源不会被旧状态覆盖。
- `test-cc-switch-unified-launch.ps1` 动态执行实际启动器 provider-source 与 provider-resolution 分支，验证缺少 `providers.json` 时仍使用 broker bundle、bundle 内多份 launch files 保留、broker 锁定时失败关闭且无旧来源回退。
- `test-cc-switch-unified-launch-full.ps1` 运行真实启动器和合成 Claude harness，检查实际会话 marker、ConfigDir 中可读的 settings、正常退出保存路径与 ConfigDir 清理。为注入无凭据的合成 broker，该测试副本仅移除 secure-session dot-source 行并由 wrapper 提供函数；命名管道协议另由 `test-cc-switch-ipc.ps1` 覆盖。因此端到端测试不等于真实 broker 与 GUI 的完整联合验证。
- 两个新增启动测试已加入 `test-foundation.ps1`。定向测试执行通过；此前中途报告的两个迁移 PowerShell 文件 BOM 已补齐，后续分批验收达到 35 组完成、1 组受阻，详见下文。
- unified readiness 检查目前要求 Claude 是 registry 中第一个启用的 harness；运行期统一来源也只支持 Claude Code。其他 harness 的统一入口尚未实现，不能将其描述为已支持。

## 本机验收进度

Foundation 共 36 组：前 24 组均显示完成；第 25 组 `test-cc-switch-encrypted-store.ps1` 连续两次未能启动，Windows 返回 `Access to %1 has been restricted by your Administrator by policy rule %2`。期间没有修改系统策略；近期 AppLocker、Code Integrity 与 Defender 日志中没有找到对应事件，因此阻止原因尚未查明。其余 11 组通过单独 foundation 运行，记录于 `E:\logs\unified-foundation-phase3-20260929.log`（exit 0）。当前全套结果仍是 35 组完成、1 组受阻，不能称为全绿。最终解锁重试新增 28 项通过；secure-session、IPC 与 session-guardian 三组 foundation 重跑通过，记录于 `E:\logs\cc-unlock-retry-20260929.log`。提交后异常回滚覆盖测试通过，修复后的 UI race 测试也通过。

本机真实验收：旧 CC Switch 配置已形成加密快照；首次锁定后，用户成功解锁。broker 读取核验均为 true：`Unlocked`、`GuiRunning`、`BaseUrlMatches`、`CredentialMatches`、`ModelsMatch`、`ExtraEnvironmentMatches`、`OriginalClaudeSettingsPreserved`；`LastSaveStatus=Saved`、`NetworkMode=InternetClient`、`LaunchFiles=1`。原生 UI 只读确认当前使用 provider 为“阿里云百炼”。工具箱 provider 已导入并核验后，`Enable-CcSwitchUnifiedMode` 成功返回 `UnifiedMode=true`、`UsesCcSwitchProvider=true`。

测试中同时观察到 USB 临时版 CC Switch 窗口与本机已安装版 CC Switch 窗口；本机安装版未触碰。没有额外发送真实模型 API 请求。密码输入提示窗口可最小化；关闭该窗口会锁定会话并关闭 USB 上的 CC Switch。本轮已删除 `config/keys.env`、`harness/providers.json` 和 `config/claude/settings.json`。删除后真实 broker 仍能提供凭据及启动配置，启动器回归通过；仅验证了这些明确目标，不宣称整盘、文件系统空闲区或系统缓存均无明文。

## 迁移与旧数据

工具箱 provider 导入程序在受 ACL 保护的临时 NTFS 目录恢复当前加密快照并导入已启用 provider；提交前会核对源文件哈希与加密快照 revision。随后 `Save-CcEncryptedSnapshotCore` 将结果提交为新的加密代，再从已提交的加密快照恢复到验证目录并核对数据库与配置 round-trip；若读回验证不一致，则恢复旧代指针与 generation。源 `providers.json`、`keys.env`、旧凭据 vault 与原 Claude settings 不由导入程序自动删除。本机已实测旧 CC Switch 配置加密快照生成、解锁、真实 provider 导入和 round-trip 核验；随后统一模式已启用。本轮另行执行了精确清理，记录见 `CC-Switch旧明文清理计划.md`；导入程序本身仍不自动删除源数据。

当前统一模式已启用。新启动的 Claude provider 与设置由 CC Switch 提供；遗留 `config/keys.env` 和 `harness/providers.json` 已在核验加密快照覆盖后删除，Claude 设置旧副本也已清理。加密 current/previous 与历史保留。

## CC Switch 与 harness 更新边界

固定上游为 [CC Switch v3.20.4 AboutSection.tsx](https://github.com/farion1231/cc-switch/blob/v3.20.4/src/components/settings/AboutSection.tsx)、[`misc.rs`](https://github.com/farion1231/cc-switch/blob/v3.20.4/src-tauri/src/commands/misc.rs) 和 [release.yml](https://github.com/farion1231/cc-switch/blob/v3.20.4/.github/workflows/release.yml)。未修改的 v3.20.4 Portable 更新检查会打开 GitHub 的 `releases/latest` 页面；非 Portable 安装才进入 MSI 安装并重启流程。Portable 发布产物是可执行文件 ZIP，并带 `portable.ini`，release workflow 明确将该 ZIP 排除在 Updater 流程之外。因此不能说上游便携 GUI 会运行 MSI。项目另已接入受控的 portable updater shim/owner：将更新请求交由官方 Release 校验和 USB 版本槽事务处理；该自有路径已接线，但真实隔离 GUI 请求捕获与新版槽激活尚未端到端验收。

未修改的 v3.20.4 工具发现/安装路径会重新合入 Windows Registry PATH 并扫描宿主固定目录；原生安装管理还会调用系统命令和包管理器。因此新增盘内 Node/npm 运行时及子进程环境本身不能保证 CC Switch 原生按钮只使用盘内工具。`docs/CC-Switch受管Harness运行时.md` 和 `test-cc-switch-harness-runtime.ps1` 只覆盖盘内 Node/npm 副本可在 AppContainer 探针中运行，不证明上游 GUI 安装/更新路径隔离。原生工具安装与更新仍须保持未支持状态，除非后续以真实执行路径证明目标、写入位置、持久化及回滚均受控。
