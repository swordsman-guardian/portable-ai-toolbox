# 便携 AI 工具箱 / Portable AI Toolbox

面向 Windows 和 Linux 的 U 盘便携 AI 编程工具箱 MVP。同一个盘保存两套运行时和一份加密供应商配置，入口按系统选择对应实现。此仓库保存源码、测试和设计说明，不包含个人配置或可直接运行的完整 U 盘镜像。

## 当前能力

- 使用盘内 Node、Git、Python、uv 等运行时，支持独立会话及归档恢复。
- 通过隔离会话接入官方 CC Switch，统一管理供应商配置，配置使用主密码加密保存。
- CC Switch 与电脑上既有实例分离；支持联网检测及受管 Claude Code 升级。
- Claude Code 已完成真实原生界面升级验收：2.1.281 → 2.1.285。程序包优先从固定国内镜像下载，依据官方元数据校验，失败回退官方源。
- 其他 harness 的原生安装、升级还需逐项适配和验收。
- Linux 使用官方 CC Switch AppImage、盘内 Node/Python/uv/Git 和便携隔离组件；运行时在本机私有目录展开，适应 FAT32 和禁止直接执行程序的 U 盘挂载方式。具体要求、启动方式及验证范围见 [Linux 使用说明](docs/Linux便携使用.md)。

## 目录

- `AI.cmd`：日常启动入口。
- `AI设置.cmd`：设置入口。
- `AI诊断.cmd`：CC Switch 无法识别 Claude Code 时的离线诊断入口，不需要解锁配置。
- `AI.sh`、`AI设置.sh`、`AI诊断.sh`：对应的 Linux 入口。用 `bash AI.sh` 启动，不要求在 U 盘上保存执行权限。
- `scripts/`：PowerShell、Python、Node 与原生隔离适配源码，以及回归测试。
- `harness/registry.json`：不含凭据的 harness 适配定义。
- `docs/`：经过筛选的设计与使用文档；部分文档记录历史阶段，以当前源码为准。

## 从源码准备

开发及主要验证环境为 Windows x64 / Windows PowerShell 5.1。仓库不包含下载好的运行时、CC Switch、WebView2、harness 程序包或编译产物。

1. 在目标 U 盘目录克隆仓库，运行 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\bootstrap.ps1` 准备基础运行时。下载需要联网。
2. CC Switch 包由 `scripts/cc-switch.ps1` 管理固定版本和校验；完整隔离启动还需要对应 WebView2 运行时及原生适配器。
3. 原生适配器源码位于 `scripts/cc-switch-portable-updater-shim.cpp` 等文件，构建入口为 `scripts/build-cc-switch-portable-updater-shim.ps1`，需要可用的 Visual Studio C++ x64 构建环境，可通过 `-VsDevCmd` 指定工具链。构建依赖用于准备阶段，不要求在每台使用电脑上安装。
4. 根据相应脚本及 `docs/` 配置便携依赖，在本机窗口创建主密码，通过 CC Switch 配置供应商；真实凭据不写入仓库。当前尚无完整的一键从空仓库装配流程。

## 仓库数据边界

`.gitignore` 使用源码白名单；新文件必须明确审查后才纳入。以下数据即使加密，也不上传：

- `config/`、供应商配置、API Key、密码、保险箱及恢复包。
- `sessions/`、`logs/`、`cache/`、`workspace/` 与工作目录记录。
- `runtime/`、`npm-global/`、`tools/` 中下载的依赖、编译产物和机器相关状态。
- 历史备份、测试运行输出、数据库、临时 fixture 和本机诊断脚本。

请勿使用 `git add -f` 绕过数据边界。私有仓库也不应存储真实密钥。仓库里的 synthetic/example 测试数据仅用于回归测试。

## 验证示例

基础运行时准备完成后，可按改动范围运行对应测试，例如：

```powershell
.\runtime\node\node.exe scripts\test-cc-switch-portable-claude-install.cjs
.\runtime\node\node.exe scripts\test-cc-switch-verify-claude-save.cjs
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-cc-switch-harness-runtime.ps1
```

部分集成测试需要 Windows 隔离能力、相应运行时或编译工具链。第三方软件从各自官方渠道获取，其许可证由各项目提供。

Linux 的程序包准备入口为 `bash scripts/bootstrap-linux.sh /目标盘路径`，只需在准备程序包时联网；已经备好依赖的 U 盘在下一台电脑上直接启动。准备脚本与日常启动的系统要求不同，详见 Linux 使用说明。加密格式互操作和入口测试可使用 `node scripts/test-linux-encrypted-store.cjs`、`node scripts/test-linux-launch.cjs`；真实隔离测试还需要 Linux 运行时及允许普通用户创建命名空间的内核。

打包脚本增加 `-IncludeLinux`，按经过校验的程序包清单组装 Windows/Linux x64 同盘包；默认仍生成 Windows 包。两种包均从空配置模板开始，不包含用户的保险箱、供应商、历史会话或恢复文件。

## 预发布便携包

首个完整包的版本说明与使用步骤见 [v0.1.0](docs/Release-v0.1.0.md)。源码仓库仍不存放运行时二进制；打包脚本仅从经过检查的依赖目录和空配置模板组装 Release。

### v0.1.0 启动解锁补丁

首版在另一台电脑直接打开 AI.cmd 时可能提示缺少 secure session locator。Release 页面另附 startup-fix 小补丁，将其中 scripts 文件夹合并到工具箱根目录即可，保留现有配置和密码。修复后，交互启动会引导解锁；已有会话直接复用，非交互启动仍需预先解锁。

### CC Switch 显示 Claude Code 未安装

先区分工具箱中的 Claude Code 是否能启动，以及 CC Switch 是否能显示版本。显示“未安装”也可能是版本命令执行失败，不能仅凭这一提示判断程序包缺失。

在出现问题的电脑上双击 `AI诊断.cmd`。诊断使用盘内程序包和全新的临时隔离环境，检查命令查找、命令入口和实际程序的版本运行；不读取保险箱、供应商或已有会话，不联网安装，不更改本机 PATH。结果保存在盘内 `logs/` 的诊断 JSON 文件中，仅包含阶段、版本、退出码和脱敏状态。诊断通过不代表 CC Switch 的真实界面检测必然通过；仍需结合界面错误判断。

### 密码窗口退出或提示保存中断

启动失败时，独立密码窗口会保留错误提示，按 Enter 后关闭。`AI.cmd` 和 `AI设置.cmd` 使用 Windows 自带 PowerShell 的固定路径，避免命中其他软件提供的同名入口。

若上次保存中断在历史版本指针替换阶段，解锁后会验证最近已提交的配置与历史版本，将原始加密文件完整备份到盘内 `config/cc-switch/recovery-archives/`，再恢复历史指针并整理活动存储。未提交的副本保留在加密备份中，不自动替代当前配置。遇到无法确认的中断状态或认证失败会停止恢复，保留文件供进一步诊断。此备份目录与保险箱一样，不纳入 Git 或 Release。
