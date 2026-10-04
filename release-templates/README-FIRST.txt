便携 AI 工具箱 v0.1.0（Windows x64，MVP 预发布）

这是不含个人配置的完整便携包。解压整个目录到 U 盘后再运行，不要在 ZIP 里双击。

首次使用：
1. 双击 AI设置.cmd，选择 10「CC Switch 接入」。
2. 选择 8「解锁 / 打开原生 CC Switch（隔离联网）」。
3. 在新打开的密码窗口设置自己的主密码并确认。密码不预设，不随本包提供。
4. 保留该密码会话窗口（可最小化）。在 CC Switch 中添加自己的供应商、API Key 和模型，并设为当前供应商。
5. 回到工具箱，开始使用；或双击 AI.cmd，选择要处理的工作目录。

若包内包含 AI.sh 和 runtime/linux-x64/，也可以在 Linux 使用同一 U 盘：
在终端进入解压后的盘根，运行 bash AI设置.sh；选择联网 CC Switch，
设置或输入同一个主密码，再通过原生窗口配置。日常运行 bash AI.sh。
Linux x86_64 的运行条件、隔离方式和验收范围见 docs/Linux便携使用.md。
Windows 与 Linux 分开使用程序包，共用盘内加密供应商配置。

日常：先解锁 CC Switch，再开始 Claude 会话。供应商只在 CC Switch 中修改。
需要联网使用你的供应商服务；本包不包含 API 额度、账号、密钥或模型。
正常退出后等待保存完成再拔盘；直接拔盘无法保存尚未归档的内容。

包含：Node / npm、Git、Python 3.12、uv、CC Switch 3.20.4、固定 WebView2、Claude Code 2.1.285。
Claude Code 可在 CC Switch 的「设置 → 关于」中升级；国内镜像优先、官方校验。
其他 harness 的安装/升级尚未逐项验收。CC Switch 自身检查更新与便携包替换是不同步骤。

本包属于 MVP 预发布，当前实测环境为 Windows x64 / Windows PowerShell 5.1 和 WSL2 内的 Ubuntu 24.04 x86_64。
目标电脑的权限策略或安全软件可能限制隔离组件；不承诺所有电脑都已验证。
拒绝访问时请保留错误，不要关闭系统安全功能或以管理员身份运行 CC Switch / Claude。
Linux 若提示系统限制隔离启动，程序会说明临时授权用途，然后直接提示输入本机管理员密码（不是 U 盘主密码）；可按 Ctrl+C 取消。
此授权只允许当前会话的隔离组件使用用户命名空间；不安装服务、不写持久策略文件，退出时撤销。
拒绝或授权失败会中止启动，不会以不隔离方式运行。详细权限与撤销说明见 docs/Linux便携使用.md。

不要把使用后的整个目录重新上传：config、sessions、logs、cache、workspace 可能含个人数据。
SHA256SUMS.txt 用于检查下载 ZIP；release-manifest.json 记录初始包内文件指纹。
源码和更新：https://github.com/swordsman-guardian/portable-ai-toolbox
本文件描述此版本首用步骤；其他文档可能包含早期开发阶段说明。
