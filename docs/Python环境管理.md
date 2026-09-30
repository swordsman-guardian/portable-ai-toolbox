# U 盘内置 Python 环境

工具箱默认使用 `runtime\python\python.exe` 和 `runtime\uv\uv.exe`。还可识别 `runtime\python-<名称>\python.exe`。版本由每个内置解释器实际运行得到；不会从宿主 PATH、Python Launcher、Conda 或宿主 uv 中寻找替代品。FAT32 不支持 uv 安装时所需的版本链接目录，所以这里使用 bootstrap 已手工解压的 Python，并把 uv 的包链接模式设为 copy。

## 项目要求和环境准备

可识别 `pyproject.toml` 的 `[project] requires-python` 单行双引号值，以及 `.python-version` 中精确的 `X.Y` / `X.Y.Z`。`.python-version` 的 `X.Y` 表示该次版本系列（例如 `3.12` 匹配 3.12.14），带 patch 的 `X.Y.Z` 则精确匹配。两者同时存在时都必须满足。`requires-python` 当前支持逗号分隔的 `==`、`!=`、`>=`、`<=`、`>`、`<`、`~=` 和 `==X.Y.*`。其他 PEP 440 语法（例如预发布标记、环境标记、任意版本、复杂 OR）会明确报告暂不支持，不会猜测。

```powershell
# 查看工具箱内置版本
powershell -NoProfile -ExecutionPolicy Bypass -File E:\scripts\python-env.ps1 -Action inventory

# 只检查项目要求，不创建目录
powershell -NoProfile -ExecutionPolicy Bypass -File E:\scripts\python-env.ps1 -Action check -ProjectPath E:\workspace\my-project

# 为项目创建或复用工具箱管理的环境
powershell -NoProfile -ExecutionPolicy Bypass -File E:\scripts\python-env.ps1 -Action prepare -ProjectPath E:\workspace\my-project
```

环境放在指定 `WorkPath\python-envs\<键>`，键基于项目绝对路径、Python 路径和版本、依赖文件名及 SHA-256。CLI 未指定 `-WorkPath` 时使用系统临时目录下的 `AIStick\python-work`；启动器传入自己的 WorkPath。项目自身的 `.venv` 不会读取、覆盖或删除。依赖文件变更会生成另一个隔离环境。创建 venv 不等于安装依赖：发现 `pyproject.toml`、requirements、setup、Pipfile 或锁文件时结果标为 `DependenciesPending` 且 `Ready=false`。本阶段不自动联网安装包，也不做全局 pip 安装。

项目要求的 Python 未安装时，状态会给出要求和工具箱内可用版本；普通/非 Python harness 启动不必因此失败，但该 Python 项目不能拿不兼容解释器冒充可用。需要人工把经信任来源验证过的版本解压到 `runtime\python` 或 `runtime\python-<版本>` 后再检查。uv 创建环境时会临时清除进程中的 UV_*、VIRTUAL_ENV 和 Python 路径注入变量，使用盘内缓存、禁用 Python 下载及 copy 链接模式，随后恢复原变量；不改宿主注册表、PATH 或配置文件。

## Python 命令边界

启动器通过 `python-session.ps1` 把普通 `python`、`uv run`、`uv sync` 和 `uv pip` 绑定到当前项目的会话虚拟环境：PATH 优先指向该环境的 Scripts，`UV_PYTHON` 和 `AISTICK_PYTHON` 指向该环境解释器，`VIRTUAL_ENV` 与 `UV_PROJECT_ENVIRONMENT` 指向该环境目录。变量只影响本窗口进程及其子进程，不写系统配置；其他窗口有独立的环境路径。uv 创建的环境默认不带 pip，请用 `uv pip` 安装依赖。

本版每个窗口绑定启动时选择的一个项目。切到另一项目工作时，请通过启动器新开窗口；同一窗口内仅用 `cd` 或 `uv --project` 切换项目不会自动重选环境。显式传入其他解释器、`--system` 或覆盖环境变量属于用户自行选择的目标，不在默认隔离保证内。

版本不兼容时，普通 Python/pip 命令会显示明确错误并返回非零，不把共享基础解释器冒充可用项目环境。初始化函数本身只返回状态；应用上述绑定的是启动器。`Invoke-PortablePython -PythonPath <明确路径> ...` 可用于显式运行指定解释器。

## 手动安装路径

bootstrap 当前使用 python-build-standalone 的 install-only tarball 手工解压到 `runtime\python`，规避 FAT32 上 `uv python install` 的链接失败。补装其他版本时，应从受信任发布源获取对应 Windows x64 install-only 包及发布方校验值，先在临时目录验证 SHA-256，再解压到 `runtime\python-<版本>` 并运行 `python.exe --version`；本脚本不会自动下载或覆盖任何版本。
