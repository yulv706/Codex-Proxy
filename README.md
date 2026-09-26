# Codex Proxy

Codex Proxy 是面向 OpenAI Codex Windows Desktop 的原生 Windows 代理启动与状态监控工具。3.5.8 版本提供首页、历史会话、历史同步和设置四页，代理端口、历史仓库、归档同步与开机启动集中在设置页。历史同步以用户选择的逻辑项目为边界，可把电脑 A 的 `A:\work` 与电脑 B 的 `B:\work` 绑定为同一项目。程序还提供托盘后台监控、运行中历史快照，以及安装、原目录覆盖升级和卸载功能。本版改进了高 DPI 与窄窗口布局：状态卡随宽度重排，长状态文字换行，历史同步列表保留可用高度，设置页消除了多余的横向滚动条。

若历史目录已经被旧版本生成的冲突副本污染，可使用安装目录中的 `Repair-CodexHistory.ps1` 先预览，再在 Codex 完全退出后执行 `-Apply`。修复器只处理指定工作目录，执行前会备份 `state_*.sqlite`、`session_index.jsonl` 并把待移出的 rollout 文件隔离到备份目录，便于回滚。

历史同步设置包含“历史会话同步”和“后台自动写入”两个开关。后台自动写入默认关闭；关闭时，程序不会因托盘监控、文件变化或 Codex 启停而自动修改本机历史文件，只能由用户点击“立即同步”主动应用。开启后才允许后台实时保存和退出时双向同步。

默认代理地址为 `http://127.0.0.1:7891`。安装完成后可在程序设置页修改本地代理端口；脚本化启动和诊断也支持临时指定端口。

本项目不包含 Codex++、远程调试端口或 Codex++ Proxy 逻辑。

## 系统要求

- Windows 10/11
- Windows PowerShell 5.1 和 .NET Framework 4.x（Windows 10/11 默认组件）
- 从官方 Microsoft Store 安装的 OpenAI Codex
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
2. 在“网络代理”中填写本地代理客户端的 HTTP/Mixed 端口，然后点击“保存端口”。
3. 控制面板显示“已就绪”后，点击“通过代理启动 Codex”。

### 跨电脑历史同步

1. 在“设置”中选择移动硬盘上的历史仓库。程序会在其中创建或连接 `.codex-history-vault`。
2. 打开“同步项目”。列表一行对应 Codex 的一个本机项目，而不是一个目录；项目名称、Codex 项目 UUID 和全部 `rootPaths` 会一起显示。一个项目有多个根目录，或多个项目共享根目录，都能被分别选择。
3. 在电脑 A 选择本机 Codex 项目并创建同步项目。在电脑 B 连接同一仓库后，选择 B 上对应的 Codex 项目，绑定到同一个同步项目。绑定比较 Codex 项目 UUID，不要求两台电脑的绝对路径或盘符相同；同一同步项目也可以包含多个不同的 Codex 项目成员。
4. 点击“立即同步”，或让托盘在 Codex 运行期间实时保存。会话按同步项目整理，并显示来源电脑与最后更新时间；导入后还会更新本机 Codex 的项目归属索引。

Codex 运行期间，托盘会监听活跃和归档会话文件，变化稳定约 2.5 秒后用共享读取方式保存完整 JSONL 记录；watcher 会在目录晚创建、配置变化或缓冲区溢出后自动重建，每 60 秒还有一次兜底检查。这个实时阶段只从 Codex 读取并写入历史仓库，不写 Codex 正在使用的 SQLite/WAL。通过本工具启动 Codex 时会先立即启动应用，再在后台执行增量保存，不会让大型历史仓库阻塞 Codex。其他电脑保存到仓库的会话会立即出现在“会话列表”中；把外部会话合并进本机 Codex 侧边栏则在托盘监控到 Codex 自然退出后安全执行，无需为了备份而手动完全退出。

同步只共享会话 JSONL、标题和必要元数据，不复制 `auth.json`、配置、插件、日志或整个 SQLite 目录。手动“立即同步”在 Codex 运行中执行实时保存，在 Codex 未运行时执行完整双向合并。完整同步和导入采用磁盘流式处理，大型 JSONL 不会整份常驻内存；同步期间会创建可恢复的事务标记，仓库对象路径会经过越界校验，索引更新采用去重后的原子重写；退出 Codex Proxy 时也会终止本程序仍在运行的同步子进程并释放仓库锁。

同一会话在两台电脑上继续时，如果一份内容是另一份的完整前缀，程序会安全采用较长版本。如果双方已经分叉，两个版本都会保留，另一分支会显示为“冲突副本”，不会静默覆盖。导入前会备份被更新的会话、`session_index.jsonl` 和状态数据库，备份位于 `%LOCALAPPDATA%\CodexProxy\history-backups`。

逻辑项目使用永久 UUID 标识，仓库对象中的结构化 `cwd` 会写成 `codex-project://<项目ID>`，多根目录项目会额外带 `/r1/...` 根目录索引。导入时再恢复为当前电脑绑定的对应根目录。若绑定目录和仓库都位于同一移动磁盘，程序还会记录卷内相对位置并适配盘符变化。聊天正文、命令输出和用户输入中的普通路径字符串不会被批量替换。

关闭控制面板不会退出程序，而是缩小到右下角托盘。托盘图标每 15 秒检查一次代理监听、Codex 安装与运行状态：绿色表示就绪或运行正常，黄色表示有待应用更新，红色表示存在故障。双击托盘图标可重新打开控制面板；右键菜单可启动 Codex、刷新状态、打开日志、运行详细诊断或退出监控。

“登录 Windows 后在后台自动运行”是可选项，默认关闭。开启后只启动状态监控，不会自动启动 Codex。

启动器会依次验证代理端口、HTTP CONNECT、官方 Store 包身份、文件签名、AppX 启动能力和 Codex 当前进程。helper 缓存损坏或版本变化时会原子刷新；启动命令执行后还会确认 Codex 进程确实出现。

启动期间使用互斥锁，连续点击不会同时复制 helper 或重复启动 Codex。图形程序本身也只允许一个托盘实例；重复打开会唤醒现有窗口。

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

测试覆盖原生应用编译、四页单窗口导航、紧凑窗口布局、列表列宽适配、关键设置可见性、后台托盘生命周期、安全退出、快捷方式识别、配置优先级与验证、启动锁、日志轮转、helper 原子刷新、历史项目选择、跨电脑目录绑定、未选目录隔离、增量合并、盘符变化、分叉冲突保留、SQLite 备份与回填，以及自动更新发现和包激活等待。GitHub Actions 会在 Windows PowerShell 5.1 下运行同一测试入口。

## 项目结构

- `src/CodexProxy.App.cs`：托盘菜单、后台状态监控与界面数据桥接。
- `src/CodexProxy.MainWindow.cs`：四页单窗口界面、响应式布局和交互状态。
- `src/CodexProxy.Ui.cs`：字体层级、代码绘制线性图标、品牌标识、颜色、圆角卡片、按钮、开关与列表等视觉组件。
- `Generate-CodexProxyIcon.ps1`：生成包含 16–256 像素画布的应用图标资源。
- `Build-CodexProxyApp.ps1`：使用 Windows 自带 .NET Framework 编译器生成 `CodexProxy.exe`。
- `Build-CodexProxyPackage.ps1`：构建并打包独立安装目录与 ZIP 安装包，不修改现有安装。
- `Build-CodexProxyInstaller.ps1`：编译可视化 Windows 安装向导 `CodexProxySetup.exe`。
- `Start-CodexProxy.ps1`：无界面的安全启动内核，由图形程序调用。
- `HistorySync.ps1`：可移动历史仓库、增量对象、冲突保留、路径映射、备份与 Codex 索引回填。
- `docs/history-sync-design.md`：同步边界、仓库格式、冲突规则、SQLite 回填和恢复设计。
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
