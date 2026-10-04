# 同一 U 盘在 Windows / Linux 使用

Windows 继续双击 `AI.cmd`；Linux 在终端进入盘根目录，运行：

```bash
bash AI.sh
```

`bash AI设置.sh` 打开设置菜单，`bash AI诊断.sh` 查看运行时和配置状态。Linux 的启动入口使用盘内 Node，不依赖电脑上的 Node 或 PowerShell。入口会检查运行系统，Windows 与 Linux 分别使用自己的运行时，不把 Windows 的可执行文件带到 Linux 启动。

## 程序包与运行要求

目前 Linux 程序包面向 x86_64、glibc 2.38 或更新版本（例如 Ubuntu 24.04）。需要能运行官方 CC Switch Linux 包的桌面环境，以及可用或经管理员允许的用户命名空间。启动器先用真正要运行的盘内 bwrap 预检，再询问配置主密码。禁止用户命名空间且无法授权的电脑会停止隔离启动，不会自动改为不隔离运行。ARM、Alpine/musl 和较旧的 glibc 尚不属于本包的支持范围。

Ubuntu 的 AppArmor 限制阻止预检时，启动器会说明临时授权的用途，然后直接由 sudo 在本机终端询问这台电脑的管理员密码，无需输入确认词。管理员密码与 U 盘主密码不同，不要发到聊天或填入供应商配置；可按 Ctrl+C 取消。授权只针对当前会话 bwrap 的准确可执行路径，不使用覆盖其他会话的路径通配符；取消授权或授权失败时不解密配置、不保存新版本。其他原因造成的启动失败不会自动请求 AppArmor 授权。

授权会临时修改内核中的 AppArmor 策略，不等同于“没有修改系统策略”。辅助进程只负责加载和撤销该规则，CC Switch、Claude 及初始化任务仍以普通用户运行。规则经标准输入传给系统 apparmor_parser，禁止写策略缓存，不安装服务、不写 `/etc/apparmor.d`、不关闭全局安全功能。会话退出或管理进程关闭管道时，辅助进程撤销它加载的规则；未确认撤销时会明确报告并提供手工撤销命令。临时规则不会在重启后由本工具箱重新加载，因此新的会话可能需要再次授权。这仍是免安装使用，但受限电脑不能保证免管理员授权。

图形化 CC Switch 需要可用的 X11 或 Wayland 桌面，以及桌面环境通常提供的 `dbus-run-session`；启动器为窗口创建自己的会话总线，不连接本机 CC Switch 使用的总线。纯终端电脑可以使用诊断及符合要求的命令行能力。Linux 发行版的基础库与桌面组件仍有差异，验证过的环境以本文后面的验收记录为准，不能把某一个发行版通过理解为所有 Linux 都通过。

程序包分别放在 `runtime/linux-x64/`、`tools/linux-x64/` 与 `npm-global/linux-x64/`。它们在 U 盘上是压缩包，启动时校验后在本机私有目录展开。这样不要求 FAT32 保存符号链接或执行权限，也不要求把 U 盘挂载为可执行。官方 AppImage 直接展开，不依赖 FUSE。

首次准备空盘时运行：

```bash
bash scripts/bootstrap-linux.sh /目标盘路径
```

准备脚本限定在 Ubuntu 24.04 x86_64 上打包，并使用该电脑已有的 curl、tar、apt-get、dpkg-deb、ldd 等工具，避免在较新系统打包后无意提高运行所需的 glibc 版本。准备阶段需要联网；脚本只下载并解包依赖，不安装系统软件。它在调用隔离环境之前也执行相同的 AppArmor 预检和临时授权流程，授权由准备任务结束时撤销。已经装配好的盘不需要在每台电脑重做准备。源码仓库不上传这些下载产物。

## 配置与数据

Windows 和 Linux 共用 `config/cc-switch/secure-store/` 的加密格式及主密码，切换系统后不应重复录入供应商。配置只通过 CC Switch 原生界面修改。启动时把配置解密到本机私有会话，目录设置转为隔离环境内部路径；关闭受控窗口后再加密保存到盘上。

本机安装的 CC Switch、Claude Code 及它们的主目录不会映射进便携 CC Switch。用户在原生界面改目录，也不能突破隔离层去写本机配置。Claude 会话使用自己独立的 HOME，只有明确选定的项目目录可写，不允许把用户主目录或整个文件系统作为项目映射。

同一个盘上的 Claude 会话可以多开，各自保存历史；关闭 Claude 不会把它启动时的旧供应商配置覆盖回 CC Switch。CC Switch 供应商数据库同一时间使用一个受控写入者，这不限制与电脑上另一个 CC Switch 同时运行。

在线窗口不继承本机的代理和凭据环境变量。离线窗口使用独立网络命名空间。在线模式使用本机网络连接能力，因此仍受电脑的网络策略限制。

正常退出先停止本工具箱拥有的子进程，再保存和删除本机明文会话。如果 U 盘突然断开或保存出现冲突，需要先生成经过认证的加密恢复包，再清理明文；恢复包与真实配置一样，不能上传 GitHub 或 Release。系统强制断电或直接终止所有管理进程时无法保证即时执行清理，应使用后续启动的恢复与清理流程。

CC Switch 窗口可以留在一个终端中运行，另开工具箱终端启动 Claude，或选择“锁定并保存 CC Switch”。锁定请求会验证本盘管理器的身份，只关闭其拥有的进程。Claude 的原生升级通过 CC Switch 的“关于”页面执行，退出管理器时把受管程序包归档回盘；新会话使用更新后的版本。程序内容没有变化时保留原槽位，不重复占用 U 盘空间；旧会话不能覆盖已由其他会话更新的程序指针。CC Switch 自身仍遵循官方便携版的手动换包方式，需要校验新官方包后使用，启动器不修改上游界面或可执行文件。

Python 和 uv 优先使用盘内版本（CPython 3.12.11、uv 0.8.22）。Windows 的虚拟环境不能直接在 Linux 运行，两个系统需要分别建立项目环境。Claude 内运行 uv 时，解释器和虚拟环境均放在私有会话中，项目文件与 uv.lock 可以保存在 U 盘；退出后环境可按锁文件重建。设置菜单建立长期项目环境时使用稳定的解释器目录，遇到 FAT/noexec 等不适合执行虚拟环境的项目位置则放在本机私有环境目录，并显示运行路径。

## 验证

加密模块的测试包含 Windows PowerShell 与 Node 双向写入、Unicode 密码、错误密码、密文篡改、并发旧版本拒绝、目录穿越和独立会话档案。

真实 Linux 运行时及隔离验证：

```bash
node scripts/test-linux-runtime.cjs /目标盘路径
node scripts/test-linux-sandbox.cjs /目标盘路径
node scripts/test-linux-sandbox.cjs /目标盘路径 --gui
node scripts/test-linux-session.cjs
node scripts/test-linux-userns.cjs
node scripts/test-linux-bootstrap-userns.cjs
node scripts/test-linux-portable-integration.cjs /目标盘路径
node scripts/test-linux-portable-integration.cjs /目标盘路径 --gui
```

测试使用合成配置，不需要解锁用户保险箱。sandbox 测试的 `--gui` 验证窗口启动与退出；portable-integration 测试的 `--gui` 进一步验证官方 CC Switch 私有代理和真实 Claude 的请求链路。它们需要已有的可用图形显示环境，不在没有桌面的 CI 中执行。隔离测试探测真实 bwrap；受限系统未授权时会结束测试并显示引导，不擅自加载规则。AppArmor 单元测试使用注入的进程接口覆盖授权、取消、失败和撤销，不要求 sudo。独立的策略集成测试只允许在 GitHub 托管的临时 Linux runner 上明确启用；它检查真实规则加载、重复加载拒绝、bwrap 执行和退出撤销，不修改全局命名空间限制。runner 没有 AppArmor 能力时会明确显示跳过。

本轮实测环境为 Windows x64 / PowerShell 5.1 和 WSL2 内的 Ubuntu 24.04 x86_64。已通过加密格式双向互操作、TTY 密码入口、并发历史归档、断盘加密恢复、真实 Node/Git/Claude 运行、私有 HOME 与项目目录边界、密钥不出现在启动参数中，以及 uv 在私有目录创建并执行 Python 环境的测试。已装配的 Linux 基础版本为 Node 22.23.3、Claude Code 2.1.287、CC Switch 3.20.4。

Ubuntu 24.04 的 GitHub 托管 runner 已验证真实 AppArmor 分支：限制值为 1 时，当前 bwrap 最初被拒绝；加载准确路径的临时规则后可以执行，复制到另一位置的 bwrap 仍被拒绝。重复授权不会替换或卸载已有规则；正常释放、控制管道关闭和终止信号后的撤销均通过内核规则列表确认。测试未修改全局命名空间限制，也未安装系统软件。本机 WSL 没有启用 AppArmor，因此这部分验收以云端 runner 为准。

官方 CC Switch AppImage 已在隔离环境中真实显示窗口，并通过退出清理测试。通过原生升级使用的 npm 命令重装当前最新版 Claude 后，已经验证程序包归档、激活新槽位和全新会话再次启动；没有把本机 HOME、缓存或供应商配置混入升级包。

原生代理集成已通过：官方窗口拥有随机端口，Claude Code 经该代理访问本地合成 Anthropic 流式接口，并获得回复；原有 15721 端口服务保持可用。测试不使用真实供应商密钥、不产生模型费用。还验证了 CC Switch 断盘清理、SIGHUP 关闭终端清理，以及归档文件的符号链接拒绝与大小限制。

GitHub 自动检查覆盖加密互操作、系统分流、会话和代理身份，以及运行时清单与归档逻辑；真实程序包、图形窗口和完整发布包仍由对应的本地集成测试验收。发布脚本通过 `-IncludeLinux` 生成双系统包，Windows 程序采用已发布版本的精确文件与哈希清单，Linux 只复制核验过的压缩包；不复制用户保险箱、配置、历史和恢复包。
