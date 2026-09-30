# v0.1.0 — 首个 Windows x64 便携 MVP（预发布）

首个完整便携包。保留官方 CC Switch 程序，通过工具箱隔离会话管理配置，支持 Claude Code 的便携运行与升级。

## 包含

- Node.js 24.21.0、npm、Git 2.55.0.windows.5、Python 3.12.14、uv 0.12.18。
- CC Switch 3.20.4、固定 WebView2 153.0.4234.48、原生隔离适配器。
- Claude Code 2.1.285：已完成“关于”页真实升级按钮验收（2.1.281 → 2.1.285）。
- 空的统一配置模板，首次使用时创建自己的主密码并通过 CC Switch 添加供应商。
- 包内逐文件 SHA-256 清单，以及 ZIP 的 SHA256SUMS.txt。

## 下载与首次使用

下载 `portable-ai-toolbox-v0.1.0-windows-x64.zip`，完整解压到 U 盘。阅读包根 `README-FIRST.txt`，双击 `AI设置.cmd` → 10 → 8，按提示创建主密码，在 CC Switch 添加供应商与密钥。保留密码会话窗口，随后用 `AI.cmd` 开始使用。

GitHub 自动生成的 Source code 压缩包只含源码；首次体验请下载上面的完整 Windows x64 ZIP。

## 数据与限制

- 不包含开发者的密钥、保险箱、供应商配置、会话、日志、工作区、恢复包或本机身份。
- 使用后的 config、sessions 等目录可能有个人数据，不应再上传。
- 这是预发布版本，目标为 Windows x64 / PowerShell 5.1；其他电脑的权限策略与安全软件兼容性尚未全面验证。
- 需要用户自己的 API 服务与额度；本包不提供账号或密钥。
- 已验收的 harness 是 Claude Code；其他 harness 的安装升级尚未逐项验证。
- 正常退出并等待保存完成后再拔盘；强行拔盘无法保证保存最后的修改。
- CC Switch 自身检查更新与完整的便携包替换不是同一个步骤。

第三方许可证随包保留，另见 `THIRD-PARTY-NOTICES.txt`。
