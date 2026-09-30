# CC Switch 受管 Claude Harness 更新适配

`scripts/cc-switch-harness-runtime.ps1` 提供 v3.20.4 原生 Claude CLI 更新所需的受管环境和验证计划；默认 portable context 不启用它。只有调用方明确传入 `ManagedHarnessSlotId`、NTFS staging 下的 `RuntimeRoot` 和 `ManagedHarnessRoot`，context 才会注入受管值。当前适配只支持 Claude。

opt-in 子进程 PATH 严格固定为当前 slot 的目录、fixture 内复制的 `RuntimeRoot\node`、Windows `System32`。因此原生工具发现优先命中 slot 中的 `claude.cmd`，而 PATH 中没有宿主 Node/npm 项。`npm_config_prefix` 指同一 staging slot；缓存和空的 user/global npmrc 位于 `ManagedHarnessRoot\state\npm-data`，registry 固定为 `https://registry.npmjs.org/`。不读取宿主 npmrc 或继承宿主 PATH。AppContainer fixture reader 会重新验证变量：拒绝额外 PATH 项、其它 npm 前缀、非官方 registry、不完整的受管路径，以及路径重解析点。

版本文件由 owner 从 USB 受管目录复制到每次启动的新 NTFS workspace `root\harness`；CLI 在 workspace 的该 slot 内原位更新。AppContainer 只有临时 workspace ACL，实际 USB（本机为 FAT32）没有被授予写权限。窗口与 Job 结束后，owner 还必须验证 slot 包名、版本、目录清单和文件树，再把有效结果保存为 USB 上新的受管版本槽并切换后续启动指针。现有加密配置快照不承载 Node/npm 或 Claude CLI 二进制。这个 owner 持久化及启动选择流程仍需 root 接入；当前模块自身不会改写 USB。

固定上游是 [CC Switch v3.20.4 `misc.rs`](https://github.com/farion1231/cc-switch/blob/v3.20.4/src-tauri/src/commands/misc.rs)。上游 Windows 发现逻辑把进程 PATH 项放在 Registry PATH 项之前，并锚定检测到的 CLI 绝对路径；生命周期命令继承本进程环境。AppContainer 对宿主 Registry 路径仍没有写权限。上述环境让原生 `claude update` 的 CLI、npm prefix 和 Node 落在 staging slot，但不能单靠 npm 环境变量证明升级产物有效或已保存到 USB，因此启动器不能把按钮成功提示当作已提交版本。

## 可验证接口

- `Get-CcSwitchManagedClaudeEnvironment`：从 StickRoot、RuntimeRoot、ManagedHarnessRoot 和 slot ID 重新计算严格 PATH/npm 环境；要求 Node/npm CLI 与 slot 中的 `claude.cmd` 已存在。
- `Get-CcSwitchManagedClaudeUpdatePlan`：返回官方 `@anthropic-ai/claude-code@latest` 的 npm 命令与受管 prefix，不执行安装，也不写 USB。
- `Test-CcSwitchManagedClaudeSlot`：要求受管 shim、官方包名及版本清单有效，拒绝额外顶层文件和 reparse point。
- `New-CcSwitchPortableContext -RuntimeRoot ... -ManagedHarnessRoot ... -ManagedHarnessSlotId ...`：opt-in 受管环境。三个新参数缺一或路径形状不符都会拒绝；不传参数时维持原环境。
- `Read-AppContainerFixture`：在启动时再次验证严格 PATH 合同。更新 mailbox 如启用，必须同时提供固定 `<Root>\runtime\updates\portable-update.request` 路径和 32 个小写十六进制 nonce 字符。

`scripts/test-cc-switch-managed-harness.ps1` 覆盖 PATH、npm 配置、官方 registry、受管安装计划、路径注入拒绝和 mailbox 配对检查；`scripts/test-cc-switch-context.ps1` 确认旧 context 行为不变。`scripts/test-cc-switch-managed-harness-ui.ps1` 可用纯合成 provider-free 配置启动原生 CC Switch GUI。默认启用 InternetClient，以便官方版本检查访问网络；这项 Windows capability 本身不提供域名白名单。测试 npm shim 只把官方 Claude 包的 `view/info/show` 元数据查询委托给 fixture 内的真实 npm CLI，其余 npm 操作一律只记日志且不安装。Claude CLI shim 是假脚本，仅记录原生调用路径和参数；可用 `-InjectPortableUpdateShim` 启用已校验的 native opener hook 和固定 mailbox。合成配置没有供应商或密钥，不会发模型请求；本检查仍不证明真实包安装或 USB 持久化。
