# 便携 AI 工具箱 / Portable AI Toolbox

面向 Windows 的 U 盘便携 AI 编程工具箱 MVP。此仓库保存源码、测试和设计说明，不包含个人配置或可直接运行的完整 U 盘镜像。

## 当前能力

- 使用盘内 Node、Git、Python、uv 等运行时，支持独立会话及归档恢复。
- 通过隔离会话接入官方 CC Switch，统一管理供应商配置，配置使用主密码加密保存。
- CC Switch 与电脑上既有实例分离；支持联网检测及受管 Claude Code 升级。
- Claude Code 已完成真实原生界面升级验收：2.1.281 → 2.1.285。程序包优先从固定国内镜像下载，依据官方元数据校验，失败回退官方源。
- 其他 harness 的原生安装、升级还需逐项适配和验收。

## 目录

- `AI.cmd`：日常启动入口。
- `AI设置.cmd`：设置入口。
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

## 预发布便携包

首个完整包的版本说明与使用步骤见 [v0.1.0](docs/Release-v0.1.0.md)。源码仓库仍不存放运行时二进制；打包脚本仅从经过检查的依赖目录和空配置模板组装 Release。
