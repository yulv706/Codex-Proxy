# Codex Proxy

Codex Proxy 是原生 Windows 多应用代理启动器。4.1.0 支持 Codex、Cursor、Grok Bot，以及用户添加的其他 `.exe` 应用。WPF 桌面程序提供代理启动、应用管理、运行诊断、运行日志和设置五个页面，支持浅色、深色和跟随系统主题。

桌面端采用独立的视图、状态和运行服务。长任务异步执行，端口保存与偏好设置使用原子写入；托盘、安装向导、输入校验、错误提示和键盘操作使用一致的交互规则。设计实现参考 CC Switch 的语义化颜色、分组设置和导航组织，具体研究记录与架构见 [桌面架构说明](docs/desktop-architecture.md)。

历史会话浏览、跨电脑同步、后台快照、项目绑定和历史修复功能已移除。程序不再读取或写入 Codex 会话、会话索引和历史数据库。覆盖升级会清理旧版附带的历史同步脚本和设计文档，保留已有的会话、历史仓库、备份和历史同步配置；这些旧配置不再被程序使用。

默认代理地址为 `http://127.0.0.1:7891`。安装完成后可在程序设置页修改本地代理端口；脚本化启动和诊断也支持临时指定端口。

本项目不包含 Codex++、远程调试端口或 Codex++ Proxy 逻辑。

## 系统要求

- Windows 10/11
- Windows PowerShell 5.1 和 .NET Framework 4.8（当前 Windows 10/11 自带）
- 至少安装一个需要代理启动的应用；Codex 需要来自官方 Microsoft Store，Cursor 和 Grok Bot 支持独立安装目录
- 在本机回环地址提供 HTTP/Mixed 代理的客户端，例如 Clash Verge 或 sing-box

## 安装

解压安装包后，双击 `CodexProxySetup.exe` 即可打开可视化安装向导。向导会引导你确认安装目录、桌面/开始菜单快捷方式以及安装完成后是否启动程序；本地代理端口在安装完成后从 Codex Proxy 的设置页面修改。

如果需要脚本化安装，也可以进入项目目录，在 Windows PowerShell 中运行：

```powershell
powershell.exe -NoLogo -NoProfile -File ".\Install-CodexProxy.ps1"
```

未指定端口时默认使用 `7891`。例如改用 `7890`：

```powershell
powershell.exe -NoLogo -NoProfile -File ".\Install-CodexProxy.ps1" -ProxyPort 7890
```

也可以安装到自定义目录；安装器会把绝对路径写入安装状态，后续修复、升级和卸载都会继续使用该目录：

```powershell
powershell.exe -NoLogo -NoProfile -File ".\Install-CodexProxy.ps1" -InstallDirectory "D:\install\CodexProxy"
```

安装器会先构建原生 `CodexProxy.exe`。首次安装时默认目录是 `%LOCALAPPDATA%\CodexProxy`；如果本机已经安装过 Codex Proxy，向导会按 Windows“已安装的应用”记录、开始菜单/桌面快捷方式、默认目录的顺序识别有效的 `CodexProxy.exe`，显示检测来源并锁定原目录进行覆盖升级。向导和底层安装脚本共用同一套识别规则，底层脚本也会拒绝把升级写入其他目录。安装器会创建桌面和开始菜单入口，并注册到 Windows“设置 → 应用 → 已安装的应用”。移动或删除源码仓库不会破坏已经安装的程序。代理端口由程序设置页维护，并保存在安装目录的 `CodexProxy.user.psd1` 中。

再次运行新版安装器或安装脚本即可覆盖升级。升级会保留已经保存的代理端口和用户配置，并通知正在运行的托盘程序安全退出后再替换文件。

如果确实希望快捷方式直接绑定当前项目目录，可使用便携模式：

```powershell
powershell.exe -NoLogo -NoProfile -File ".\Install-CodexProxy.ps1" -Portable -ProxyPort 7891
```

安装器不会静默覆盖不属于本项目的同名桌面快捷方式；确认需要替换时才使用 `-ForceShortcutReplacement`，原快捷方式会被备份，并在卸载时恢复。升级旧版时，安装器会自动把 PowerShell 启动快捷方式迁移到图形程序，并移除旧的独立更新脚本和更新快捷方式。

## 使用

1. 双击桌面的 `Codex-Proxy` 打开控制面板。
2. 打开“设置”，在“网络代理”中填写本地代理客户端的 HTTP/Mixed 端口，然后点击“保存更改”。
3. 从窗口顶部选择 Codex、Cursor 或 Grok Bot。启动器会自动识别常见安装目录及 Windows 安装记录，包括自定义安装位置。
4. “代理启动”页面显示“已就绪”后，点击“启动”按钮。如果应用已经运行，请先完全退出应用和托盘进程，再重新检测。

“应用管理”可以选择应用、修改启动配置，或添加其他程序。内置应用保留在列表中，自定义应用可以在配置窗口移除。配置包含程序位置、代理方式、独立代理端口和启动参数；启动参数每行一个，路径含空格也无需手动加引号。内置 Codex 继续使用 Store 包，不需要手动选择程序文件。

| 应用 | 启动方式 | 安装位置 |
| --- | --- | --- |
| Codex | 官方 Store 包启动、签名与 helper 检查、进程代理环境 | 自动发现可信 Store 包 |
| Cursor | Electron `--proxy-server` + HTTP / HTTPS 等环境变量 | 自动识别，或手动选择 `Cursor.exe` |
| Grok Bot | Electron 代理参数 + 环境变量，并适配 Grok Bot 的网络环境开关 | 自动识别，或手动选择 `Grok Bot.exe` |
| 自定义应用 | Electron 代理或环境变量模式 | 选择 `.exe` 文件 |

每个应用默认跟随全局端口，也可在“应用设置”中关闭“跟随默认代理端口”，使用独立端口。配置和当前选择保存在 `%LOCALAPPDATA%\CodexProxy\applications.json`，覆盖升级会保留；未安装的内置应用不会阻止其他应用启动。启动器不修改系统代理、永久环境变量或应用账号配置。

环境变量模式要求目标应用支持 `HTTP_PROXY` / `HTTPS_PROXY`。Electron 模式同时传入代理开关；应用内部的特殊网络实现仍可能需要应用自身的设置。Cursor 网络兼容模式与代理要求可参考 [Cursor 官方网络文档](https://cursor.com/docs/enterprise/network-configuration)；如果聊天连接异常，可在 Cursor 的 Network 设置中尝试 HTTP/1.1。Grok Bot 的企业网关与流式连接要求见 [官方代理文档](https://cursor.com/docs/grok-bot/proxies)。这里的连接检查验证 HTTP CONNECT 通道，不代表已经验证应用登录或聊天请求。

“运行诊断”跟随顶部所选应用，显示代理连接、应用版本、启动方式、程序位置和进程状态。Codex 额外检查 AppX 启动能力、快捷方式和文件签名。可以复制诊断摘要，用于排查问题。

“运行日志”读取本地启动和桌面日志，支持按级别、关键词筛选，并导出当前筛选结果。最多显示最近 500 条记录。

“设置”支持浅色、深色、跟随系统主题、开机启动、关闭窗口留在托盘，以及自动检测开关。界面偏好独立保存在 `%LOCALAPPDATA%\CodexProxy\desktop-settings.json`，升级会保留。

键盘操作：`F5` 重新检测，`Ctrl+Enter` 启动当前应用，`Alt+1` 代理启动，`Alt+2` 运行诊断，`Alt+3` 运行日志，`Alt+4` 设置，`Alt+5` 应用管理，`Ctrl+,` 打开设置，日志页的 `Ctrl+F` 聚焦搜索，`Esc` 关闭提示。

默认关闭控制面板会缩小到右下角托盘，可在设置中改为完全退出。托盘图标每 15 秒检查一次当前应用的代理连接、安装与运行状态：绿色表示启动环境可用，红色表示存在故障。已有应用进程的代理环境无法从进程存在这一点确认。双击托盘图标可重新打开控制面板；右键菜单可以切换应用、启动当前应用、刷新状态、打开管理和诊断页面，或完全退出。

“登录 Windows 后在后台自动运行”是可选项，默认关闭。开启后启动状态监控，需要时再手动启动应用。

启动器会依次验证代理端口、HTTP CONNECT、官方 Store 包身份、文件签名、AppX 启动能力和 Codex 当前进程。helper 缓存损坏或版本变化时会原子刷新；启动命令执行后还会确认 Codex 进程确实出现。

启动期间使用互斥锁，连续点击不会同时复制 helper 或重复启动同一个程序。应用启动或检测期间会锁定应用切换，防止状态串到另一个应用。图形程序本身也只允许一个托盘实例；重复打开会唤醒现有窗口。退出启动器会取消自身的后台检查，不会结束已经启动的应用。

### 临时使用其他端口

图形界面会保存端口。如需脚本化地临时使用其他端口且不修改已保存配置，仍可运行：

```powershell
powershell.exe -NoLogo -NoProfile -File "$env:LOCALAPPDATA\CodexProxy\Start-CodexProxy.ps1" -ProxyPort 7890
```

端口优先级为：命令行 `-ProxyPort` > `CodexProxy.user.psd1` > 默认值 `7891`。

## 内置自动更新

用户仍然只需双击 `Codex-Proxy`。Codex 官方内置更新器会在应用运行期间检查、下载并暂存 Microsoft Store 更新；启动器读取桌面日志中已经检测到的清单版本，并在每次启动前短暂等待 Windows 完成已暂存包的版本切换。

更新完成后，启动器会重新发现 AppX 包、验证官方应用文件签名、原子同步所有 `codex*.exe` helper，然后直接启动新版本。如果 Windows 尚未完成切换，启动器会把状态记录为 `AwaitingAppUpdater`，继续打开当前版本，让官方内置更新器继续下载或暂存；用户下次完全退出 Codex 并再次使用同一个快捷方式时即可应用。整个流程没有额外快捷方式、弹窗或手动更新命令。

更新协调器不再调用 `winget` 判断已安装 Store 包是否可升级，因为 Store 清单可能把版本报告为 `Unknown`，从而在官方内置更新器已经发现新版时仍返回“没有适用的更新”。旧版留下的失败状态会在系统包达到目标版本后自动纠正为成功。

自动更新不修改 WinHTTP、系统代理或永久环境变量。官方 Windows 安装、Store 分发和内置自动更新说明参考：<https://learn.chatgpt.com/docs/enterprise/windows-deployment>。

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

推荐在 Windows“设置 → 应用 → 已安装的应用 → Codex Proxy”中选择卸载，也可以使用开始菜单的“卸载 Codex Proxy”。默认会删除桌面/开始菜单快捷方式、开机启动项、卸载注册信息和稳定安装目录；不会卸载官方 Codex、代理客户端或 helper 缓存。

命令行卸载：

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

构建独立安装包（只输出到 `artifacts`，不会替换当前安装）：

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\Build-CodexProxyPackage.ps1"
```

测试覆盖 WPF 编译与绑定、四页导航、浅色/深色和窄窗口渲染、重复启动拦截、输入校验、偏好持久化与失败回退、日志筛选与导出、安装向导升级锁定和错误恢复，以及原有代理启动、托盘生命周期、快捷方式、helper 缓存和自动更新回归。测试用假运行服务隔离真实 Codex 和开机启动注册。GitHub Actions 会在 Windows PowerShell 5.1 下运行同一测试入口。

桌面渲染结果位于 `artifacts/desktop-4.1.0-preview`，安装向导渲染结果位于 `artifacts/setup-4.1.0-preview`。构建无需 Node.js、Rust、额外 NuGet 包或终端 .NET SDK。

## 项目结构

- `src/CodexProxy.App.cs`：WPF 应用生命周期、单实例事件、后台监控与托盘。
- `src/CodexProxy.MainWindow.cs`：窗口行为、响应式导航、剪贴板、导出和快捷键。
- `src/CodexProxy.ViewModel.cs`：可观察状态、异步命令、启动和设置流程。
- `src/CodexProxy.Runtime.cs`：PowerShell 进程桥、端口配置和类型化诊断结果。
- `src/CodexProxy.State.cs`：原子偏好存储、日志读取与轮转、通用命令。
- `src/CodexProxy.Ui.cs` 与 `src/Desktop/`：主题、窗口框架、共享控件模板与 XAML 页面。
- `src/CodexProxy.Setup.cs`：使用同一设计系统的异步安装与升级向导。
- `CodexProxy.files.psd1`：安装和打包共用的产品文件清单。
- `Generate-CodexProxyIcon.ps1`：生成包含 16–256 像素画布的应用图标资源。
- `Build-CodexProxyApp.ps1`：使用 Windows 自带 .NET Framework 编译器生成 `CodexProxy.exe`。
- `Build-CodexProxyPackage.ps1`：构建并打包独立安装目录与 ZIP 安装包，不修改现有安装。
- `Build-CodexProxyInstaller.ps1`：编译可视化 Windows 安装向导 `CodexProxySetup.exe`。
- `Start-CodexProxy.ps1`：无界面的安全启动内核，由图形程序调用。
- `Test-CodexProxy.ps1`：只读诊断和显式修复入口。
- `Install-CodexProxy.ps1`：构建应用、稳定安装、覆盖升级、开始菜单和卸载注册。
- `Uninstall-CodexProxy.ps1`：验证安装身份后移除程序、快捷方式和注册信息。
- `CodexProxy.config.psd1`：安全默认值和产品配置。
- `CodexProxy.user.psd1`：安装后生成的用户端口配置，不提交到 Git。
- `src/CodexProxy.Common.psm1`：配置、健康状态、AppX、helper 缓存、日志和启动生命周期。
- `tests/`：Windows PowerShell 5.1 回归测试。

## 配置边界

Codex 权限配置中的 `permissions.<name>.network.proxy_url` 是沙箱命令网络使用的代理监听器；官方文档同时说明，Codex 客户端服务流量使用单独的 HTTP/系统代理设置。本项目还需要覆盖 Desktop/Electron 主进程及其 CLI 子进程，因此使用进程级代理环境和 Electron `--proxy-server` 参数。官方参考：<https://learn.chatgpt.com/docs/permissions#what-the-network-proxy-does-not-control>。

## 声明

这是社区维护的非官方启动工具，与 OpenAI 无隶属或背书关系。Codex、OpenAI 及相关标识归其各自权利人所有。
