# Codex Proxy

Codex Proxy 是面向 OpenAI Codex Windows Desktop 的本地代理启动器。它只给通过本项目启动的 Codex 进程树注入代理，不修改 Windows 系统代理，也不写入用户级或机器级代理环境变量。

默认代理地址为 `http://127.0.0.1:7891`，用户可以在安装、启动或诊断时指定其他本地端口。

本项目不包含 Codex++、远程调试端口或 Codex++ Proxy 逻辑。

## 系统要求

- Windows 10/11
- Windows PowerShell 5.1
- 从官方 Microsoft Store 安装的 OpenAI Codex
- 在本机回环地址提供 HTTP/Mixed 代理的客户端，例如 Clash Verge 或 sing-box

## 安装

进入项目目录，在 Windows PowerShell 中运行：

```powershell
powershell.exe -NoLogo -NoProfile -File ".\Install-CodexProxy.ps1"
```

未指定端口时默认使用 `7891`。例如改用 `7890`：

```powershell
powershell.exe -NoLogo -NoProfile -File ".\Install-CodexProxy.ps1" -ProxyPort 7890
```

默认安装到 `%LOCALAPPDATA%\CodexProxy`。桌面快捷方式始终指向这个稳定目录，因此移动或删除源码仓库不会破坏已经安装的快捷方式。所选端口保存在安装目录的 `CodexProxy.user.psd1` 中。

如果确实希望快捷方式直接绑定当前项目目录，可使用便携模式：

```powershell
powershell.exe -NoLogo -NoProfile -File ".\Install-CodexProxy.ps1" -Portable -ProxyPort 7891
```

安装器不会静默覆盖不属于本项目的同名快捷方式。确认需要替换时才使用 `-ForceShortcutReplacement`；原快捷方式会被备份，并在卸载时恢复。

## 使用

1. 启动本地代理客户端，确认 HTTP/Mixed 端口与安装时填写的端口一致。
2. 保存正在进行的 Codex 任务，并从系统托盘完全退出 Codex。
3. 双击桌面的 `Codex-Proxy`。

启动器会依次验证代理端口、HTTP CONNECT、官方 Store 包身份、文件签名、AppX 启动能力和 Codex 当前进程。helper 缓存损坏或版本变化时会原子刷新；启动命令执行后还会确认 Codex 进程确实出现。

启动期间使用互斥锁，连续双击不会同时复制 helper 或重复启动 Codex。

### 临时使用其他端口

不修改已保存配置，只让本次启动使用其他端口：

```powershell
powershell.exe -NoLogo -NoProfile -File "$env:LOCALAPPDATA\CodexProxy\Start-CodexProxy.ps1" -ProxyPort 7890
```

端口优先级为：命令行 `-ProxyPort` > `CodexProxy.user.psd1` > 默认值 `7891`。

## helper 缓存

为避免直接从受保护的 `WindowsApps` 目录运行 helper 造成模块加载错误，启动器会动态发现官方资源目录中的所有 `codex*.exe`。当前最低必需集合包括 `codex.exe`、sandbox setup、command runner 和 code mode host。

缓存发布使用 staging 目录、SHA-256 校验、完整文件集合检查和目录级切换。复制失败不会覆盖上一份可用缓存，已被新版本移除的旧 helper 也不会残留。

缓存目录为 `%LOCALAPPDATA%\OpenAI\Codex\bin\codex-proxy-current`。

## 诊断与修复

```powershell
powershell.exe -NoLogo -NoProfile -File "$env:LOCALAPPDATA\CodexProxy\Test-CodexProxy.ps1"
powershell.exe -NoLogo -NoProfile -File "$env:LOCALAPPDATA\CodexProxy\Test-CodexProxy.ps1" -Detailed
powershell.exe -NoLogo -NoProfile -File "$env:LOCALAPPDATA\CodexProxy\Test-CodexProxy.ps1" -Json
```

修复稳定安装和桌面快捷方式：

```powershell
powershell.exe -NoLogo -NoProfile -File "$env:LOCALAPPDATA\CodexProxy\Test-CodexProxy.ps1" -Repair
```

诊断退出码：

- `0`：现在可以启动。
- `2`：配置正常，但需要先退出正在运行的 Codex。
- `1`：存在代理、安装、签名、快捷方式或系统依赖故障。

默认日志位于 `%LOCALAPPDATA%\CodexProxy\logs\launcher.log`，自动轮转。日志写入失败不会阻断 Codex 启动；错误窗口会提供稳定错误码、处理建议和打开日志目录的入口。

## 卸载

默认删除桌面快捷方式和稳定安装目录，不卸载官方 Codex，也不删除代理客户端或 helper 缓存：

```powershell
powershell.exe -NoLogo -NoProfile -File "$env:LOCALAPPDATA\CodexProxy\Uninstall-CodexProxy.ps1"
```

保留安装文件或同时清理 helper 缓存：

```powershell
powershell.exe -NoLogo -NoProfile -File "$env:LOCALAPPDATA\CodexProxy\Uninstall-CodexProxy.ps1" -KeepInstalledFiles
powershell.exe -NoLogo -NoProfile -File "$env:LOCALAPPDATA\CodexProxy\Uninstall-CodexProxy.ps1" -PurgeCache
```

卸载会要求确认，并且只删除经过安装身份和绝对路径校验的目录。

## 测试

```powershell
powershell.exe -NoLogo -NoProfile -File ".\tests\Run-Tests.ps1"
```

测试覆盖配置优先级与验证、启动锁、日志轮转、内部脚本解析、helper 原子刷新、损坏修复、旧文件清理和最低必需集合。GitHub Actions 会在 Windows PowerShell 5.1 下运行同一测试入口。

## 项目结构

- `Start-CodexProxy.ps1`：统一启动入口。
- `Test-CodexProxy.ps1`：只读诊断和显式修复入口。
- `Install-CodexProxy.ps1`：稳定安装、升级和快捷方式修复。
- `Uninstall-CodexProxy.ps1`：验证安装身份后卸载。
- `CodexProxy.config.psd1`：安全默认值和产品配置。
- `CodexProxy.user.psd1`：安装后生成的用户端口配置，不提交到 Git。
- `src/CodexProxy.Common.psm1`：配置、健康状态、AppX、helper 缓存、日志和启动生命周期。
- `tests/`：Windows PowerShell 5.1 回归测试。

## 配置边界

Codex 权限配置中的 `permissions.<name>.network.proxy_url` 是沙箱命令网络使用的代理监听器；官方文档同时说明，Codex 客户端服务流量使用单独的 HTTP/系统代理设置。本项目还需要覆盖 Desktop/Electron 主进程及其 CLI 子进程，因此使用进程级代理环境和 Electron `--proxy-server` 参数。官方参考：<https://learn.chatgpt.com/docs/permissions#what-the-network-proxy-does-not-control>。

## 声明

这是社区维护的非官方启动工具，与 OpenAI 无隶属或背书关系。Codex、OpenAI 及相关标识归其各自权利人所有。
