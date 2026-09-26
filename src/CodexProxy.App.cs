using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: System.Reflection.AssemblyTitle("Codex Proxy")]
[assembly: System.Reflection.AssemblyDescription("OpenAI Codex Windows 本地代理启动与状态监控工具")]
[assembly: System.Reflection.AssemblyCompany("Codex Proxy Community")]
[assembly: System.Reflection.AssemblyProduct("Codex Proxy")]
[assembly: System.Reflection.AssemblyCopyright("Community maintained")]
[assembly: System.Reflection.AssemblyVersion("3.5.8.0")]
[assembly: System.Reflection.AssemblyFileVersion("3.5.8.0")]

namespace CodexProxyDesktop
{
    internal static class Program
    {
        private const string InstanceMutexNameBase = "Local\\CodexProxy.Tray.Instance";
        private const string ShowEventNameBase = "Local\\CodexProxy.Tray.Show";
        private const string ExitEventNameBase = "Local\\CodexProxy.Tray.Exit";

        [STAThread]
        private static void Main(string[] args)
        {
            try { NativeMethods.SetProcessDPIAware(); } catch { }

            if (HasArgument(args, "--self-test-powershell"))
            {
                RuntimeBridge bridge = new RuntimeBridge(AppDomain.CurrentDomain.BaseDirectory);
                Environment.ExitCode = bridge.HasPowerShellDataFileCommand() ? 0 : 1;
                bridge.Dispose();
                return;
            }

            if (HasArgument(args, "--self-test-process-cleanup"))
            {
                RuntimeBridge bridge = new RuntimeBridge(AppDomain.CurrentDomain.BaseDirectory);
                Environment.ExitCode = bridge.VerifyOutstandingProcessCleanup() ? 0 : 1;
                return;
            }

            if (HasArgument(args, "--self-test-ui"))
            {
                try
                {
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    using (MainWindow testWindow = new MainWindow(7891, delegate(int unused) { }, delegate { }, delegate { }, delegate { },
                        delegate(bool unused) { }, delegate { }, delegate { }, delegate(bool unused) { }, delegate(bool unused) { }, delegate(bool unused) { }, delegate { }, delegate { },
                        delegate { }, delegate(string unusedCodexId, string unusedPath, string unusedName) { }, delegate(string unusedId, string unusedCodexId, string unusedPath) { }, delegate(string unusedId) { }))
                    {
                        foreach (string page in new[] { "overview", "sessions", "sync", "settings" })
                        {
                            testWindow.ShowPage(page);
                            if (!string.Equals(testWindow.CurrentPage, page, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("UI page navigation failed: " + page);
                        }
                        testWindow.ShowPage("projects");
                        if (!string.Equals(testWindow.CurrentPage, "sync", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Legacy project page alias failed.");
                        if (!testWindow.UsesVectorNavigationIcons) throw new InvalidOperationException("Vector navigation icon system is incomplete.");
                        if (!testWindow.UsesRefinedTypography) throw new InvalidOperationException("Typography system was not applied.");
                        HistoryVaultListResult fixture = new HistoryVaultListResult { Success=true, VaultPath="F:\\fixture" };
                        fixture.Entries.Add(new HistoryVaultEntry { ThreadId="00000000-0000-0000-0000-000000000001", Title="中文会话标题", WorkingDirectory="F:\\项目甲", MachineNames="电脑甲", ContentLength=1024 });
                        fixture.Entries.Add(new HistoryVaultEntry { ThreadId="00000000-0000-0000-0000-000000000002", Title="归档会话", WorkingDirectory="F:\\项目甲", MachineNames="电脑甲", Archived=true, ContentLength=2048 });
                        testWindow.ApplyHistoryList(fixture);
                        if (testWindow.VisibleSessionCount != 1 || testWindow.FirstVisibleSessionTitle != "中文会话标题") throw new InvalidOperationException("Embedded history page rendering failed.");
                        HistoryProjectCatalogResult projectFixture = new HistoryProjectCatalogResult { Success=true, VaultPath="F:\\fixture" };
                        projectFixture.LocalDirectories.Add(new HistoryLocalDirectory { Path="F:\\项目甲", ActiveSessionCount=2 });
                        projectFixture.Projects.Add(new HistoryProjectInfo { ProjectId="00000000-0000-0000-0000-000000000010", Name="项目甲", Bound=true, LocalPath="F:\\项目甲", SessionCount=2 });
                        testWindow.ApplyProjectCatalog(projectFixture);
                        if (testWindow.VisibleLocalProjectCount != 1 || testWindow.VisibleSharedProjectCount != 1) throw new InvalidOperationException("Project binding page rendering failed.");
                        testWindow.ClientSize = new Size(940, 660);
                        testWindow.PerformLayout();
                        Application.DoEvents();
                        if (!testWindow.CompactLayoutActive) throw new InvalidOperationException("Compact navigation layout did not activate.");
                        if (!testWindow.SessionColumnsFit) throw new InvalidOperationException("Responsive session columns overflowed.");
                        if (!testWindow.ProjectColumnsFit) throw new InvalidOperationException("Responsive project columns overflowed: " + testWindow.ProjectColumnDiagnostics);
                        testWindow.ShowPage("settings");
                        if (!testWindow.HistoryVaultPickerVisible) throw new InvalidOperationException("History vault picker is not visible in settings.");
                        testWindow.ClientSize = new Size(1180, 760);
                        testWindow.ShowPage("overview");
                        testWindow.ApplyStatus(new DiagnosticStatus
                        {
                            ProxyReady = true, ProxyUrl = "http://127.0.0.1:7891", CodexInstalled = true,
                            CodexRunning = true, RuntimeReadyNow = true, CodexVersion = "26.917.6896.0",
                            ReportedUpdateVersion = "26.917.8451.0", UpdatePending = true,
                            CheckedAt = DateTime.Now, Title = "Codex 正在运行"
                        });
                        testWindow.PerformLayout();
                        testWindow.VerifyOverviewTextLayout();
                        testWindow.ApplyStatus(DiagnosticStatus.FromError("PROXY_UNAVAILABLE", "本地代理连接失败，请检查代理程序是否正在运行，并确认代理地址和端口与 Codex Proxy 设置一致。"));
                        testWindow.PerformLayout();
                        testWindow.VerifyOverviewTextLayout();
                        testWindow.ClientSize = new Size(940, 660);
                        testWindow.PerformLayout();
                        testWindow.VerifyOverviewTextLayout();
                    }
                }
                catch (Exception ex)
                {
                    try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "CodexProxy-ui-selftest.log"), ex.ToString(), Encoding.UTF8); } catch { }
                    Environment.ExitCode = 1;
                }
                return;
            }

            string instanceSuffix = GetInstanceSuffix(args);
            string instanceMutexName = InstanceMutexNameBase + instanceSuffix;
            string showEventName = ShowEventNameBase + instanceSuffix;
            string exitEventName = ExitEventNameBase + instanceSuffix;

            bool createdNew;
            using (Mutex instanceMutex = new Mutex(true, instanceMutexName, out createdNew))
            {
                if (!createdNew)
                {
                    SignalExistingInstance(showEventName);
                    return;
                }

                bool background = HasArgument(args, "--background") || HasArgument(args, "/background");
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                bool showCreated;
                bool exitCreated;
                using (EventWaitHandle showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, showEventName, out showCreated))
                using (EventWaitHandle exitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, exitEventName, out exitCreated))
                using (TrayApplicationContext context = new TrayApplicationContext(background))
                {
                    RegisteredWaitHandle showWait = ThreadPool.RegisterWaitForSingleObject(showEvent, delegate { context.RequestShow(); }, null, Timeout.Infinite, false);
                    RegisteredWaitHandle exitWait = ThreadPool.RegisterWaitForSingleObject(exitEvent, delegate { context.RequestExit(); }, null, Timeout.Infinite, false);
                    Application.Run(context);
                    showWait.Unregister(null);
                    exitWait.Unregister(null);
                }
            }
        }

        private static bool HasArgument(string[] args, string value)
        {
            foreach (string arg in args)
            {
                if (string.Equals(arg, value, StringComparison.OrdinalIgnoreCase)) return true;
            }
            return false;
        }

        private static string GetInstanceSuffix(string[] args)
        {
            const string prefix = "--instance-suffix=";
            foreach (string arg in args)
            {
                if (!arg.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
                string value = Regex.Replace(arg.Substring(prefix.Length), "[^A-Za-z0-9_-]", string.Empty);
                if (value.Length > 40) value = value.Substring(0, 40);
                return value.Length == 0 ? string.Empty : "." + value;
            }
            return string.Empty;
        }

        private static void SignalExistingInstance(string showEventName)
        {
            try
            {
                using (EventWaitHandle showEvent = EventWaitHandle.OpenExisting(showEventName)) showEvent.Set();
            }
            catch { }
        }
    }

    internal sealed class TrayApplicationContext : ApplicationContext, IDisposable
    {
        private readonly RuntimeBridge bridge;
        private readonly MainWindow window;
        private readonly NotifyIcon notifyIcon;
        private readonly System.Windows.Forms.Timer monitorTimer;
        private readonly ToolStripMenuItem statusMenuItem;
        private readonly ToolStripMenuItem historyStatusMenuItem;
        private readonly ToolStripMenuItem startupMenuItem;
        private readonly List<FileSystemWatcher> historyWatchers = new List<FileSystemWatcher>();
        private readonly System.Windows.Forms.Timer liveSyncDebounceTimer;
        private Icon statusIcon;
        private int monitorRunning;
        private int historySyncRunning;
        private int projectOperationRunning;
        private bool? previousCodexRunning;
        private DiagnosticStatus latestDiagnosticStatus;
        private HistorySyncStatus latestHistoryStatus;
        private DateTime lastLiveSyncUtc = DateTime.MinValue;
        private DateTime lastWatcherRefreshUtc = DateTime.MinValue;
        private bool historyWatcherNeedsRefresh;
        private bool exiting;
        private bool trayTipShown;

        internal TrayApplicationContext(bool background)
        {
            bridge = new RuntimeBridge(AppDomain.CurrentDomain.BaseDirectory);
            window = new MainWindow(
                bridge.ReadSavedPort(),
                delegate(int port) { SavePort(port); },
                delegate { LaunchCodex(); },
                delegate { RefreshStatus(); },
                delegate { bridge.OpenLogDirectory(); },
                delegate(bool enabled) { SetStartup(enabled); },
                delegate { ConfigureHistoryVault(); },
                delegate { SyncHistory(false); },
                delegate(bool enabled) { SetHistoryEnabled(enabled); },
                delegate(bool enabled) { SetHistoryAutomaticWriteEnabled(enabled); },
                delegate(bool enabled) { SetHistoryArchivedEnabled(enabled); },
                delegate { OpenHistoryVault(); },
                delegate { ShowHistoryPage(); },
                delegate { ShowProjectsPage(); },
                delegate(string codexProjectId, string path, string name) { CreateHistoryProject(codexProjectId, path, name); },
                delegate(string projectId, string codexProjectId, string path) { BindHistoryProject(projectId, codexProjectId, path); },
                delegate(string projectId) { UnbindHistoryProject(projectId); });
            window.StartupEnabled = bridge.IsStartupEnabled();
            window.FormClosing += OnWindowClosing;
            window.ExitRequested += delegate { RequestExit(); };
            IntPtr unusedHandle = window.Handle;

            ContextMenuStrip menu = new ContextMenuStrip();
            statusMenuItem = new ToolStripMenuItem("正在检查状态…");
            statusMenuItem.Enabled = false;
            menu.Items.Add(statusMenuItem);
            historyStatusMenuItem = new ToolStripMenuItem("历史同步：正在检查…");
            historyStatusMenuItem.Enabled = false;
            menu.Items.Add(historyStatusMenuItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("打开 Codex Proxy", null, delegate { ShowWindow(); });
            menu.Items.Add("启动 Codex", null, delegate { LaunchCodex(); });
            menu.Items.Add("立即同步", null, delegate { SyncHistory(false); });
            menu.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem moreMenu = new ToolStripMenuItem("更多");
            moreMenu.DropDownItems.Add("刷新状态", null, delegate { RefreshStatus(); });
            moreMenu.DropDownItems.Add("历史会话", null, delegate { ShowHistoryPage(); });
            moreMenu.DropDownItems.Add("历史同步", null, delegate { ShowProjectsPage(); });
            moreMenu.DropDownItems.Add("设置", null, delegate { ShowWindow(); window.ShowPage("settings"); });
            moreMenu.DropDownItems.Add(new ToolStripSeparator());
            moreMenu.DropDownItems.Add("打开日志", null, delegate { bridge.OpenLogDirectory(); });
            moreMenu.DropDownItems.Add("详细诊断", null, delegate { bridge.OpenDetailedDiagnostic(); });
            menu.Items.Add(moreMenu);
            menu.Items.Add(new ToolStripSeparator());
            startupMenuItem = new ToolStripMenuItem("登录 Windows 后自动运行");
            startupMenuItem.CheckOnClick = true;
            startupMenuItem.Checked = bridge.IsStartupEnabled();
            startupMenuItem.CheckedChanged += delegate { SetStartup(startupMenuItem.Checked); };
            menu.Items.Add(startupMenuItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出状态监控", null, delegate { RequestExit(); });

            notifyIcon = new NotifyIcon();
            notifyIcon.ContextMenuStrip = menu;
            notifyIcon.Text = "Codex Proxy - 正在检查状态";
            notifyIcon.Icon = CreateStatusIcon(Color.FromArgb(100, 116, 139));
            statusIcon = notifyIcon.Icon;
            notifyIcon.Visible = true;
            notifyIcon.DoubleClick += delegate { ShowWindow(); };

            monitorTimer = new System.Windows.Forms.Timer();
            monitorTimer.Interval = 15000;
            monitorTimer.Tick += delegate { RefreshStatus(); };
            monitorTimer.Start();

            liveSyncDebounceTimer = new System.Windows.Forms.Timer();
            liveSyncDebounceTimer.Interval = 2500;
            liveSyncDebounceTimer.Tick += delegate
            {
                liveSyncDebounceTimer.Stop();
                if (latestDiagnosticStatus != null && latestDiagnosticStatus.CodexRunning && latestHistoryStatus != null && latestHistoryStatus.AutomaticReady)
                    SyncHistory(true);
            };
            InitializeHistoryWatchers();

            if (!background) ShowWindow();
            RefreshStatus();
        }

        internal void RequestShow()
        {
            SafeBeginInvoke(delegate { ShowWindow(); });
        }

        internal void RequestExit()
        {
            SafeBeginInvoke(delegate
            {
                if (exiting) return;
                exiting = true;
                monitorTimer.Stop();
                liveSyncDebounceTimer.Stop();
                bridge.Dispose();
                notifyIcon.Visible = false;
                window.AllowExit = true;
                window.Close();
                ExitThread();
            });
        }

        private void ShowWindow()
        {
            if (window.Visible && window.WindowState != FormWindowState.Minimized)
            {
                window.Activate();
                return;
            }
            window.Show();
            window.WindowState = FormWindowState.Normal;
            window.ShowInTaskbar = true;
            window.BringToFront();
            window.Activate();
        }

        private void OnWindowClosing(object sender, FormClosingEventArgs e)
        {
            if (exiting || window.AllowExit) return;
            e.Cancel = true;
            window.Hide();
            window.ShowInTaskbar = false;
            if (!trayTipShown)
            {
                trayTipShown = true;
                notifyIcon.ShowBalloonTip(2500, "Codex Proxy 正在后台运行", "可从右下角托盘重新打开。", ToolTipIcon.Info);
            }
        }

        private void RefreshStatus()
        {
            if (Interlocked.CompareExchange(ref monitorRunning, 1, 0) != 0) return;
            window.SetChecking();
            ThreadPool.QueueUserWorkItem(delegate
            {
                DiagnosticStatus status = bridge.GetStatus();
                HistorySyncStatus historyStatus = bridge.GetHistorySyncStatus();
                SafeBeginInvoke(delegate
                {
                    Interlocked.Exchange(ref monitorRunning, 0);
                    ApplyStatus(status);
                    ApplyHistoryStatus(historyStatus);
                });
            });
        }

        private void ApplyStatus(DiagnosticStatus status)
        {
            latestDiagnosticStatus = status;
            window.ApplyStatus(status);
            statusMenuItem.Text = status.TraySummary;
            notifyIcon.Text = LimitNotifyText("Codex Proxy - " + status.TraySummary);
            ReplaceStatusIcon(status.StatusColor);
            bool shouldSyncAfterExit = previousCodexRunning.HasValue && previousCodexRunning.Value && !status.CodexRunning;
            previousCodexRunning = status.CodexRunning;
            if (DateTime.UtcNow.Subtract(lastWatcherRefreshUtc).TotalSeconds >= 30 || historyWatcherNeedsRefresh)
            {
                RefreshHistoryWatchers();
            }
            if (shouldSyncAfterExit && latestHistoryStatus != null && latestHistoryStatus.AutomaticReady) SyncHistory(true);
            else if (status.CodexRunning && latestHistoryStatus != null && latestHistoryStatus.AutomaticReady && DateTime.UtcNow.Subtract(lastLiveSyncUtc).TotalSeconds >= 60)
                SyncHistory(true);
        }

        private void ApplyHistoryStatus(HistorySyncStatus status)
        {
            latestHistoryStatus = status;
            window.ApplyHistoryStatus(status);
            historyStatusMenuItem.Text = status.TrayDescription;
        }

        private void LaunchCodex()
        {
            if (Interlocked.CompareExchange(ref monitorRunning, 1, 0) != 0) return;
            window.SetLaunching();
            statusMenuItem.Text = "正在启动 Codex…";
            notifyIcon.Text = "Codex Proxy - 正在启动 Codex";
            ReplaceStatusIcon(Color.FromArgb(37, 99, 235));
            ThreadPool.QueueUserWorkItem(delegate
            {
                LaunchResult result = bridge.LaunchCodex();
                DiagnosticStatus status = bridge.GetStatus();
                HistorySyncStatus historyStatus = bridge.GetHistorySyncStatus();
                SafeBeginInvoke(delegate
                {
                    Interlocked.Exchange(ref monitorRunning, 0);
                    ApplyStatus(status);
                    ApplyHistoryStatus(historyStatus);
                    if (result.Success)
                    {
                        notifyIcon.ShowBalloonTip(2500, "Codex Proxy", "Codex 已通过本地代理启动。", ToolTipIcon.Info);
                        if (historyStatus.AutomaticReady) SyncHistory(true);
                    }
                    else
                    {
                        notifyIcon.ShowBalloonTip(5000, "Codex 启动失败", result.Message, ToolTipIcon.Error);
                        ShowWindow();
                        window.ShowActionError(result.Message);
                    }
                });
            });
        }

        private void ConfigureHistoryVault()
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "选择移动硬盘上的共享目录。程序会在其中创建 .codex-history-vault 子目录。";
                dialog.ShowNewFolderButton = true;
                if (dialog.ShowDialog(window) != DialogResult.OK) return;
                string selectedPath = dialog.SelectedPath;
                window.SetHistoryWorking("正在创建并验证历史仓库…");
                ThreadPool.QueueUserWorkItem(delegate
                {
                    HistorySyncStatus status = bridge.ConfigureHistoryVault(selectedPath);
                    SafeBeginInvoke(delegate
                    {
                        ApplyHistoryStatus(status);
                        if (status.Success)
                        {
                            window.ShowActionSuccess("历史仓库已配置。请在“同步项目”页面选择需要参与同步的工作目录。");
                            if (window.CurrentPage == "sync") RefreshProjectPage();
                        }
                        else window.ShowActionError(status.Message);
                    });
                });
            }
        }

        private void SyncHistory(bool automatic)
        {
            if (automatic && (latestHistoryStatus == null || !latestHistoryStatus.AutomaticReady)) return;
            if (Interlocked.CompareExchange(ref historySyncRunning, 1, 0) != 0) return;
            bool live = latestDiagnosticStatus != null && latestDiagnosticStatus.CodexRunning;
            window.SetHistoryWorking(automatic ? (live ? "检测到会话变化，正在实时保存…" : "Codex 已退出，正在应用双向同步…") : "正在无损同步 Codex 历史…");
            lastLiveSyncUtc = DateTime.UtcNow;
            historyStatusMenuItem.Text = "历史同步：正在同步…";
            ThreadPool.QueueUserWorkItem(delegate
            {
                HistorySyncResult result = bridge.SyncHistory(automatic);
                HistorySyncStatus status = bridge.GetHistorySyncStatus();
                SafeBeginInvoke(delegate
                {
                    Interlocked.Exchange(ref historySyncRunning, 0);
                    ApplyHistoryStatus(status);
                    if (result.Success && !result.AutomaticBlocked)
                    {
                        window.ShowActionSuccess(result.Message);
                        if (!automatic && (result.Imported + result.Updated + result.Conflicts) > 0)
                            notifyIcon.ShowBalloonTip(3500, "Codex 历史同步完成", result.Message, ToolTipIcon.Info);
                    }
                    else if (!result.Success)
                    {
                        window.ShowActionError("历史同步失败：" + result.Message);
                        if (!automatic)
                        {
                            ShowWindow();
                            notifyIcon.ShowBalloonTip(5000, "Codex 历史同步失败", result.Message, ToolTipIcon.Warning);
                        }
                    }
                    if (result.LiveMode && !status.CodexRunning && status.AutomaticReady) SyncHistory(true);
                });
            });
        }

        private void SetHistoryEnabled(bool enabled)
        {
            HistorySyncStatus status = bridge.SetHistoryEnabled(enabled);
            ApplyHistoryStatus(status);
            if (!status.Success) window.ShowActionError(status.Message);
            else window.ShowActionSuccess(enabled ? "历史会话同步已启用。" : "历史会话同步已暂停；仓库和历史不会被删除。");
        }

        private void SetHistoryAutomaticWriteEnabled(bool enabled)
        {
            HistorySyncStatus status = bridge.SetHistoryAutomaticWriteEnabled(enabled);
            ApplyHistoryStatus(status);
            if (!status.Success) window.ShowActionError(status.Message);
            else window.ShowActionSuccess(enabled ? "后台自动写入已启用。" : "后台自动写入已关闭；需要点击“立即同步”应用历史变更。");
        }

        private void SetHistoryArchivedEnabled(bool enabled)
        {
            HistorySyncStatus status = bridge.SetHistoryArchivedEnabled(enabled);
            ApplyHistoryStatus(status);
            if (!status.Success) window.ShowActionError(status.Message);
            else window.ShowActionSuccess(enabled ? "已归档会话将参与同步。" : "已归档会话已排除在同步之外；仓库中的旧对象不会删除。");
        }

        private void OpenHistoryVault()
        {
            HistorySyncResult result = bridge.OpenHistoryVault();
            if (!result.Success) window.ShowActionError(result.Message);
        }

        private void InitializeHistoryWatchers()
        {
            RefreshHistoryWatchers();
        }

        private void RefreshHistoryWatchers()
        {
            lastWatcherRefreshUtc = DateTime.UtcNow;
            historyWatcherNeedsRefresh = false;
            foreach (FileSystemWatcher watcher in historyWatchers)
            {
                try { watcher.EnableRaisingEvents = false; watcher.Dispose(); } catch { }
            }
            historyWatchers.Clear();
            foreach (string directory in bridge.GetCodexSessionDirectories())
            {
                try
                {
                    string parent = Path.GetDirectoryName(directory);
                    if (!Directory.Exists(directory))
                    {
                        if (!Directory.Exists(parent)) continue;
                        Directory.CreateDirectory(directory);
                    }
                    FileSystemWatcher watcher = new FileSystemWatcher(directory, "rollout-*.jsonl");
                    watcher.IncludeSubdirectories = true;
                    watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size;
                    FileSystemEventHandler changed = delegate { ScheduleLiveHistorySync(); };
                    RenamedEventHandler renamed = delegate { ScheduleLiveHistorySync(); };
                    watcher.Changed += changed;
                    watcher.Created += changed;
                    watcher.Deleted += changed;
                    watcher.Renamed += renamed;
                    watcher.Error += delegate { historyWatcherNeedsRefresh = true; ScheduleLiveHistorySync(); };
                    watcher.EnableRaisingEvents = true;
                    historyWatchers.Add(watcher);
                }
                catch { }
            }
        }

        private void ScheduleLiveHistorySync()
        {
            SafeBeginInvoke(delegate
            {
                if (latestDiagnosticStatus == null || !latestDiagnosticStatus.CodexRunning || latestHistoryStatus == null || !latestHistoryStatus.AutomaticReady) return;
                liveSyncDebounceTimer.Stop();
                liveSyncDebounceTimer.Start();
            });
        }

        private void ShowHistoryPage()
        {
            ShowWindow();
            window.ShowPage("sessions");
            RefreshHistoryPage();
        }

        private void RefreshHistoryPage()
        {
            window.SetHistoryListLoading();
            ThreadPool.QueueUserWorkItem(delegate
            {
                HistoryVaultListResult result = bridge.GetHistoryVaultList();
                SafeBeginInvoke(delegate
                {
                    window.ApplyHistoryList(result);
                });
            });
        }

        private void ShowProjectsPage()
        {
            ShowWindow();
            window.ShowPage("sync");
            RefreshProjectPage();
        }

        private void RefreshProjectPage()
        {
            if (Interlocked.CompareExchange(ref projectOperationRunning, 1, 0) != 0) return;
            window.SetProjectCatalogLoading("正在读取 Codex 项目与共享同步项目…");
            ThreadPool.QueueUserWorkItem(delegate
            {
                HistoryProjectCatalogResult result = bridge.GetHistoryProjectCatalog();
                SafeBeginInvoke(delegate
                {
                    Interlocked.Exchange(ref projectOperationRunning, 0);
                    window.ApplyProjectCatalog(result);
                });
            });
        }

        private void CreateHistoryProject(string codexProjectId, string localPath, string projectName)
        {
            RunProjectOperation(delegate { return bridge.CreateHistoryProject(codexProjectId, localPath, projectName); }, "已创建同步项目并绑定本机 Codex 项目。正在首次保存该项目的会话…");
        }

        private void BindHistoryProject(string projectId, string codexProjectId, string localPath)
        {
            RunProjectOperation(delegate { return bridge.BindHistoryProject(projectId, codexProjectId, localPath); }, "Codex 项目绑定已保存。正在整理并同步该项目的会话…");
        }

        private void UnbindHistoryProject(string projectId)
        {
            RunProjectOperation(delegate { return bridge.UnbindHistoryProject(projectId); }, "已停止同步该项目；仓库与本机会话均未删除。", false);
        }

        private void RunProjectOperation(Func<HistoryProjectCatalogResult> operation, string successMessage)
        {
            RunProjectOperation(operation, successMessage, true);
        }

        private void RunProjectOperation(Func<HistoryProjectCatalogResult> operation, string successMessage, bool syncAfter)
        {
            if (Interlocked.CompareExchange(ref projectOperationRunning, 1, 0) != 0) return;
            window.SetProjectCatalogLoading("正在保存 Codex 项目绑定…");
            ThreadPool.QueueUserWorkItem(delegate
            {
                HistoryProjectCatalogResult result = operation();
                HistorySyncStatus status = bridge.GetHistorySyncStatus();
                SafeBeginInvoke(delegate
                {
                    Interlocked.Exchange(ref projectOperationRunning, 0);
                    window.ApplyProjectCatalog(result);
                    ApplyHistoryStatus(status);
                    if (!result.Success) { window.ShowActionError(result.Message); return; }
                    window.ShowActionSuccess(successMessage);
                    if (syncAfter && status.AutomaticReady) SyncHistory(true);
                });
            });
        }

        private void SavePort(int port)
        {
            try
            {
                bridge.SavePort(port);
                window.ShowActionSuccess("代理端口已保存为 " + port + "。下一次启动立即生效。");
                RefreshStatus();
            }
            catch (Exception ex)
            {
                window.ShowActionError("保存端口失败：" + ex.Message);
            }
        }

        private void SetStartup(bool enabled)
        {
            try
            {
                bridge.SetStartup(enabled);
                startupMenuItem.Checked = enabled;
                window.StartupEnabled = enabled;
            }
            catch (Exception ex)
            {
                startupMenuItem.Checked = bridge.IsStartupEnabled();
                window.StartupEnabled = startupMenuItem.Checked;
                window.ShowActionError("修改开机启动失败：" + ex.Message);
            }
        }

        private void ReplaceStatusIcon(Color color)
        {
            Icon replacement = CreateStatusIcon(color);
            notifyIcon.Icon = replacement;
            if (statusIcon != null) statusIcon.Dispose();
            statusIcon = replacement;
        }

        private static Icon CreateStatusIcon(Color color)
        {
            using (Bitmap bitmap = new Bitmap(32, 32))
            using (Graphics graphics = Graphics.FromImage(bitmap))
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.Clear(Color.Transparent);
                IconPainter.DrawBrandMark(graphics, new Rectangle(1, 1, 30, 30), Ui.Accent);
                using (Brush rim = new SolidBrush(Color.White)) graphics.FillEllipse(rim, 20, 20, 11, 11);
                using (Brush status = new SolidBrush(color)) graphics.FillEllipse(status, 22, 22, 7, 7);
                IntPtr handle = bitmap.GetHicon();
                try
                {
                    using (Icon temporary = Icon.FromHandle(handle)) return (Icon)temporary.Clone();
                }
                finally { NativeMethods.DestroyIcon(handle); }
            }
        }

        private static string LimitNotifyText(string text)
        {
            return text.Length <= 63 ? text : text.Substring(0, 63);
        }

        private void SafeBeginInvoke(Action action)
        {
            if (exiting) return;
            try
            {
                if (window.IsDisposed) return;
                window.BeginInvoke(action);
            }
            catch (ObjectDisposedException) { }
            catch (InvalidOperationException) { }
        }

        public new void Dispose()
        {
            monitorTimer.Dispose();
            liveSyncDebounceTimer.Dispose();
            foreach (FileSystemWatcher watcher in historyWatchers) watcher.Dispose();
            notifyIcon.Dispose();
            if (statusIcon != null) statusIcon.Dispose();
            bridge.Dispose();
            window.Dispose();
            base.Dispose();
        }
    }

    internal sealed class RuntimeBridge : IDisposable
    {
        private const string RunRegistryPath = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        private const string RunValueName = "CodexProxy";
        private readonly string root;
        private readonly string diagnosticPath;
        private readonly string launcherPath;
        private readonly string historySyncPath;
        private readonly string userConfigPath;
        private readonly string defaultConfigPath;
        private readonly string logPath;
        private readonly object processGate = new object();
        private readonly List<Process> activeProcesses = new List<Process>();
        private bool disposed;

        internal RuntimeBridge(string applicationRoot)
        {
            root = Path.GetFullPath(applicationRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            diagnosticPath = Path.Combine(root, "Test-CodexProxy.ps1");
            launcherPath = Path.Combine(root, "Start-CodexProxy.ps1");
            historySyncPath = Path.Combine(root, "HistorySync.ps1");
            userConfigPath = Path.Combine(root, "CodexProxy.user.psd1");
            defaultConfigPath = Path.Combine(root, "CodexProxy.config.psd1");
            logPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexProxy", "logs", "launcher.log");
        }

        internal int ReadSavedPort()
        {
            int port;
            if (TryReadPort(userConfigPath, out port)) return port;
            if (TryReadPort(defaultConfigPath, out port)) return port;
            return 7891;
        }

        internal bool HasPowerShellDataFileCommand()
        {
            ProcessResult result = RunPowerShell("-NoLogo -NoProfile -NonInteractive -Command \"if (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue) { exit 0 } else { exit 41 }\"", true);
            return result.ExitCode == 0;
        }

        internal bool VerifyOutstandingProcessCleanup()
        {
            bool started = false;
            Thread worker = new Thread(new ThreadStart(delegate
            {
                RunPowerShell("-NoLogo -NoProfile -NonInteractive -Command \"Start-Sleep -Seconds 30\"", true);
            }));
            worker.IsBackground = true;
            worker.Start();
            DateTime deadline = DateTime.UtcNow.AddSeconds(3);
            while (DateTime.UtcNow < deadline)
            {
                lock (processGate) { if (activeProcesses.Count > 0) { started = true; break; } }
                Thread.Sleep(25);
            }
            Dispose();
            return started && worker.Join(3000);
        }

        internal void SavePort(int port)
        {
            if (port < 1 || port > 65535) throw new ArgumentOutOfRangeException("port");
            string temporaryPath = userConfigPath + ".writing-" + Guid.NewGuid().ToString("N") + ".tmp";
            string contents = "@{\r\n    ProxyPort = " + port + "\r\n}\r\n";
            File.WriteAllText(temporaryPath, contents, new UTF8Encoding(true));
            try
            {
                if (File.Exists(userConfigPath)) File.Replace(temporaryPath, userConfigPath, null);
                else File.Move(temporaryPath, userConfigPath);
            }
            finally
            {
                if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
            }
        }

        internal DiagnosticStatus GetStatus()
        {
            if (!File.Exists(diagnosticPath)) return DiagnosticStatus.FromError("DIAGNOSTIC_MISSING", "找不到状态诊断脚本，请重新安装 Codex Proxy。");
            ProcessResult result = RunPowerShell("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(diagnosticPath) + " -Json -Monitor", true);
            string json = result.StandardOutput.Trim();
            if (json.Length == 0) return DiagnosticStatus.FromError("DIAGNOSTIC_FAILED", FirstUseful(result.StandardError, "状态检查没有返回结果。"));
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> values = serializer.Deserialize<Dictionary<string, object>>(json);
                return DiagnosticStatus.FromValues(values, result.ExitCode);
            }
            catch (Exception ex)
            {
                return DiagnosticStatus.FromError("DIAGNOSTIC_JSON_INVALID", "无法读取状态结果：" + ex.Message);
            }
        }

        internal LaunchResult LaunchCodex()
        {
            if (!File.Exists(launcherPath)) return new LaunchResult(false, "找不到启动脚本，请重新安装 Codex Proxy。");
            ProcessResult result = RunPowerShell("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(launcherPath) + " -NoUI", true);
            if (result.ExitCode == 0) return new LaunchResult(true, "Codex 已启动。");
            return new LaunchResult(false, FirstUseful(result.StandardError, FirstUseful(result.StandardOutput, "启动失败，退出码 " + result.ExitCode + "。")));
        }

        internal HistorySyncStatus GetHistorySyncStatus()
        {
            return RunHistoryStatus("Status", null);
        }

        internal HistorySyncStatus ConfigureHistoryVault(string path)
        {
            return RunHistoryStatus("Configure", " -VaultPath " + Quote(path));
        }

        internal HistorySyncStatus SetHistoryEnabled(bool enabled)
        {
            return RunHistoryStatus(enabled ? "Enable" : "Disable", null);
        }

        internal HistorySyncStatus SetHistoryAutomaticWriteEnabled(bool enabled)
        {
            return RunHistoryStatus(enabled ? "EnableAutomatic" : "DisableAutomatic", null);
        }

        internal HistorySyncStatus SetHistoryArchivedEnabled(bool enabled)
        {
            return RunHistoryStatus(enabled ? "EnableArchived" : "DisableArchived", null);
        }

        internal HistorySyncResult SyncHistory(bool automatic)
        {
            if (!File.Exists(historySyncPath)) return HistorySyncResult.FromError("找不到历史同步组件，请重新安装 Codex Proxy。");
            string automaticArgument = automatic ? " -Automatic" : string.Empty;
            ProcessResult result = RunPowerShell("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(historySyncPath) + " -Action Sync -Json" + automaticArgument, true);
            return HistorySyncResult.FromProcess(result);
        }

        internal HistorySyncResult OpenHistoryVault()
        {
            if (!File.Exists(historySyncPath)) return HistorySyncResult.FromError("找不到历史同步组件，请重新安装 Codex Proxy。");
            ProcessResult result = RunPowerShell("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(historySyncPath) + " -Action OpenVault -Json", true);
            return HistorySyncResult.FromProcess(result);
        }

        internal HistoryVaultListResult GetHistoryVaultList()
        {
            if (!File.Exists(historySyncPath)) return HistoryVaultListResult.FromError("找不到历史同步组件，请重新安装 Codex Proxy。");
            ProcessResult result = RunPowerShell("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(historySyncPath) + " -Action List -Json", true);
            return HistoryVaultListResult.FromProcess(result);
        }

        internal HistoryProjectCatalogResult GetHistoryProjectCatalog()
        {
            return RunHistoryProjects("Projects", null);
        }

        internal HistoryProjectCatalogResult CreateHistoryProject(string codexProjectId, string localPath, string projectName)
        {
            string extra = string.IsNullOrWhiteSpace(codexProjectId) ? " -LocalPath " + Quote(localPath) : " -CodexProjectId " + Quote(codexProjectId);
            if (!string.IsNullOrWhiteSpace(projectName)) extra += " -ProjectName " + Quote(projectName);
            return RunHistoryProjects("CreateProject", extra);
        }

        internal HistoryProjectCatalogResult BindHistoryProject(string projectId, string codexProjectId, string localPath)
        {
            string extra = " -ProjectId " + Quote(projectId);
            if (!string.IsNullOrWhiteSpace(codexProjectId)) extra += " -CodexProjectId " + Quote(codexProjectId);
            else extra += " -LocalPath " + Quote(localPath);
            return RunHistoryProjects("BindProject", extra);
        }

        internal HistoryProjectCatalogResult UnbindHistoryProject(string projectId)
        {
            return RunHistoryProjects("UnbindProject", " -ProjectId " + Quote(projectId));
        }

        internal IEnumerable<string> GetCodexSessionDirectories()
        {
            string codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
            if (string.IsNullOrWhiteSpace(codexHome)) codexHome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            yield return Path.Combine(codexHome, "sessions");
            yield return Path.Combine(codexHome, "archived_sessions");
        }

        private HistorySyncStatus RunHistoryStatus(string action, string extraArguments)
        {
            if (!File.Exists(historySyncPath)) return HistorySyncStatus.FromError("找不到历史同步组件，请重新安装 Codex Proxy。");
            string arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(historySyncPath) + " -Action " + action + " -Json" + (extraArguments ?? string.Empty);
            ProcessResult result = RunPowerShell(arguments, true);
            string json = result.StandardOutput.Trim();
            if (json.Length == 0) return HistorySyncStatus.FromError(FirstUseful(result.StandardError, "历史同步组件没有返回结果。"));
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> values = serializer.Deserialize<Dictionary<string, object>>(json);
                HistorySyncStatus status = HistorySyncStatus.FromValues(values);
                if (result.ExitCode != 0) status.Success = false;
                return status;
            }
            catch (Exception ex)
            {
                return HistorySyncStatus.FromError("无法读取历史同步状态：" + ex.Message);
            }
        }

        private HistoryProjectCatalogResult RunHistoryProjects(string action, string extraArguments)
        {
            if (!File.Exists(historySyncPath)) return HistoryProjectCatalogResult.FromError("找不到历史同步组件，请重新安装 Codex Proxy。");
            string arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(historySyncPath) + " -Action " + action + " -Json" + (extraArguments ?? string.Empty);
            ProcessResult result = RunPowerShell(arguments, true);
            return HistoryProjectCatalogResult.FromProcess(result);
        }

        internal void OpenDetailedDiagnostic()
        {
            if (!File.Exists(diagnosticPath)) return;
            ProcessStartInfo info = new ProcessStartInfo(GetPowerShellPath(), "-NoLogo -NoProfile -ExecutionPolicy Bypass -File " + Quote(diagnosticPath) + " -Detailed");
            info.WorkingDirectory = root;
            info.UseShellExecute = true;
            Process.Start(info);
        }

        internal void OpenLogDirectory()
        {
            string directory = Path.GetDirectoryName(logPath);
            Directory.CreateDirectory(directory);
            Process.Start("explorer.exe", Quote(directory));
        }

        internal bool IsStartupEnabled()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunRegistryPath, false))
            {
                string current = key == null ? null : key.GetValue(RunValueName) as string;
                return string.Equals(current, StartupCommand(), StringComparison.OrdinalIgnoreCase);
            }
        }

        internal void SetStartup(bool enabled)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunRegistryPath))
            {
                if (enabled) key.SetValue(RunValueName, StartupCommand(), RegistryValueKind.String);
                else key.DeleteValue(RunValueName, false);
            }
        }

        private string StartupCommand()
        {
            return Quote(Application.ExecutablePath) + " --background";
        }

        private static bool TryReadPort(string path, out int port)
        {
            port = 0;
            if (!File.Exists(path)) return false;
            Match match = Regex.Match(File.ReadAllText(path), @"(?im)^\s*ProxyPort\s*=\s*(\d+)\s*$");
            return match.Success && int.TryParse(match.Groups[1].Value, out port) && port >= 1 && port <= 65535;
        }

        private ProcessResult RunPowerShell(string arguments, bool hidden)
        {
            ProcessStartInfo info = new ProcessStartInfo(GetPowerShellPath(), arguments);
            info.WorkingDirectory = root;
            info.UseShellExecute = false;
            info.CreateNoWindow = hidden;
            info.WindowStyle = hidden ? ProcessWindowStyle.Hidden : ProcessWindowStyle.Normal;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardOutputEncoding = Encoding.UTF8;
            info.StandardErrorEncoding = Encoding.UTF8;
            info.EnvironmentVariables["PSModulePath"] = GetWindowsPowerShellModulePath();
            Process process = null;
            try
            {
                lock (processGate)
                {
                    if (disposed) return new ProcessResult(-1, string.Empty, "Codex Proxy 正在退出，后台任务已取消。");
                    process = Process.Start(info);
                    activeProcesses.Add(process);
                }
                // Read both redirected pipes concurrently. Reading stdout to the
                // end before stderr can deadlock when PowerShell fills stderr.
                System.Threading.Tasks.Task<string> standardOutputTask = process.StandardOutput.ReadToEndAsync();
                System.Threading.Tasks.Task<string> standardErrorTask = process.StandardError.ReadToEndAsync();
                process.WaitForExit();
                System.Threading.Tasks.Task.WaitAll(standardOutputTask, standardErrorTask);
                return new ProcessResult(process.ExitCode, standardOutputTask.Result, standardErrorTask.Result);
            }
            catch (InvalidOperationException ex) { return new ProcessResult(-1, string.Empty, ex.Message); }
            catch (System.ComponentModel.Win32Exception ex) { return new ProcessResult(-1, string.Empty, ex.Message); }
            finally
            {
                if (process != null)
                {
                    lock (processGate) { activeProcesses.Remove(process); }
                    process.Dispose();
                }
            }
        }

        public void Dispose()
        {
            Process[] processes;
            lock (processGate)
            {
                if (disposed) return;
                disposed = true;
                processes = activeProcesses.ToArray();
            }
            foreach (Process process in processes)
            {
                try { if (!process.HasExited) process.Kill(); } catch { }
            }
            foreach (Process process in processes)
            {
                try { process.WaitForExit(1500); } catch { }
            }
        }

        private static string GetPowerShellPath()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
        }

        private static string GetWindowsPowerShellModulePath()
        {
            List<string> paths = new List<string>();
            AddModulePath(paths, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "Modules"));
            AddModulePath(paths, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules"));
            AddModulePath(paths, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "WindowsPowerShell", "Modules"));
            string inherited = Environment.GetEnvironmentVariable("PSModulePath");
            if (!string.IsNullOrWhiteSpace(inherited))
            {
                foreach (string candidate in inherited.Split(Path.PathSeparator))
                {
                    if (candidate.IndexOf("WindowsPowerShell", StringComparison.OrdinalIgnoreCase) >= 0) AddModulePath(paths, candidate);
                }
            }
            return string.Join(Path.PathSeparator.ToString(), paths.ToArray());
        }

        private static void AddModulePath(List<string> paths, string candidate)
        {
            if (string.IsNullOrWhiteSpace(candidate)) return;
            string normalized = candidate.Trim().TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            foreach (string existing in paths) if (string.Equals(existing, normalized, StringComparison.OrdinalIgnoreCase)) return;
            paths.Add(normalized);
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static string FirstUseful(string value, string fallback)
        {
            if (string.IsNullOrWhiteSpace(value)) return fallback;
            string[] lines = value.Trim().Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            return lines.Length == 0 ? fallback : lines[lines.Length - 1].Trim();
        }
    }

    internal sealed class DiagnosticStatus
    {
        internal bool ProxyReady;
        internal bool CodexInstalled;
        internal bool CodexRunning;
        internal bool RuntimeReadyNow;
        internal bool RuntimeReadyAfterExit;
        internal bool UpdatePending;
        internal string ProxyUrl;
        internal string ProxyProcess;
        internal string CodexVersion;
        internal string ReportedUpdateVersion;
        internal string BlockingCode;
        internal string BlockingMessage;
        internal string Remediation;
        internal DateTime CheckedAt;
        internal Color StatusColor;
        internal string Title;
        internal string TraySummary;

        internal static DiagnosticStatus FromValues(Dictionary<string, object> values, int exitCode)
        {
            DiagnosticStatus status = new DiagnosticStatus();
            status.ProxyReady = Bool(values, "ProxyReady");
            status.CodexInstalled = Bool(values, "CodexInstalled");
            status.CodexRunning = Bool(values, "CodexCurrentlyRunning");
            status.RuntimeReadyNow = Bool(values, "RuntimeReadyNow", Bool(values, "ReadyToLaunchNow"));
            status.RuntimeReadyAfterExit = Bool(values, "RuntimeReadyAfterCodexExit", Bool(values, "ReadyToLaunchAfterCodexExit"));
            status.UpdatePending = Bool(values, "AutomaticUpdatePending");
            status.ProxyUrl = Text(values, "ProxyUrl", "未配置");
            status.ProxyProcess = Text(values, "ProxyProcess", null);
            status.CodexVersion = Text(values, "CodexVersion", null);
            status.ReportedUpdateVersion = Text(values, "ReportedUpdateVersion", null);
            status.BlockingCode = Text(values, "BlockingCode", null);
            status.BlockingMessage = Text(values, "BlockingMessage", null);
            status.Remediation = Text(values, "Remediation", null);
            status.CheckedAt = DateTime.Now;

            if (status.CodexRunning && status.RuntimeReadyAfterExit)
            {
                status.Title = "Codex 正在运行";
                status.TraySummary = "运行中 · 代理监控正常";
                status.StatusColor = Color.FromArgb(16, 185, 129);
            }
            else if (status.RuntimeReadyNow)
            {
                status.Title = status.UpdatePending ? "已就绪，发现待应用更新" : "已就绪";
                status.TraySummary = status.UpdatePending ? "已就绪 · 有待应用更新" : "已就绪 · 可以启动 Codex";
                status.StatusColor = status.UpdatePending ? Color.FromArgb(245, 158, 11) : Color.FromArgb(16, 185, 129);
            }
            else
            {
                status.Title = string.IsNullOrWhiteSpace(status.BlockingMessage) ? "当前不可用" : status.BlockingMessage;
                status.TraySummary = string.IsNullOrWhiteSpace(status.BlockingCode) ? "状态异常" : "异常 · " + status.BlockingCode;
                status.StatusColor = Color.FromArgb(239, 68, 68);
            }
            return status;
        }

        internal static DiagnosticStatus FromError(string code, string message)
        {
            return new DiagnosticStatus
            {
                CheckedAt = DateTime.Now,
                BlockingCode = code,
                BlockingMessage = message,
                Title = message,
                TraySummary = "异常 · " + code,
                StatusColor = Color.FromArgb(239, 68, 68),
                ProxyUrl = "未知"
            };
        }

        internal string ProxyDescription
        {
            get
            {
                if (!ProxyReady) return "代理：未连接 · " + ProxyUrl;
                return "代理：连接正常 · " + ProxyUrl + (string.IsNullOrWhiteSpace(ProxyProcess) ? "" : " · " + ProxyProcess);
            }
        }

        internal string CodexDescription
        {
            get
            {
                if (!CodexInstalled) return "Codex：未检测到 Microsoft Store 安装";
                return "Codex：" + (CodexRunning ? "运行中" : "未运行") + (string.IsNullOrWhiteSpace(CodexVersion) ? "" : " · 版本 " + CodexVersion);
            }
        }

        internal string UpdateDescription
        {
            get
            {
                if (!UpdatePending) return "更新：当前未发现待应用版本";
                return "更新：等待应用 " + (string.IsNullOrWhiteSpace(ReportedUpdateVersion) ? "新版本" : ReportedUpdateVersion);
            }
        }

        private static bool Bool(Dictionary<string, object> values, string key)
        {
            return Bool(values, key, false);
        }

        private static bool Bool(Dictionary<string, object> values, string key, bool fallback)
        {
            object value;
            if (!values.TryGetValue(key, out value) || value == null) return fallback;
            if (value is bool) return (bool)value;
            bool parsed;
            return bool.TryParse(Convert.ToString(value), out parsed) ? parsed : fallback;
        }

        private static string Text(Dictionary<string, object> values, string key, string fallback)
        {
            object value;
            if (!values.TryGetValue(key, out value) || value == null) return fallback;
            string text = Convert.ToString(value);
            return string.IsNullOrWhiteSpace(text) ? fallback : text;
        }
    }

    internal sealed class HistorySyncStatus
    {
        internal bool Success;
        internal bool Configured;
        internal bool Enabled;
        internal bool AutomaticWriteEnabled;
        internal bool AutomaticReady;
        internal bool SyncArchived;
        internal bool Ready;
        internal bool VaultConnected;
        internal bool CodexRunning;
        internal int LocalSessionCount;
        internal int SelectedProjectCount;
        internal int SelectedLocalSessionCount;
        internal int VaultSessionCount;
        internal int SelectedVaultSessionCount;
        internal string VaultPath;
        internal string LastSyncUtc;
        internal string LastSyncOutcome;
        internal string Message;

        internal static HistorySyncStatus FromValues(Dictionary<string, object> values)
        {
            return new HistorySyncStatus
            {
                Success = Bool(values, "Success", true),
                Configured = Bool(values, "Configured", false),
                Enabled = Bool(values, "Enabled", false),
                AutomaticWriteEnabled = Bool(values, "AutomaticWriteEnabled", false),
                AutomaticReady = Bool(values, "AutomaticReady", false),
                SyncArchived = Bool(values, "SyncArchived", false),
                Ready = Bool(values, "Ready", false),
                VaultConnected = Bool(values, "VaultConnected", false),
                CodexRunning = Bool(values, "CodexRunning", false),
                LocalSessionCount = Number(values, "LocalSessionCount"),
                SelectedProjectCount = Number(values, "SelectedProjectCount"),
                SelectedLocalSessionCount = Number(values, "SelectedLocalSessionCount"),
                VaultSessionCount = Number(values, "VaultSessionCount"),
                SelectedVaultSessionCount = Number(values, "SelectedVaultSessionCount"),
                VaultPath = Text(values, "VaultPath", null),
                LastSyncUtc = Text(values, "LastSyncUtc", null),
                LastSyncOutcome = Text(values, "LastSyncOutcome", "Never"),
                Message = Text(values, "Message", "历史同步状态未知。")
            };
        }

        internal static HistorySyncStatus FromError(string message)
        {
            return new HistorySyncStatus { Success=false, Message=message, LastSyncOutcome="Failed" };
        }

        internal string TrayDescription
        {
            get
            {
                if (!Configured) return "历史同步：未配置";
                if (!Enabled) return "历史同步：已暂停";
                if (!VaultConnected) return "历史同步：仓库未连接";
                if (!AutomaticWriteEnabled) return "历史同步：手动模式";
                return "历史同步：已连接 · " + VaultSessionCount + " 个会话";
            }
        }

        private static bool Bool(Dictionary<string, object> values, string key, bool fallback)
        {
            object value;
            if (!values.TryGetValue(key, out value) || value == null) return fallback;
            if (value is bool) return (bool)value;
            bool parsed;
            return bool.TryParse(Convert.ToString(value), out parsed) ? parsed : fallback;
        }

        private static int Number(Dictionary<string, object> values, string key)
        {
            object value;
            int parsed;
            return values.TryGetValue(key, out value) && value != null && int.TryParse(Convert.ToString(value), out parsed) ? parsed : 0;
        }

        private static string Text(Dictionary<string, object> values, string key, string fallback)
        {
            object value;
            if (!values.TryGetValue(key, out value) || value == null) return fallback;
            string text = Convert.ToString(value);
            return string.IsNullOrWhiteSpace(text) ? fallback : text;
        }
    }

    internal sealed class HistorySyncResult
    {
        internal bool Success;
        internal bool LiveMode;
        internal bool AutomaticBlocked;
        internal bool ManualRequired;
        internal string Message;
        internal int Saved;
        internal int Exported;
        internal int Imported;
        internal int Updated;
        internal int Conflicts;
        internal int Skipped;
        internal int PendingImports;

        internal static HistorySyncResult FromProcess(ProcessResult process)
        {
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> values = serializer.Deserialize<Dictionary<string, object>>(process.StandardOutput.Trim());
                return new HistorySyncResult
                {
                    Success = process.ExitCode == 0 && Bool(values, "Success"),
                    LiveMode = Bool(values, "LiveMode"),
                    AutomaticBlocked = Bool(values, "AutomaticBlocked"),
                    ManualRequired = Bool(values, "ManualRequired"),
                    Message = Text(values, "Message", process.ExitCode == 0 ? "历史同步完成。" : Useful(process.StandardError, "历史同步失败。")),
                    Saved = Number(values, "Saved"), Exported = Number(values, "Exported"), Imported = Number(values, "Imported"),
                    Updated = Number(values, "Updated"), Conflicts = Number(values, "Conflicts"), Skipped = Number(values, "Skipped"),
                    PendingImports = Number(values, "PendingImports")
                };
            }
            catch
            {
                return FromError(Useful(process.StandardError, Useful(process.StandardOutput, "历史同步失败，退出码 " + process.ExitCode + "。")));
            }
        }

        internal static HistorySyncResult FromError(string message)
        {
            return new HistorySyncResult { Success=false, Message=message };
        }

        private static bool Bool(Dictionary<string, object> values, string key)
        {
            object value; bool parsed;
            if (!values.TryGetValue(key, out value) || value == null) return false;
            if (value is bool) return (bool)value;
            return bool.TryParse(Convert.ToString(value), out parsed) && parsed;
        }

        private static int Number(Dictionary<string, object> values, string key)
        {
            object value; int parsed;
            return values.TryGetValue(key, out value) && value != null && int.TryParse(Convert.ToString(value), out parsed) ? parsed : 0;
        }

        private static string Text(Dictionary<string, object> values, string key, string fallback)
        {
            object value;
            if (!values.TryGetValue(key, out value) || value == null) return fallback;
            string text = Convert.ToString(value);
            return string.IsNullOrWhiteSpace(text) ? fallback : text;
        }

        private static string Useful(string value, string fallback)
        {
            if (string.IsNullOrWhiteSpace(value)) return fallback;
            string[] lines = value.Trim().Split(new[] {'\r','\n'}, StringSplitOptions.RemoveEmptyEntries);
            return lines.Length == 0 ? fallback : lines[lines.Length - 1].Trim();
        }
    }

    internal sealed class HistoryLocalDirectory
    {
        internal string Path;
        internal string CodexProjectId;
        internal string CodexProjectName;
        internal List<string> RootPaths = new List<string>();
        internal int ActiveSessionCount;
        internal int ArchivedSessionCount;
        internal int TotalSessionCount;
        internal bool Selected;
        internal string ProjectId;
        internal string ProjectName;

        internal static HistoryLocalDirectory FromValues(Dictionary<string, object> values)
        {
            return new HistoryLocalDirectory
            {
                Path=HistoryProjectCatalogResult.Text(values,"Path",""), ActiveSessionCount=HistoryProjectCatalogResult.Number(values,"ActiveSessionCount"),
                ArchivedSessionCount=HistoryProjectCatalogResult.Number(values,"ArchivedSessionCount"), TotalSessionCount=HistoryProjectCatalogResult.Number(values,"TotalSessionCount"),
                Selected=HistoryProjectCatalogResult.Bool(values,"Selected"), ProjectId=HistoryProjectCatalogResult.Text(values,"ProjectId",""),
                ProjectName=HistoryProjectCatalogResult.Text(values,"ProjectName",""), CodexProjectId=HistoryProjectCatalogResult.Text(values,"CodexProjectId",""),
                CodexProjectName=HistoryProjectCatalogResult.Text(values,"CodexProjectName",""), RootPaths=HistoryProjectCatalogResult.StringSequence(values,"RootPaths")
            };
        }
    }

    internal sealed class HistoryProjectInfo
    {
        internal string ProjectId;
        internal string Name;
        internal bool Bound;
        internal string LocalPath;
        internal int SessionCount;
        internal string MachineNames;
        internal string SourceDirectories;
        internal string CodexProjectId;
        internal string CodexProjectIds;
        internal string CodexProjectNames;
        internal List<string> LocalRootPaths = new List<string>();
        internal DateTime UpdatedAt;

        internal static HistoryProjectInfo FromValues(Dictionary<string, object> values)
        {
            DateTime updated;
            DateTime.TryParse(HistoryProjectCatalogResult.Text(values,"UpdatedUtc",null), out updated);
            return new HistoryProjectInfo
            {
                ProjectId=HistoryProjectCatalogResult.Text(values,"ProjectId",""), Name=HistoryProjectCatalogResult.Text(values,"Name","未命名项目"),
                Bound=HistoryProjectCatalogResult.Bool(values,"Bound"), LocalPath=HistoryProjectCatalogResult.Text(values,"LocalPath",""),
                SessionCount=HistoryProjectCatalogResult.Number(values,"SessionCount"), MachineNames=HistoryProjectCatalogResult.Text(values,"MachineNames",""),
                SourceDirectories=HistoryProjectCatalogResult.Text(values,"SourceDirectories",""), UpdatedAt=updated,
                CodexProjectId=HistoryProjectCatalogResult.Text(values,"CodexProjectId",""), CodexProjectIds=HistoryProjectCatalogResult.Text(values,"CodexProjectIds",""), CodexProjectNames=HistoryProjectCatalogResult.Text(values,"CodexProjectNames",""), LocalRootPaths=HistoryProjectCatalogResult.StringSequence(values,"LocalRootPaths")
            };
        }
    }

    internal sealed class HistoryProjectCatalogResult
    {
        internal bool Success;
        internal string Message;
        internal string VaultPath;
        internal int BoundProjectCount;
        internal int CodexProjectCount;
        internal List<HistoryLocalDirectory> LocalDirectories = new List<HistoryLocalDirectory>();
        internal List<HistoryProjectInfo> Projects = new List<HistoryProjectInfo>();

        internal static HistoryProjectCatalogResult FromProcess(ProcessResult process)
        {
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> values = serializer.Deserialize<Dictionary<string, object>>(process.StandardOutput.Trim());
                HistoryProjectCatalogResult result = new HistoryProjectCatalogResult();
                result.Success = process.ExitCode == 0 && Bool(values, "Success");
                result.Message = Text(values, "Message", result.Success ? "已读取同步项目。" : "读取同步项目失败。");
                result.VaultPath = Text(values, "VaultPath", null);
                result.BoundProjectCount = Number(values, "BoundProjectCount");
                result.CodexProjectCount = Number(values, "CodexProjectCount");
                AddSequence(values, "LocalDirectories", delegate(Dictionary<string, object> item) { result.LocalDirectories.Add(HistoryLocalDirectory.FromValues(item)); });
                if (result.LocalDirectories.Count == 0) AddSequence(values, "LocalProjects", delegate(Dictionary<string, object> item) { result.LocalDirectories.Add(HistoryLocalDirectory.FromValues(item)); });
                AddSequence(values, "Projects", delegate(Dictionary<string, object> item) { result.Projects.Add(HistoryProjectInfo.FromValues(item)); });
                return result;
            }
            catch (Exception ex) { return FromError("无法读取同步项目：" + ex.Message); }
        }

        internal static HistoryProjectCatalogResult FromError(string message) { return new HistoryProjectCatalogResult { Success=false, Message=message }; }

        private static void AddSequence(Dictionary<string, object> values, string key, Action<Dictionary<string, object>> add)
        {
            object raw;
            if (!values.TryGetValue(key, out raw) || raw == null) return;
            System.Collections.IEnumerable sequence = raw as System.Collections.IEnumerable;
            if (sequence == null) return;
            foreach (object item in sequence)
            {
                Dictionary<string, object> entry = item as Dictionary<string, object>;
                if (entry != null) add(entry);
            }
        }

        internal static bool Bool(Dictionary<string, object> values, string key) { object value; bool parsed; return values.TryGetValue(key,out value) && value != null && (value is bool ? (bool)value : bool.TryParse(Convert.ToString(value),out parsed) && parsed); }
        internal static int Number(Dictionary<string, object> values, string key) { object value; int parsed; return values.TryGetValue(key,out value) && value != null && int.TryParse(Convert.ToString(value),out parsed) ? parsed : 0; }
        internal static string Text(Dictionary<string, object> values, string key, string fallback) { object value; if (!values.TryGetValue(key,out value) || value == null) return fallback; string text=Convert.ToString(value); return string.IsNullOrWhiteSpace(text) ? fallback : text; }
        internal static List<string> StringSequence(Dictionary<string, object> values, string key)
        {
            List<string> result = new List<string>(); object raw;
            if (!values.TryGetValue(key, out raw) || raw == null || raw is string) return result;
            System.Collections.IEnumerable sequence = raw as System.Collections.IEnumerable;
            if (sequence == null) return result;
            foreach (object item in sequence) { if (item != null && !string.IsNullOrWhiteSpace(Convert.ToString(item))) result.Add(Convert.ToString(item)); }
            return result;
        }
    }

    internal sealed class HistoryVaultEntry
    {
        internal string ThreadId;
        internal string Title;
        internal DateTime UpdatedAt;
        internal string MachineNames;
        internal bool Archived;
        internal string ModelProvider;
        internal string WorkingDirectory;
        internal string LocalWorkingDirectory;
        internal string ProjectId;
        internal string ProjectName;
        internal string CodexProjectId;
        internal string CodexProjectName;
        internal int ProjectRootIndex;
        internal string ProjectRootPath;
        internal string ContentHash;
        internal long ContentLength;
        internal bool IsConflict;
        internal int ReplicaCount;

        internal static HistoryVaultEntry FromValues(Dictionary<string, object> values)
        {
            DateTime updated;
            DateTime.TryParse(Text(values, "UpdatedUtc", null), out updated);
            return new HistoryVaultEntry
            {
                ThreadId=Text(values,"ThreadId",""), Title=Text(values,"Title","未命名会话"), UpdatedAt=updated,
                MachineNames=Text(values,"MachineNames","未知电脑"), Archived=Bool(values,"Archived"),
                ModelProvider=Text(values,"ModelProvider",""), WorkingDirectory=Text(values,"WorkingDirectory",""), LocalWorkingDirectory=Text(values,"LocalWorkingDirectory",""),
                ProjectId=Text(values,"ProjectId",""), ProjectName=Text(values,"ProjectName",""), ContentHash=Text(values,"ContentHash",""),
                CodexProjectId=Text(values,"CodexProjectId",""), CodexProjectName=Text(values,"CodexProjectName",""), ProjectRootIndex=Number(values,"ProjectRootIndex"), ProjectRootPath=Text(values,"ProjectRootPath",""),
                ContentLength=LongNumber(values,"ContentLength"), IsConflict=Bool(values,"IsConflict"), ReplicaCount=Number(values,"ReplicaCount")
            };
        }

        private static bool Bool(Dictionary<string, object> values, string key) { object value; bool parsed; return values.TryGetValue(key,out value) && value != null && (value is bool ? (bool)value : bool.TryParse(Convert.ToString(value),out parsed) && parsed); }
        private static int Number(Dictionary<string, object> values, string key) { object value; int parsed; return values.TryGetValue(key,out value) && value != null && int.TryParse(Convert.ToString(value),out parsed) ? parsed : 0; }
        private static long LongNumber(Dictionary<string, object> values, string key) { object value; long parsed; return values.TryGetValue(key,out value) && value != null && long.TryParse(Convert.ToString(value),out parsed) ? parsed : 0; }
        private static string Text(Dictionary<string, object> values, string key, string fallback) { object value; if (!values.TryGetValue(key,out value) || value == null) return fallback; string text=Convert.ToString(value); return string.IsNullOrWhiteSpace(text) ? fallback : text; }
    }

    internal sealed class HistoryVaultListResult
    {
        internal bool Success;
        internal string Message;
        internal string VaultPath;
        internal List<HistoryVaultEntry> Entries = new List<HistoryVaultEntry>();

        internal static HistoryVaultListResult FromProcess(ProcessResult process)
        {
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> values = serializer.Deserialize<Dictionary<string, object>>(process.StandardOutput.Trim());
                HistoryVaultListResult result = new HistoryVaultListResult();
                result.Success = process.ExitCode == 0 && GetBool(values, "Success");
                result.Message = GetText(values, "Message", result.Success ? "已读取历史仓库。" : "读取历史仓库失败。");
                result.VaultPath = GetText(values, "VaultPath", null);
                object rawEntries;
                if (values.TryGetValue("Entries", out rawEntries) && rawEntries != null)
                {
                    System.Collections.IEnumerable sequence = rawEntries as System.Collections.IEnumerable;
                    if (sequence != null)
                    {
                        foreach (object item in sequence)
                        {
                            Dictionary<string, object> entryValues = item as Dictionary<string, object>;
                            if (entryValues != null) result.Entries.Add(HistoryVaultEntry.FromValues(entryValues));
                        }
                    }
                }
                return result;
            }
            catch (Exception ex) { return FromError("无法读取会话列表：" + ex.Message); }
        }

        internal static HistoryVaultListResult FromError(string message) { return new HistoryVaultListResult { Success=false, Message=message }; }
        private static bool GetBool(Dictionary<string, object> values,string key) { object value; bool parsed; return values.TryGetValue(key,out value) && value != null && (value is bool ? (bool)value : bool.TryParse(Convert.ToString(value),out parsed) && parsed); }
        private static string GetText(Dictionary<string, object> values,string key,string fallback) { object value; if(!values.TryGetValue(key,out value)||value==null)return fallback; string text=Convert.ToString(value); return string.IsNullOrWhiteSpace(text)?fallback:text; }
    }

#if LEGACY_UI
    internal sealed class MainWindow : Form
    {
        private readonly Action<int> savePort;
        private readonly Action launch;
        private readonly Action refresh;
        private readonly Action openLogs;
        private readonly Action<bool> setStartup;
        private readonly Action configureHistory;
        private readonly Action syncHistory;
        private readonly Action<bool> setHistoryEnabled;
        private readonly Action openHistory;
        private readonly Label statusDot;
        private readonly Label statusTitle;
        private readonly Label proxyStatus;
        private readonly Label codexStatus;
        private readonly Label updateStatus;
        private readonly Label checkedAt;
        private readonly Label actionMessage;
        private readonly NumericUpDown portInput;
        private readonly CheckBox startupCheck;
        private readonly CheckBox historyEnabledCheck;
        private readonly Label historyStatus;
        private readonly Label historyPath;
        private readonly Label historyCounts;
        private readonly Button historySyncButton;
        private readonly Button launchButton;
        internal bool AllowExit;
        internal event EventHandler ExitRequested;

        internal MainWindow(int initialPort, Action<int> savePortAction, Action launchAction, Action refreshAction, Action openLogsAction, Action<bool> startupAction,
            Action configureHistoryAction, Action syncHistoryAction, Action<bool> historyEnabledAction, Action openHistoryAction)
        {
            savePort = savePortAction;
            launch = launchAction;
            refresh = refreshAction;
            openLogs = openLogsAction;
            setStartup = startupAction;
            configureHistory = configureHistoryAction;
            syncHistory = syncHistoryAction;
            setHistoryEnabled = historyEnabledAction;
            openHistory = openHistoryAction;

            Text = "Codex Proxy";
            ClientSize = new Size(720, 668);
            MinimumSize = new Size(736, 707);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            BackColor = Color.FromArgb(241, 245, 249);
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            AutoScaleMode = AutoScaleMode.Dpi;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            Panel header = new Panel { Dock = DockStyle.Top, Height = 84, BackColor = Color.FromArgb(15, 23, 42) };
            Controls.Add(header);
            header.Controls.Add(NewLabel("Codex Proxy", 24, 11, 280, 34, 21F, FontStyle.Bold, Color.White));
            header.Controls.Add(NewLabel("本地网络代理、后台监控与跨电脑历史同步", 26, 48, 520, 24, 9.5F, FontStyle.Regular, Color.FromArgb(148, 163, 184)));
            Label version = NewLabel("v3.2.1", 622, 21, 70, 24, 9F, FontStyle.Bold, Color.FromArgb(147, 197, 253));
            version.TextAlign = ContentAlignment.MiddleRight;
            header.Controls.Add(version);

            Panel statusCard = Card(24, 100, 672, 150);
            Controls.Add(statusCard);
            statusDot = NewLabel("●", 22, 18, 28, 32, 21F, FontStyle.Regular, Color.FromArgb(100, 116, 139));
            statusTitle = NewLabel("正在检查运行状态…", 56, 19, 580, 30, 15F, FontStyle.Bold, Color.FromArgb(15, 23, 42));
            proxyStatus = NewLabel("代理：正在检查", 58, 61, 580, 22, 9.5F, FontStyle.Regular, Color.FromArgb(71, 85, 105));
            codexStatus = NewLabel("Codex：正在检查", 58, 88, 580, 22, 9.5F, FontStyle.Regular, Color.FromArgb(71, 85, 105));
            updateStatus = NewLabel("更新：正在检查", 58, 115, 440, 22, 9.5F, FontStyle.Regular, Color.FromArgb(71, 85, 105));
            checkedAt = NewLabel("", 500, 115, 138, 22, 8.5F, FontStyle.Regular, Color.FromArgb(148, 163, 184));
            checkedAt.TextAlign = ContentAlignment.MiddleRight;
            statusCard.Controls.AddRange(new Control[] { statusDot, statusTitle, proxyStatus, codexStatus, updateStatus, checkedAt });

            Panel settingsCard = Card(24, 264, 672, 104);
            Controls.Add(settingsCard);
            settingsCard.Controls.Add(NewLabel("网络代理", 22, 15, 150, 25, 11F, FontStyle.Bold, Color.FromArgb(15, 23, 42)));
            settingsCard.Controls.Add(NewLabel("本机 HTTP / Mixed 代理端口", 22, 48, 235, 28, 9F, FontStyle.Regular, Color.FromArgb(71, 85, 105)));
            portInput = new NumericUpDown
            {
                Location = new Point(263, 45), Size = new Size(108, 30), Minimum = 1, Maximum = 65535,
                Value = Math.Max(1, Math.Min(65535, initialPort)), Font = new Font("Segoe UI", 10F), ThousandsSeparator = false
            };
            settingsCard.Controls.Add(portInput);
            Button saveButton = PrimaryButton("保存端口", 383, 43, 102, 34);
            saveButton.Click += delegate { savePort(Convert.ToInt32(portInput.Value)); };
            settingsCard.Controls.Add(saveButton);
            startupCheck = new CheckBox
            {
                Text = "登录 Windows 后在后台自动运行", AutoSize = true, Location = new Point(22, 82),
                ForeColor = Color.FromArgb(71, 85, 105), BackColor = Color.White
            };
            startupCheck.CheckedChanged += delegate { if (startupCheck.Focused) setStartup(startupCheck.Checked); };
            settingsCard.Controls.Add(startupCheck);

            Panel historyCard = Card(24, 382, 672, 150);
            Controls.Add(historyCard);
            historyCard.Controls.Add(NewLabel("跨电脑历史同步", 22, 14, 220, 26, 11F, FontStyle.Bold, Color.FromArgb(15, 23, 42)));
            Button chooseHistoryButton = SecondaryButton("选择历史仓库", 472, 12, 166, 34);
            chooseHistoryButton.Click += delegate { configureHistory(); };
            historyCard.Controls.Add(chooseHistoryButton);
            historyStatus = NewLabel("尚未配置历史仓库", 22, 45, 430, 23, 9.5F, FontStyle.Regular, Color.FromArgb(71, 85, 105));
            historyPath = NewLabel("移动硬盘：未选择", 22, 72, 616, 22, 8.8F, FontStyle.Regular, Color.FromArgb(100, 116, 139));
            historyCounts = NewLabel("本机 0 个会话 · 仓库 0 个会话", 22, 94, 420, 22, 8.8F, FontStyle.Regular, Color.FromArgb(100, 116, 139));
            historyCard.Controls.AddRange(new Control[] { historyStatus, historyPath, historyCounts });
            historyEnabledCheck = new CheckBox
            {
                Text = "实时保存；退出后安全合并", AutoSize = true, Location = new Point(22, 120),
                ForeColor = Color.FromArgb(71, 85, 105), BackColor = Color.White
            };
            historyEnabledCheck.CheckedChanged += delegate { if (historyEnabledCheck.Focused) setHistoryEnabled(historyEnabledCheck.Checked); };
            historyCard.Controls.Add(historyEnabledCheck);
            historySyncButton = PrimaryButton("立即同步", 472, 108, 82, 32);
            historySyncButton.Click += delegate { syncHistory(); };
            historyCard.Controls.Add(historySyncButton);
            Button openHistoryButton = SecondaryButton("会话列表", 562, 108, 76, 32);
            openHistoryButton.Click += delegate { openHistory(); };
            historyCard.Controls.Add(openHistoryButton);

            launchButton = PrimaryButton("通过代理启动 Codex", 24, 548, 230, 42);
            launchButton.Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold);
            launchButton.Click += delegate { launch(); };
            Controls.Add(launchButton);
            Button refreshButton = SecondaryButton("立即刷新", 266, 548, 126, 42);
            refreshButton.Click += delegate { refresh(); };
            Controls.Add(refreshButton);
            Button logsButton = SecondaryButton("打开日志", 404, 548, 126, 42);
            logsButton.Click += delegate { openLogs(); };
            Controls.Add(logsButton);
            Button exitButton = SecondaryButton("退出监控", 542, 548, 154, 42);
            exitButton.Click += delegate { if (ExitRequested != null) ExitRequested(this, EventArgs.Empty); };
            Controls.Add(exitButton);

            actionMessage = NewLabel("关闭窗口后程序仍会在右下角托盘监控状态。", 26, 604, 668, 25, 8.5F, FontStyle.Regular, Color.FromArgb(100, 116, 139));
            Controls.Add(actionMessage);
            Label footer = NewLabel("历史同步不复制认证文件、插件、日志或正在运行的数据库", 26, 636, 668, 22, 8F, FontStyle.Regular, Color.FromArgb(148, 163, 184));
            Controls.Add(footer);
        }

        internal bool StartupEnabled
        {
            get { return startupCheck.Checked; }
            set { startupCheck.Checked = value; }
        }

        internal void SetChecking()
        {
            statusDot.ForeColor = Color.FromArgb(100, 116, 139);
            statusTitle.Text = "正在检查运行状态…";
            checkedAt.Text = "";
        }

        internal void SetLaunching()
        {
            statusDot.ForeColor = Color.FromArgb(37, 99, 235);
            statusTitle.Text = "正在通过代理启动 Codex…";
            launchButton.Enabled = false;
            actionMessage.Text = "正在验证代理、官方应用和 helper 缓存，请稍候。";
            actionMessage.ForeColor = Color.FromArgb(37, 99, 235);
        }

        internal void ApplyStatus(DiagnosticStatus status)
        {
            statusDot.ForeColor = status.StatusColor;
            statusTitle.Text = status.Title;
            proxyStatus.Text = status.ProxyDescription;
            codexStatus.Text = status.CodexDescription;
            updateStatus.Text = status.UpdateDescription;
            checkedAt.Text = status.CheckedAt.ToString("HH:mm:ss") + " 更新";
            launchButton.Enabled = status.RuntimeReadyNow;
            if (!string.IsNullOrWhiteSpace(status.BlockingMessage) && !status.CodexRunning)
            {
                actionMessage.Text = string.IsNullOrWhiteSpace(status.Remediation) ? status.BlockingMessage : status.Remediation;
                actionMessage.ForeColor = Color.FromArgb(185, 28, 28);
            }
            else
            {
                actionMessage.Text = "关闭窗口后程序仍会在右下角托盘监控状态。";
                actionMessage.ForeColor = Color.FromArgb(100, 116, 139);
            }
        }

        internal void ApplyHistoryStatus(HistorySyncStatus status)
        {
            historyEnabledCheck.Checked = status.Enabled;
            historySyncButton.Enabled = status.Ready;
            if (!status.Configured)
            {
                historyStatus.Text = "尚未配置历史仓库";
                historyStatus.ForeColor = Color.FromArgb(100, 116, 139);
                historyPath.Text = "移动硬盘：未选择";
            }
            else if (!status.Enabled)
            {
                historyStatus.Text = "历史同步已暂停";
                historyStatus.ForeColor = Color.FromArgb(217, 119, 6);
                historyPath.Text = "仓库：" + (string.IsNullOrWhiteSpace(status.VaultPath) ? "当前未连接" : status.VaultPath);
            }
            else if (!status.VaultConnected)
            {
                historyStatus.Text = "历史仓库未连接";
                historyStatus.ForeColor = Color.FromArgb(220, 38, 38);
                historyPath.Text = "请连接移动硬盘；盘符改变后会自动重新发现";
            }
            else
            {
                historyStatus.Text = status.CodexRunning ? "仓库已连接 · 正在实时保存本机会话" : "仓库已连接 · 可以执行完整双向同步";
                historyStatus.ForeColor = Color.FromArgb(5, 150, 105);
                historyPath.Text = "仓库：" + status.VaultPath;
            }
            historyCounts.Text = "本机 " + status.LocalSessionCount + " 个会话 · 仓库 " + status.VaultSessionCount + " 个会话" + LastSyncSuffix(status);
        }

        internal void SetHistoryWorking(string message)
        {
            historyStatus.Text = message;
            historyStatus.ForeColor = Color.FromArgb(37, 99, 235);
            historySyncButton.Enabled = false;
        }

        private static string LastSyncSuffix(HistorySyncStatus status)
        {
            if (string.IsNullOrWhiteSpace(status.LastSyncUtc)) return " · 尚未同步";
            DateTime parsed;
            string time = DateTime.TryParse(status.LastSyncUtc, out parsed) ? parsed.ToLocalTime().ToString("MM-dd HH:mm") : status.LastSyncUtc;
            bool successful = string.Equals(status.LastSyncOutcome, "Succeeded", StringComparison.OrdinalIgnoreCase) || string.Equals(status.LastSyncOutcome, "LiveSnapshot", StringComparison.OrdinalIgnoreCase);
            return " · 上次 " + time + (successful ? " 成功" : " 失败");
        }

        internal void ShowActionSuccess(string message)
        {
            actionMessage.Text = message;
            actionMessage.ForeColor = Color.FromArgb(5, 150, 105);
        }

        internal void ShowActionError(string message)
        {
            actionMessage.Text = message;
            actionMessage.ForeColor = Color.FromArgb(185, 28, 28);
        }

        private static Panel Card(int x, int y, int width, int height)
        {
            return new Panel { Location = new Point(x, y), Size = new Size(width, height), BackColor = Color.White, BorderStyle = BorderStyle.FixedSingle };
        }

        private static Label NewLabel(string text, int x, int y, int width, int height, float size, FontStyle style, Color color)
        {
            return new Label
            {
                Text = text, Location = new Point(x, y), Size = new Size(width, height),
                Font = new Font("Microsoft YaHei UI", size, style, GraphicsUnit.Point), ForeColor = color,
                BackColor = Color.Transparent, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft
            };
        }

        private static Button PrimaryButton(string text, int x, int y, int width, int height)
        {
            Button button = new Button
            {
                Text = text, Location = new Point(x, y), Size = new Size(width, height), FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(37, 99, 235), ForeColor = Color.White, Cursor = Cursors.Hand,
                Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold)
            };
            button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.MouseOverBackColor = Color.FromArgb(29, 78, 216);
            return button;
        }

        private static Button SecondaryButton(string text, int x, int y, int width, int height)
        {
            Button button = new Button
            {
                Text = text, Location = new Point(x, y), Size = new Size(width, height), FlatStyle = FlatStyle.Flat,
                BackColor = Color.White, ForeColor = Color.FromArgb(30, 41, 59), Cursor = Cursors.Hand,
                Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold)
            };
            button.FlatAppearance.BorderColor = Color.FromArgb(203, 213, 225);
            button.FlatAppearance.MouseOverBackColor = Color.FromArgb(248, 250, 252);
            return button;
        }
    }

    internal sealed class HistoryBrowserWindow : Form
    {
        private readonly Action refreshAction;
        private readonly Action openVaultAction;
        private readonly TextBox searchBox;
        private readonly ListView list;
        private readonly Label summaryLabel;
        private readonly Label pathLabel;
        private readonly List<HistoryVaultEntry> allEntries = new List<HistoryVaultEntry>();

        internal HistoryBrowserWindow(Action refresh, Action openVault)
        {
            refreshAction = refresh;
            openVaultAction = openVault;
            Text = "已保存的 Codex 历史会话";
            ClientSize = new Size(980, 590);
            MinimumSize = new Size(820, 500);
            StartPosition = FormStartPosition.CenterParent;
            BackColor = Color.FromArgb(241,245,249);
            Font = new Font("Microsoft YaHei UI", 9F);
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            Panel header = new Panel { Dock=DockStyle.Top, Height=82, BackColor=Color.FromArgb(15,23,42) };
            Controls.Add(header);
            header.Controls.Add(NewLabel("已保存的历史会话", 22, 10, 390, 32, 18F, FontStyle.Bold, Color.White));
            header.Controls.Add(NewLabel("这里显示移动历史仓库中的会话版本；列表读取不会修改 Codex。", 24, 44, 620, 22, 9F, FontStyle.Regular, Color.FromArgb(148,163,184)));

            searchBox = new TextBox { Location=new Point(20,98), Size=new Size(360,30), Font=new Font("Microsoft YaHei UI",10F) };
            searchBox.TextChanged += delegate { RebuildList(); };
            Controls.Add(searchBox);
            Label searchHint = NewLabel("搜索标题、电脑或会话 ID", 390, 100, 250, 26, 8.5F, FontStyle.Regular, Color.FromArgb(100,116,139));
            Controls.Add(searchHint);

            list = new ListView
            {
                Location=new Point(20,140), Size=new Size(940,360), Anchor=AnchorStyles.Top|AnchorStyles.Bottom|AnchorStyles.Left|AnchorStyles.Right,
                View=View.Details, FullRowSelect=true, GridLines=false, HideSelection=false, MultiSelect=false,
                BackColor=Color.White, ForeColor=Color.FromArgb(30,41,59), Font=new Font("Microsoft YaHei UI",9F)
            };
            list.Columns.Add("会话标题", 290);
            list.Columns.Add("最后更新时间", 135);
            list.Columns.Add("来源电脑", 130);
            list.Columns.Add("状态", 90);
            list.Columns.Add("提供商", 90);
            list.Columns.Add("大小", 75);
            list.Columns.Add("会话 ID", 245);
            list.DoubleClick += delegate { CopySelectedId(); };
            Controls.Add(list);

            summaryLabel = NewLabel("正在读取历史仓库…", 22, 512, 500, 24, 9F, FontStyle.Regular, Color.FromArgb(71,85,105));
            summaryLabel.Anchor = AnchorStyles.Bottom|AnchorStyles.Left;
            Controls.Add(summaryLabel);
            pathLabel = NewLabel("", 22, 540, 640, 24, 8F, FontStyle.Regular, Color.FromArgb(100,116,139));
            pathLabel.Anchor = AnchorStyles.Bottom|AnchorStyles.Left|AnchorStyles.Right;
            Controls.Add(pathLabel);

            Button refreshButton = ButtonStyle("刷新列表", 675, 518, 90, 36, true);
            refreshButton.Anchor = AnchorStyles.Bottom|AnchorStyles.Right;
            refreshButton.Click += delegate { refreshAction(); };
            Controls.Add(refreshButton);
            Button copyButton = ButtonStyle("复制会话 ID", 775, 518, 100, 36, false);
            copyButton.Anchor = AnchorStyles.Bottom|AnchorStyles.Right;
            copyButton.Click += delegate { CopySelectedId(); };
            Controls.Add(copyButton);
            Button openButton = ButtonStyle("打开仓库", 885, 518, 75, 36, false);
            openButton.Anchor = AnchorStyles.Bottom|AnchorStyles.Right;
            openButton.Click += delegate { openVaultAction(); };
            Controls.Add(openButton);
        }

        internal void SetLoading()
        {
            summaryLabel.Text = "正在读取历史仓库…";
            summaryLabel.ForeColor = Color.FromArgb(37,99,235);
        }

        internal void ApplyResult(HistoryVaultListResult result)
        {
            allEntries.Clear();
            if (result.Success) allEntries.AddRange(result.Entries);
            pathLabel.Text = string.IsNullOrWhiteSpace(result.VaultPath) ? "" : "仓库：" + result.VaultPath;
            if (!result.Success)
            {
                list.Items.Clear();
                summaryLabel.Text = result.Message;
                summaryLabel.ForeColor = Color.FromArgb(185,28,28);
                return;
            }
            summaryLabel.ForeColor = Color.FromArgb(71,85,105);
            RebuildList();
        }

        private void RebuildList()
        {
            string query = searchBox.Text.Trim();
            list.BeginUpdate();
            try
            {
                list.Items.Clear();
                foreach (HistoryVaultEntry entry in allEntries)
                {
                    string haystack = entry.Title + " " + entry.MachineNames + " " + entry.ThreadId + " " + entry.ModelProvider;
                    if (query.Length > 0 && haystack.IndexOf(query, StringComparison.OrdinalIgnoreCase) < 0) continue;
                    string updated = entry.UpdatedAt == DateTime.MinValue ? "未知" : entry.UpdatedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss");
                    string state = entry.IsConflict ? "冲突副本" : (entry.Archived ? "已归档" : "正常");
                    ListViewItem item = new ListViewItem(entry.Title);
                    item.SubItems.Add(updated);
                    item.SubItems.Add(entry.MachineNames);
                    item.SubItems.Add(state);
                    item.SubItems.Add(entry.ModelProvider);
                    item.SubItems.Add(FormatBytes(entry.ContentLength));
                    item.SubItems.Add(entry.ThreadId);
                    item.Tag = entry;
                    if (entry.IsConflict) item.ForeColor = Color.FromArgb(180,83,9);
                    list.Items.Add(item);
                }
                summaryLabel.Text = "共保存 " + allEntries.Count + " 个会话版本 · 当前显示 " + list.Items.Count + " 个 · 双击可复制会话 ID";
            }
            finally { list.EndUpdate(); }
        }

        private void CopySelectedId()
        {
            if (list.SelectedItems.Count == 0) return;
            HistoryVaultEntry entry = list.SelectedItems[0].Tag as HistoryVaultEntry;
            if (entry == null || string.IsNullOrWhiteSpace(entry.ThreadId)) return;
            try { Clipboard.SetText(entry.ThreadId); summaryLabel.Text = "已复制会话 ID：" + entry.ThreadId; } catch { }
        }

        private static string FormatBytes(long bytes)
        {
            if (bytes >= 1024L*1024L) return (bytes/(1024D*1024D)).ToString("0.0") + " MB";
            if (bytes >= 1024L) return (bytes/1024D).ToString("0.0") + " KB";
            return bytes + " B";
        }

        private static Label NewLabel(string text,int x,int y,int width,int height,float size,FontStyle style,Color color)
        {
            return new Label { Text=text,Location=new Point(x,y),Size=new Size(width,height),Font=new Font("Microsoft YaHei UI",size,style),ForeColor=color,BackColor=Color.Transparent,AutoEllipsis=true,TextAlign=ContentAlignment.MiddleLeft };
        }

        private static Button ButtonStyle(string text,int x,int y,int width,int height,bool primary)
        {
            Button button = new Button { Text=text,Location=new Point(x,y),Size=new Size(width,height),FlatStyle=FlatStyle.Flat,Cursor=Cursors.Hand,Font=new Font("Microsoft YaHei UI",8.5F,FontStyle.Bold),BackColor=primary?Color.FromArgb(37,99,235):Color.White,ForeColor=primary?Color.White:Color.FromArgb(30,41,59) };
            button.FlatAppearance.BorderColor = primary ? Color.FromArgb(37,99,235) : Color.FromArgb(203,213,225);
            return button;
        }
    }
#endif

    internal sealed class ProcessResult
    {
        internal readonly int ExitCode;
        internal readonly string StandardOutput;
        internal readonly string StandardError;
        internal ProcessResult(int exitCode, string standardOutput, string standardError)
        {
            ExitCode = exitCode;
            StandardOutput = standardOutput ?? string.Empty;
            StandardError = standardError ?? string.Empty;
        }
    }

    internal sealed class LaunchResult
    {
        internal readonly bool Success;
        internal readonly string Message;
        internal LaunchResult(bool success, string message) { Success = success; Message = message; }
    }

    internal static class NativeMethods
    {
        [DllImport("user32.dll")]
        internal static extern bool SetProcessDPIAware();

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        internal static extern bool DestroyIcon(IntPtr handle);
    }
}
