using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Data;
using System.Windows.Input;

namespace CodexProxyDesktop
{
    internal sealed class WorkspaceViewModel : Observable, IDisposable
    {
        private readonly IRuntimeBridge runtime;
        private readonly PreferencesStore preferencesStore;
        private DesktopPreferences preferences;
        private DiagnosticStatus status;
        private readonly string logDirectory;
        private bool refreshing, launching, saving, loadingLogs, startup, disposed;
        private bool hasChecked;
        private string portText, selectedPage = "overview", search = "", level = "全部";
        private string toast = "", toastKind = "info", logError = "";
        private double checkSeconds;
        private int savedPort;
        private ApplicationCatalog catalog;
        private ApplicationProfile selectedApplication;
        internal event Action<ApplicationProfile> EditApplicationRequested;
        internal event EventHandler AppearanceChanged;
        internal event EventHandler ToastChanged;
        internal event EventHandler ExitRequested;

        internal WorkspaceViewModel(IRuntimeBridge bridge, PreferencesStore store, string logs)
        {
            runtime = bridge;
            preferencesStore = store;
            preferences = store.Load();
            logDirectory = logs;
            savedPort = bridge.ReadSavedPort();
            portText = savedPort.ToString(CultureInfo.InvariantCulture);
            try { startup = bridge.IsStartupEnabled(); } catch (Exception ex) { ShowToast("开机启动状态读取失败：" + ex.Message, "error"); }
            status = DiagnosticStatus.FromError("CHECKING", "正在检查运行环境");
            catalog = bridge.LoadApplications();
            Applications = new ObservableCollection<ApplicationProfile>(catalog.Applications);
            selectedApplication = Applications.FirstOrDefault(app => app.Id == catalog.SelectedId) ?? Applications[0];
            Logs = new ObservableCollection<LogEntry>();
            LogsView = CollectionViewSource.GetDefaultView(Logs);
            LogsView.Filter = FilterLog;
            NavigateCommand = new ActionCommand(value => Navigate(Convert.ToString(value)));
            RefreshCommand = new AsyncCommand(() => RefreshAsync(false), () => !IsWorking, Error);
            FullCheckCommand = new AsyncCommand(() => RefreshAsync(true), () => !IsWorking, Error);
            LaunchCommand = new AsyncCommand(LaunchAsync, () => CanLaunch, Error);
            SavePortCommand = new AsyncCommand(SavePortAsync, () => !IsWorking && PortError.Length == 0 && PortDirty, Error);
            ReloadLogsCommand = new AsyncCommand(LoadLogsAsync, () => !loadingLogs, Error);
            OpenLogsCommand = new ActionCommand(value => { try { runtime.OpenLogDirectory(); } catch (Exception ex) { Error(ex); } });
            ThemeCommand = new ActionCommand(value => SetTheme(Convert.ToString(value)));
            CollapseCommand = new ActionCommand(value => SidebarCollapsed = !SidebarCollapsed);
            DismissToastCommand = new ActionCommand(value => DismissToast());
            ExitCommand = new ActionCommand(value => { if (ExitRequested != null) ExitRequested(this, EventArgs.Empty); });
            AddApplicationCommand = new ActionCommand(value => { if (EditApplicationRequested != null) EditApplicationRequested(null); }, value => !IsWorking);
            EditApplicationCommand = new ActionCommand(value => { if (EditApplicationRequested != null) EditApplicationRequested(value as ApplicationProfile ?? selectedApplication); }, value => !IsWorking);
            SelectApplicationCommand = new ActionCommand(value => { SelectedApplication = value as ApplicationProfile; Navigate("overview"); }, value => !IsWorking && value is ApplicationProfile);
            if (!string.IsNullOrWhiteSpace(store.ReadWarning)) ShowToast(store.ReadWarning, "error");
            if (!string.IsNullOrWhiteSpace(bridge.ApplicationWarning)) ShowToast(bridge.ApplicationWarning, "error");
        }

        public ICommand NavigateCommand { get; private set; }
        public ICommand RefreshCommand { get; private set; }
        public ICommand FullCheckCommand { get; private set; }
        public ICommand LaunchCommand { get; private set; }
        public ICommand SavePortCommand { get; private set; }
        public ICommand ReloadLogsCommand { get; private set; }
        public ICommand OpenLogsCommand { get; private set; }
        public ICommand ThemeCommand { get; private set; }
        public ICommand CollapseCommand { get; private set; }
        public ICommand DismissToastCommand { get; private set; }
        public ICommand ExitCommand { get; private set; }
        public ICommand AddApplicationCommand { get; private set; }
        public ICommand EditApplicationCommand { get; private set; }
        public ICommand SelectApplicationCommand { get; private set; }
        public ObservableCollection<ApplicationProfile> Applications { get; private set; }
        public ApplicationProfile SelectedApplication
        {
            get { return selectedApplication; }
            set
            {
                if (value == null || selectedApplication == value) return;
                if (IsWorking || !Applications.Contains(value)) { Changed("SelectedApplication"); return; }
                ApplicationCatalog next = catalog.Copy(); next.SelectedId = value.Id;
                try { runtime.SaveApplications(next); catalog = next; selectedApplication = value; ResetApplicationStatus(); RefreshCommand.Execute(null); }
                catch (Exception ex) { Changed("SelectedApplication"); Error(ex); }
            }
        }
        public bool CanChangeApplication { get { return !IsWorking; } }
        public string ApplicationName { get { return selectedApplication.Name; } }
        internal int DefaultProxyPort { get { return savedPort; } }
        public bool IsCodex { get { return selectedApplication.IsCodex; } }
        public string ApplicationCaption { get { return "通过本地代理连接 " + ApplicationName + "。"; } }
        public string ApplicationCount { get { return Applications.Count + " 个应用 · 选择、配置，然后启动"; } }
        public string ApplicationRoute { get { return selectedApplication.ProxyPort == 0 ? "默认代理" : "独立代理"; } }
        public string ProxyScopeNote { get { return "代理设置用于本次启动的 " + ApplicationName + " 及其子进程。"; } }
        public string LaunchStrategyTitle { get { return IsCodex ? "应用更新" : "代理启动方式"; } }
        public string LaunchStrategyDetail { get { return IsCodex ? UpdateDetail : selectedApplication.Mode == "electron" ? "Electron 代理参数 + HTTP / HTTPS 环境变量" : "HTTP / HTTPS / ALL_PROXY 环境变量"; } }
        public string LaunchStrategyState { get { return IsCodex ? UpdateState : selectedApplication.Mode == "electron" ? "双通道" : "环境变量"; } }
        public string LaunchStrategyKind { get { return IsCodex ? UpdateKind : "info"; } }
        public string AdapterTitle { get { return IsCodex ? "Windows 应用启动能力" : "代理适配方式"; } }
        public string AdapterDetail { get { return IsCodex ? "AppX 桌面包启动接口" : LaunchStrategyDetail; } }
        public string AdapterState { get { return IsCodex ? AppxState : selectedApplication.KindLabel; } }
        public string AdapterKind { get { return IsCodex ? AppxKind : "info"; } }
        public string LocationTitle { get { return IsCodex ? "桌面快捷方式" : "程序文件"; } }
        public string LocationState { get { return IsCodex ? ShortcutState : !hasChecked ? "等待检测" : status.ApplicationInstalled ? "文件存在" : "未找到"; } }
        public string LocationKind { get { return IsCodex ? ShortcutKind : AppKind; } }
        public string LocationDetail { get { return IsCodex ? "Codex Proxy 启动入口" : string.IsNullOrWhiteSpace(status.ExecutablePath) ? "自动识别安装目录，也可在应用设置中指定" : status.ExecutablePath; } }
        public ObservableCollection<LogEntry> Logs { get; private set; }
        public ICollectionView LogsView { get; private set; }
        public string Version { get { return Product.Version; } }
        public string SelectedPage { get { return selectedPage; } }
        public string PageTitle { get { return selectedPage == "overview" ? ApplicationName : selectedPage == "applications" ? "应用管理" : selectedPage == "diagnostics" ? "运行诊断" : selectedPage == "logs" ? "运行日志" : "设置"; } }
        public string PageSubtitle { get { return selectedPage == "overview" ? "代理启动" : selectedPage == "applications" ? "管理你的桌面工具" : selectedPage == "diagnostics" ? "连接与启动环境" : selectedPage == "logs" ? "查看最近的运行记录" : "让工作方式更适合你"; } }
        public bool IsWorking { get { return refreshing || launching || saving; } }
        public bool IsRefreshing { get { return refreshing; } }
        public bool IsLaunching { get { return launching; } }
        public bool CanLaunch { get { return hasChecked && status.RuntimeReadyNow && !IsWorking; } }
        public bool HasChecked { get { return hasChecked; } }
        public string StatusKind { get { return !hasChecked || launching ? "info" : status.ApplicationRunning && status.RuntimeReadyAfterExit || status.RuntimeReadyNow ? "success" : "error"; } }
        public string StatusBadge { get { return launching ? "启动中" : !hasChecked ? "检测中" : StatusKind == "success" ? status.ApplicationRunning ? "运行中" : "已就绪" : "需处理"; } }
        public string StatusTitle { get { return launching ? "正在为你启动 " + ApplicationName : !hasChecked ? "正在检查连接" : StatusKind == "error" ? "启动前，还需要处理一点问题" : status.ApplicationRunning ? ApplicationName + " 正在运行" : "连接已就绪"; } }
        public string StatusDescription { get { return launching ? "正在检查应用并准备代理环境，请稍候。" : !hasChecked ? "检测本地代理、" + ApplicationName + " 与启动环境。" : StatusKind == "error" ? string.IsNullOrWhiteSpace(status.Remediation) ? status.BlockingMessage : status.Remediation : status.ApplicationRunning ? "代理连接正常。请完全退出 " + ApplicationName + "（包括托盘进程）后，再通过代理启动。已有进程的代理状态无法确认。" : selectedApplication.Mode == "environment" ? "启动环境已就绪。此模式需要应用本身支持 HTTP_PROXY / HTTPS_PROXY 环境变量。" : "代理与启动环境检查通过，可以打开 " + ApplicationName + "。"; } }
        public string LaunchLabel { get { return launching ? "正在启动…" : hasChecked && status.ApplicationRunning ? ApplicationName + " 已在运行" : "启动 " + ApplicationName; } }
        public string ProxyEndpoint { get { return hasChecked && !string.IsNullOrWhiteSpace(status.ProxyUrl) && status.ProxyUrl.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? status.ProxyUrl : "http://127.0.0.1:" + selectedApplication.EffectivePort(savedPort); } }
        public string ProxyState { get { return !hasChecked ? "等待检测" : status.ProxyReady ? "连接正常" : "连接不可用"; } }
        public string ProxyDetail { get { return !hasChecked ? "检测 HTTP CONNECT 连接" : status.ProxyReady ? string.IsNullOrWhiteSpace(status.ProxyProcess) ? "HTTP CONNECT 已通过" : status.ProxyProcess : "请检查本地代理客户端与端口"; } }
        public bool ProxyReady { get { return hasChecked && status.ProxyReady; } }
        public string ProxyKind { get { return !hasChecked ? "info" : ProxyReady ? "success" : "error"; } }
        public string AppState { get { return !hasChecked ? "等待检测" : !status.HasRuntimeData ? "未能确认" : !status.ApplicationInstalled ? "尚未安装" : status.ApplicationRunning ? "正在运行" : "已安装"; } }
        public string AppVersion { get { return string.IsNullOrWhiteSpace(status.ApplicationVersion) ? IsCodex ? "Microsoft Store 版本" : selectedApplication.KindLabel : "版本 " + status.ApplicationVersion; } }
        public bool AppReady { get { return hasChecked && status.ApplicationInstalled && status.ApplicationReady; } }
        public string AppKind { get { return !hasChecked || !status.HasRuntimeData ? "info" : AppReady ? "success" : "error"; } }
        public string UpdateState { get { return !hasChecked ? "等待检测" : !status.HasRuntimeData ? "等待确认" : status.UpdatePending ? "有待应用更新" : "当前无待应用更新"; } }
        public string UpdateDetail { get { return status.UpdatePending ? "下次启动时协调应用 " + status.ReportedUpdateVersion : "由 Codex 官方更新器维护"; } }
        public bool AppxReady { get { return hasChecked && status.AppxAvailable; } }
        public bool ShortcutReady { get { return hasChecked && status.ShortcutReady; } }
        public string AppxKind { get { return !hasChecked || !status.HasRuntimeData ? "info" : AppxReady ? "success" : "error"; } }
        public string ShortcutKind { get { return !hasChecked || !status.HasRuntimeData ? "info" : ShortcutReady ? "success" : "error"; } }
        public string UpdateKind { get { return status.UpdatePending ? "warning" : "info"; } }
        public string AppxState { get { return !hasChecked ? "等待检测" : !status.HasRuntimeData ? "未能确认" : AppxReady ? "可用" : "不可用"; } }
        public string ShortcutState { get { return !hasChecked ? "等待检测" : !status.HasRuntimeData ? "未能确认" : ShortcutReady ? "正常" : "需要修复"; } }
        public string ProcessState { get { return !hasChecked ? "等待检测" : !status.HasRuntimeData ? "未能确认" : status.ApplicationRunning ? "运行中" : "未运行，可以启动"; } }
        public string LastChecked { get { return refreshing ? "正在重新检测…" : !hasChecked ? "尚未完成检测" : "最近检测 " + status.CheckedAt.ToString("HH:mm:ss") + " · 耗时 " + checkSeconds.ToString("0.0") + " 秒"; } }
        public string MonitorText { get { return AutoRefresh ? "每 15 秒自动检测" : "自动检测已暂停"; } }
        public string DiagnosticCode { get { return !hasChecked ? "等待检测" : string.IsNullOrWhiteSpace(status.BlockingCode) ? "READY" : status.BlockingCode; } }
        public string DiagnosticSummary { get { return "Codex Proxy " + Version + Environment.NewLine + "应用：" + ApplicationName + Environment.NewLine + "检测时间：" + (hasChecked ? status.CheckedAt.ToString("yyyy-MM-dd HH:mm:ss") : "尚未检测") + Environment.NewLine + "代理地址：" + ProxyEndpoint + Environment.NewLine + "代理状态：" + ProxyState + Environment.NewLine + "应用状态：" + AppState + " · " + AppVersion + Environment.NewLine + AdapterTitle + "：" + AdapterState + Environment.NewLine + LocationTitle + "：" + LocationState + Environment.NewLine + LocationDetail + Environment.NewLine + "状态代码：" + DiagnosticCode + Environment.NewLine + StatusDescription; } }
        public string PortText { get { return portText; } set { portText = value; Changed("PortText", "PortError", "HasPortError", "PortDirty", "PortPreview"); } }
        public bool HasPortError { get { return PortError.Length > 0; } }
        public string PortError { get { int value; return int.TryParse(portText, NumberStyles.None, CultureInfo.InvariantCulture, out value) && value >= 1 && value <= 65535 ? "" : "请输入 1–65535 之间的端口。"; } }
        public string PortPreview { get { return "http://127.0.0.1:" + portText; } }
        public bool PortDirty { get { return portText != savedPort.ToString(CultureInfo.InvariantCulture); } }
        public bool StartupEnabled
        {
            get { return startup; }
            set
            {
                if (startup == value) return;
                try { runtime.SetStartup(value); startup = value; Changed("StartupEnabled"); ShowToast(value ? "已开启登录后在后台运行" : "已关闭登录后自动运行", "success"); }
                catch (Exception ex) { Changed("StartupEnabled"); Error(ex); }
            }
        }
        public string Theme { get { return preferences.Theme; } }
        public bool CloseToTray { get { return preferences.CloseToTray; } set { ChangePreference(next => next.CloseToTray = value); } }
        public bool AutoRefresh { get { return preferences.AutoRefresh; } set { ChangePreference(next => next.AutoRefresh = value); } }
        public bool SidebarCollapsed { get { return preferences.SidebarCollapsed; } set { ChangePreference(next => next.SidebarCollapsed = value); } }
        internal double SavedWidth { get { return preferences.WindowWidth; } }
        internal double SavedHeight { get { return preferences.WindowHeight; } }
        public string Toast { get { return toast; } }
        public string ToastKind { get { return toastKind; } }
        public bool HasToast { get { return toast.Length > 0; } }
        public string Search { get { return search; } set { search = value ?? ""; LogsView.Refresh(); Changed("Search", "LogSummary", "NoMatchingLogs"); } }
        public string Level { get { return level; } set { level = value; LogsView.Refresh(); Changed("Level", "LogSummary", "NoMatchingLogs"); } }
        public string[] LogLevels { get { return new[] { "全部", "INFO", "WARN", "ERROR" }; } }
        public bool NoMatchingLogs { get { return !LogsView.Cast<LogEntry>().Any(); } }
        public string LogSummary { get { return loadingLogs ? "正在读取日志…" : "显示 " + LogsView.Cast<LogEntry>().Count() + " / " + Logs.Count + " 条 · 最近 500 条记录"; } }
        public string LogError { get { return logError; } }
        public bool HasLogError { get { return logError.Length > 0; } }
        public string LogDirectory { get { return logDirectory; } }

        internal void Navigate(string page)
        {
            if (page != "overview" && page != "applications" && page != "diagnostics" && page != "logs" && page != "settings") return;
            selectedPage = page;
            Changed("SelectedPage", "PageTitle", "PageSubtitle");
            if (page == "logs") ReloadLogsCommand.Execute(null);
        }
        internal async Task RefreshAsync(bool full)
        {
            if (disposed || IsWorking) return;
            refreshing = true; Changed("");
            Stopwatch elapsed = Stopwatch.StartNew();
            try
            {
                ApplicationProfile profile = selectedApplication.Copy();
                DiagnosticStatus result = await Task.Run(() => runtime.GetStatus(profile, full));
                if (disposed) return;
                ApplyStatus(result, elapsed.Elapsed.TotalSeconds);
                if (full) ShowToast("完整诊断已完成", "success");
            }
            catch (Exception ex) { if (!disposed) { ApplyStatus(DiagnosticStatus.FromError("DIAGNOSTIC_FAILED", ex.Message), elapsed.Elapsed.TotalSeconds); Error(ex); } }
            finally { refreshing = false; if (!disposed) Changed(""); }
        }
        internal void ApplyStatus(DiagnosticStatus value, double seconds)
        {
            status = value; hasChecked = true; checkSeconds = seconds;
            Changed("");
        }
        internal async Task LaunchAsync()
        {
            if (!CanLaunch || disposed) return;
            launching = true; Changed("");
            ApplicationProfile profile = selectedApplication.Copy();
            LogStore.Append(logDirectory, "INFO", "[" + profile.Name + "] 请求通过 " + ProxyEndpoint + " 启动。");
            try
            {
                LaunchResult result = await Task.Run(() => runtime.LaunchApplication(profile));
                if (disposed) return;
                ShowToast(result.Success ? profile.Name + " 已在代理环境中启动" : result.Message, result.Success ? "success" : "error");
                Stopwatch statusTimer = Stopwatch.StartNew();
                DiagnosticStatus refreshed = await Task.Run(() => runtime.GetStatus(profile));
                if (!disposed) ApplyStatus(refreshed, statusTimer.Elapsed.TotalSeconds);
            }
            catch (Exception ex) { if (!disposed) Error(ex); }
            finally { launching = false; if (!disposed) Changed(""); }
        }
        internal async Task SavePortAsync()
        {
            if (PortError.Length > 0 || IsWorking || disposed) return;
            saving = true; Changed("");
            try
            {
                int port = int.Parse(portText, CultureInfo.InvariantCulture);
                await Task.Run(() => runtime.SavePort(port));
                savedPort = port;
                if (!disposed) ShowToast("默认代理端口已保存，下次启动应用时生效", "success");
            }
            catch (Exception ex) { if (!disposed) Error(ex); }
            finally { saving = false; if (!disposed) Changed(""); }
            await RefreshAsync(false);
        }
        internal async Task LoadLogsAsync()
        {
            if (loadingLogs || disposed) return;
            loadingLogs = true; Changed("LogSummary");
            try
            {
                var result = await Task.Run(() => LogStore.Read(logDirectory));
                if (disposed) return;
                Logs.Clear(); foreach (LogEntry entry in result) Logs.Add(entry);
                logError = "";
            }
            catch (Exception ex) { if (!disposed) { logError = "日志读取失败：" + ex.Message; Error(ex); } }
            finally { loadingLogs = false; if (!disposed) Changed("LogSummary", "NoMatchingLogs", "LogError", "HasLogError"); }
        }
        internal string ExportLogs() { return LogStore.Format(LogsView.Cast<LogEntry>()); }
        internal string ResolveExecutable(ApplicationProfile profile) { return runtime.ResolveExecutable(profile); }
        internal void SaveApplication(ApplicationProfile profile)
        {
            if (IsWorking || disposed) throw new InvalidOperationException("请等待当前操作完成。");
            ApplicationProfile.Validate(profile);
            ApplicationCatalog next = catalog.Copy();
            int index = next.Applications.FindIndex(app => app.Id == profile.Id);
            if (index < 0) next.Applications.Add(profile.Copy()); else next.Applications[index] = profile.Copy();
            next.SelectedId = profile.Id;
            ApplyCatalog(next); ShowToast(profile.Name + " 的启动配置已保存", "success");
        }
        internal void RemoveApplication(ApplicationProfile profile)
        {
            if (IsWorking || disposed || profile.IsBuiltIn) throw new InvalidOperationException("内置应用不能移除。");
            ApplicationCatalog next = catalog.Copy(); next.Applications.RemoveAll(app => app.Id == profile.Id);
            if (next.SelectedId == profile.Id) next.SelectedId = "codex";
            ApplyCatalog(next); ShowToast("已从启动器移除 " + profile.Name, "success");
        }
        private void ApplyCatalog(ApplicationCatalog next)
        {
            runtime.SaveApplications(next); catalog = next;
            Applications = new ObservableCollection<ApplicationProfile>(next.Applications);
            selectedApplication = Applications.First(app => app.Id == next.SelectedId);
            ResetApplicationStatus(); RefreshCommand.Execute(null);
        }
        private void ResetApplicationStatus()
        {
            status = DiagnosticStatus.FromError("CHECKING", "正在检查运行环境"); hasChecked = false;
            Changed("");
        }
        internal void SetTheme(string theme)
        {
            if (theme != "light" && theme != "dark" && theme != "system") return;
            ChangePreference(next => next.Theme = theme);
        }
        private void ChangePreference(Action<DesktopPreferences> change)
        {
            DesktopPreferences next = preferences.Copy(); change(next);
            try { preferencesStore.Save(next); preferences = next; Changed(""); if (AppearanceChanged != null) AppearanceChanged(this, EventArgs.Empty); }
            catch (Exception ex) { Changed(""); Error(ex); }
        }
        internal void SaveWindowSize(double width, double height)
        {
            if (width < 820 || height < 600) return;
            ChangePreference(next => { next.WindowWidth = width; next.WindowHeight = height; });
        }
        internal void ShowToast(string message, string kind)
        {
            toast = message ?? ""; toastKind = kind;
            LogStore.Append(logDirectory, kind == "error" ? "ERROR" : "INFO", toast);
            Changed("Toast", "ToastKind", "HasToast");
            if (ToastChanged != null) ToastChanged(this, EventArgs.Empty);
        }
        internal void DismissToast() { toast = ""; Changed("Toast", "HasToast"); }
        private bool FilterLog(object value)
        {
            LogEntry entry = value as LogEntry;
            return entry != null && (level == "全部" || entry.Level == level) && (search.Length == 0 || (entry.Message + " " + entry.Source).IndexOf(search, StringComparison.OrdinalIgnoreCase) >= 0);
        }
        private void Error(Exception ex) { ShowToast(ex.Message, "error"); }
        public void Dispose() { disposed = true; runtime.Dispose(); }
    }
}
