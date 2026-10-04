# v0.2.0-alpha.1

这是便携 AI 工具箱的预发布版本。它提供 Windows 与 Linux 的源码和启动实现；源码压缩包不含 Node、Git、Python、uv、CC Switch、Claude Code、WebView2 或其他第三方运行程序，也不是可直接插入电脑使用的完整 U 盘镜像。首次准备需要联网，下载优先使用官方来源；若使用镜像，也必须通过官方固定 SHA-256 校验，文件大小不能代替哈希校验。

## 验证范围

- Windows 11 Home x64（版本 10.0.26200）、Windows PowerShell 5.1 的独立空源码 fixture 准备入口成功，Windows 10 尚无实体机验证结果。
- Linux 完整准备脚本以普通用户身份在 WSL2 Ubuntu 24.04 x64 重跑成功；冷准备与 WSLg 图形启动完成验证，覆盖 Node 22.23.3、uv 0.8.22、CC Switch 3.20.4、Git、bubblewrap、Python 3.12.11 和 Claude Code 2.1.289。
- Linux AppArmor 临时授权与撤销分支在 GitHub 托管 Linux runner 上验证；当前 WSL 环境未启用 AppArmor，不能代表实体机授权体验。

这些条目记录了当前实测环境和验证边界，不是对所有电脑、发行版、桌面、系统策略或安全软件的兼容承诺。其他 CPU 架构、非 Ubuntu Linux、较旧 glibc 环境未列入本版本支持范围。

## 首次准备与启动

首次使用前请阅读[首次使用说明](首次使用.md)。Linux x64 的准备脚本面向 Ubuntu 24.04 x64。Windows 使用 `准备Windows.cmd`：在 Windows 10/11 x64、Windows PowerShell 5.1 和已安装 Visual Studio“使用 C++ 的桌面开发”工作负载的准备机上，把源码 ZIP 平铺到全新目录后运行。入口先检查环境，再下载依赖；下载优先使用官方来源，若使用镜像仍须通过官方固定 SHA-256 校验，文件大小不能代替哈希校验。第三方运行程序按固定 SHA-256 或官方发布信息校验。准备成功后把准备目录内的全部文件和文件夹复制到 U 盘根目录，确保入口和 `scripts/` 位于同一层。每个新的源码目录只准备一次，不要在已有个人配置的目录重跑。该过程需要联网、数 GB 空间，耗时随网络情况变化。

Windows 准备入口通过独立空源码 fixture 完整运行。已校验 Node 24.21.0、uv 0.12.17、Git 2.56.0、Python 3.12.14、CC Switch 3.20.4、WebView2 153.0.4234.48、原生适配器编译和 Claude Code 2.1.289 CLI。WebView2 通过固定 SHA-256、Microsoft 签名与 257 文件清单核验；Claude Code 通过官方 registry SHA-512 及隔离空配置下的 `--version` 检查。入口完成后的回执复核退出码为 0，配置仍与内置空模板逐字节一致，未设置主密码、供应商或发出 API 请求。

本次 CC Switch ZIP 来自本轮通过 `gh` 从官方 Release 获取的缓存，准备入口再次验证了固定 SHA-256 和解压文件；这不是从旧 U 盘或项目目录借用程序。匿名下载通道未完整下载该 ZIP，只完成 HEAD/分段探测。首次准备耗时和成功与否仍可能受网络影响；此次也没有进行真实用户 GUI 或供应商 API 测试。Windows 10 尚无实体机验证结果。

Linux 日常入口为 `bash AI.sh`；设置和只读诊断入口分别为 `bash AI设置.sh` 与 `bash AI诊断.sh`。默认工作目录是 U 盘根目录中的 `workspace/`，也可明确选择其他项目目录。AppArmor 限制阻止 user namespace 时，程序先说明用途，再由 sudo 请求本机管理员密码；无需输入额外确认词，Ctrl+C 可取消。

Windows 日常入口为 `AI.cmd`，设置和诊断入口为 `AI设置.cmd` 与 `AI诊断.cmd`。CC Switch 解锁后应保留其会话窗口，再启动 Claude；正常退出并等待保存完成后再拔盘。

## 功能与限制

本版本围绕 CC Switch 管理 Claude Code 供应商，并在独立会话中启动 Claude。凭据以本机主密码加密保存。启动过程不要求发送真实 API 请求；明确选择连通性测试后才会向所选服务商发请求，该请求可能产生费用。

Linux 在当前会话中按准确的 bwrap 可执行文件路径临时授权 AppArmor user namespace 规则，结束时撤销。授权过程需要系统 sudo；撤销未确认时会报告并提供后续处理信息。强行拔盘、断电或终止进程可能打断保存或清理，因此本版本不保证此类情况下没有残留。

只读诊断入口用于查看本机或 U 盘运行状态，不解锁保险箱、不读取供应商密钥，也不请求真实 API。其他 harness、操作系统和系统策略的可用性不在本次验证结论内。

## 发布文件与许可证

本版本公开附件固定为 `portable-ai-toolbox-v0.2.0-alpha.1-source.zip`、`release-manifest.json` 和 `SHA256SUMS.txt`。源码归档只包含仓库内容，不含第三方运行程序或完整 U 盘镜像；首次准备需联网，优先从第三方官方来源获取程序。若使用镜像，也必须通过官方固定 SHA-256 校验，文件大小不能代替哈希校验。

项目原创代码按仓库根目录的 [MIT 许可证](../LICENSE) 发布。该许可不改变第三方软件各自的许可证，依赖的许可和再分发条件仍由各项目决定；详情见[第三方许可与公开发布说明](第三方许可与公开发布.md)。发布包中不得包含个人密钥、主密码、加密保险箱、用户配置、工作区、会话、恢复包或本机运行状态。
