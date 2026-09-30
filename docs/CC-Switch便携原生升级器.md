# CC Switch 便携原生升级器

升级器仅查询 GitHub 官方 latest Release API：`https://api.github.com/repos/farion1231/cc-switch/releases/latest`。它只接受 `farion1231/cc-switch` 的稳定 `vMAJOR.MINOR.PATCH` tag、非 draft/prerelease，并要求资产名精确为 `CC-Switch-vX.Y.Z-Windows-Portable.zip`，官方 `digest` 必须提供 SHA-256，下载 URL 必须匹配官方 release 下载路径。下载最终重定向仅允许 GitHub 官方资产域名。

验证要求：ZIP 长度与 API 一致、SHA-256 与 API digest 相同；压缩包必须恰有 `cc-switch.exe` 与 `portable.ini` 两个顶层文件；拒绝重复/路径异常/超长成员和异常压缩比。文件展开到独立 `tools/cc-switch/managed/slots/vX.Y.Z/`，生成只含 SHA-256/长度的 slot manifest，再逐文件复核。现有官方固定包及其 `app/` 不被覆盖。

## 调用接口

```powershell
. .\scripts\cc-switch-portable-updater.ps1
$active = Resolve-CcPortableUpdatePackage -StickRoot 'E:\'
$volume = Get-VolumeIdentity -StickRoot 'E:\'
$check = Invoke-CcPortableUpdateCheck -StickRoot 'E:\' -CurrentVersion $active.Version -ExpectedVolume $volume
if ($check.Prepared) {
    # 界面提示版本与变更；只有用户明确确认后才在停止/保存回调中提交。
    Commit-CcPortableUpdateCandidate -StickRoot 'E:\' -Candidate $check.Prepared `
        -CompletedGuiState $completedState -EncryptedSession $storeSession `
        -SavedRevision $saveResult.Revision `
        -ExpectedVolume $volume -Confirm:$false
}
```

`Resolve-CcPortableUpdatePackage` 无 managed 指针时调用固定安装的 `cc-switch.ps1 -Action Status`，返回 `Source=Pinned`。存在 managed 指针后绝不静默回退到 pinned；它按 current、崩溃恢复指针、previous 的次序验证，返回可靠槽或明确报需恢复。`Invoke-CcPortableUpdateCheck` 先下载到受限本机临时目录并校验，再把版本槽与官方 ZIP 复制到 USB 的 staging 目录，复核后以同卷重命名发布；候选记录与保护的本机归档留在同一 owner PowerShell 进程，直到提交或显式丢弃。该函数只准备候选，不激活。`Commit-CcPortableUpdateCandidate` 要求同一 PowerShell 进程产生的 candidate、session unlocked 且 data key 仍在内存、保存回执 revision 与密文 current revision 一致，再用 current/recovery/previous 指针事务激活。正常独立调用还要求 broker 报告 GUI 已停止且配置已 Saved。manager 可传入刚完成的 `CompletedGuiState`、`EncryptedSession`、`SavedRevision` 与启动时捕获的 `ExpectedVolume`，走不回调 broker 的生命周期路径：复核 Job/process handles 已关闭、PID 与 start ticks 已退出、AppContainer workspace marker 完好、session root/revision匹配、密文 current revision 与 stopped-save 收据相同、U盘卷身份未变。更新准备和提交均持有独占 writer lock，USB写入/每次指针更换前重查卷身份。指针写入使用同卷文件创建与重命名；如果 FAT32 在指针替换时中断，resolver 可从 recovery/previous 选择已验证槽。升级前不会删除历史版本槽。取消候选可调用 `Discard-CcPortableUpdateCandidate -Candidate $check.Prepared` 清除保护的本机 staging。

合成测试 `scripts/test-cc-switch-portable-updater.ps1` 不访问网络、不执行包中程序，覆盖 latest 元数据严格解析、受限本机 staging、USB卷身份/进程结束/保存回执闸门、current pointer提交、升级恢复和损坏槽拒绝。官方 API 当前发布为 v3.20.4、Windows x64 portable ZIP，已有固定基线也为 v3.20.4；因此此时只有“已最新”路径，没有真实的新版本切换验收。该 API 检查不证明 CC Switch 官方 GUI 的宿主隔离能力。
