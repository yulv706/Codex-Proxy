# Codex Proxy

这是普通 OpenAI Codex Desktop 的本地代理启动项目，固定让通过本项目启动的 Codex 进程使用 `http://127.0.0.1:7891`。

本项目不包含 Codex++、远程调试端口或 Codex++ Proxy 逻辑。

## 使用方法

1. 启动 Clash Verge 或其他在 `127.0.0.1:7891` 提供 HTTP/Mixed 代理的程序。
2. 完全退出已经运行的 Codex，包括系统托盘中的 Codex。
3. 双击桌面的 `Codex-Proxy` 快捷方式。

如果需要重新创建桌面快捷方式，请先进入项目目录，然后在 Windows PowerShell 中运行：

```powershell
powershell.exe -NoLogo -NoProfile -File ".\Install-CodexProxy.ps1"
```

## 项目结构

- `Start-CodexProxy.ps1`：主启动器，只负责普通 Codex Proxy。
- `CodexProxy.config.psd1`：代理端口、Codex 包名、快捷方式名称等配置。
- `src/CodexProxy.Common.psm1`：Codex 包发现、更新适配、辅助程序同步和日志功能。
- `Install-CodexProxy.ps1`：安装或修复桌面快捷方式。
- `Uninstall-CodexProxy.ps1`：只移除属于本项目的桌面快捷方式。
- `Test-CodexProxy.ps1`：只读诊断，不启动或关闭 Codex。
- `assets/codex-official-transparent.ico`：桌面快捷方式图标。
- `logs/launcher.log`：启动日志，首次运行后生成。

## 工作方式

启动器会先验证 7891 正在监听，然后动态查找最新的 `OpenAI.Codex` AppX 包及清单中的实际可执行文件。因此 Codex 更新并改变安装版本目录后，通常不需要修改项目。

为避免直接从受保护的 `WindowsApps` 目录运行辅助程序所造成的模块加载错误，启动器会核对 `codex.exe`、`codex-windows-sandbox-setup.exe` 和 `codex-command-runner.exe` 的 SHA-256，并将与当前 Codex 版本一致的一组辅助程序同步到：

```text
%LOCALAPPDATA%\OpenAI\Codex\bin\codex-proxy-current
```

这个目录是运行缓存，不是另一个项目。Codex 更新后，下一次从快捷方式启动时会自动刷新。

启动 Codex 时，项目仅给该次 Codex 进程树注入 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、WebSocket 代理变量及小写兼容变量，并向 Electron 传入 `--proxy-server`。它不会写入 Windows 用户级或机器级环境变量，也不会改变系统代理，因此其他程序不会因为本项目而使用 7891。

## 诊断

在 Windows PowerShell 中运行：

```powershell
powershell.exe -NoLogo -NoProfile -File ".\Test-CodexProxy.ps1"
```

常见情况：

- `ProxyListening = False`：先启动本地代理客户端并确认 Mixed/HTTP 端口是 7891。
- 提示 Codex 已运行：从托盘完全退出 Codex，再使用桌面快捷方式。
- 启动失败：查看 `logs/launcher.log` 的最后几行。
- 安全软件拦截：将整个项目目录加入可信目录。桌面快捷方式没有 `ExecutionPolicy Bypass`、隐藏窗口或远程调试参数；启动器只会在 AppX 容器内部隐藏一次临时 PowerShell 窗口，避免启动 Codex 时闪出控制台。

## 卸载快捷方式

```powershell
powershell.exe -NoLogo -NoProfile -File ".\Uninstall-CodexProxy.ps1"
```

卸载脚本不会删除项目、Codex、代理客户端或辅助程序缓存。

## 配置边界

Codex 官方的权限配置中，`network.proxy_url` 描述的是沙箱命令网络使用的代理监听器。这个项目的目标还包括 Codex Desktop/Electron 主进程和它启动的 CLI 子进程，因此使用专用启动器提供进程级代理环境和 Electron 代理参数。官方参考：<https://learn.chatgpt.com/docs/permissions#configuration-spec>。

## 声明

这是社区维护的非官方启动工具，与 OpenAI 无隶属或背书关系。Codex、OpenAI 及相关标识归其各自权利人所有。
