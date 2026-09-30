# CC Switch 唯一配置入口迁移接口

`scripts/cc-switch-unified-mode.ps1` 提供迁移准备检查与单向激活闸门。它不启动 CC Switch GUI、不搬运供应商、不改官方程序，也不创建主密码。迁移和解锁必须由已有安全会话流程完成；激活只接受已经存在并解锁的加密存储及当前 Claude 供应商。

## 对接函数

- `Get-CcSwitchUnifiedMode -StickRoot <USB根目录>`：返回严格布尔值。缺少设置文件或标记表示未激活；JSON 错误、类型错误、标记矛盾会抛错。
- `Test-CcSwitchUnifiedActivationReadiness -StickRoot <USB根目录>`：只读检查 secure-store 存在、安全会话已解锁，并调用现有 `Get-ToolboxCcSwitchClaudeProvider` 验证当前供应商。返回 `{ Ready, AlreadyActive, ProviderName }`，不返回凭据。
- `Enable-CcSwitchUnifiedMode -StickRoot <USB根目录>`：先通过上述检查，再在 `config\settings.json.lock` 下用临时文件和替换事务写入 `ccSwitchUnifiedConfig=true`、`ccSwitchClaudeProvider=true`。此标记是单向的；脚本不提供关闭函数。

激活前任何检查失败都不写模式标记、不删除旧配置、不创建存储。激活成功后由启动层将统一标记视为唯一配置源；若该源之后锁定或读取失败，必须停止并报错，不得改用旧供应商。退役旧菜单入口应由后续整合在完成迁移验收后处理，不属于本脚本职责。

## 现有安全 API

`cc-switch-secure-session.ps1` 的 `Get-CcSecureSessionStatus -StickRoot` 可确认 `Unlocked`；`Get-CcSecureSessionClaudeProvider -StickRoot` 通过受保护的本机 broker 取回当前供应商，凭据以 `SecureString` 返回。`cc-switch-provider.ps1` 的 `Get-ToolboxCcSwitchClaudeProvider -StickRoot` 已固定读取 USB 当前 profile，并在发现加密存储时禁止明文回退。统一模式准备检查复用这两个现有 API。

合成覆盖脚本为 `scripts/test-cc-switch-unified-mode.ps1`，所有文件均写入 GUID 临时目录，使用合成密钥，不访问真实用户配置。
