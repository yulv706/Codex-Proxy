using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Windows.Forms;

namespace CodexProxyDesktop
{
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
        private readonly Action<bool> setHistoryAutomaticWriteEnabled;
        private readonly Action<bool> setHistoryArchivedEnabled;
        private readonly Action openVault;
        private readonly Action openHistory;
        private readonly Action refreshProjects;
        private readonly Action<string, string, string> createProject;
        private readonly Action<string, string, string> bindProject;
        private readonly Action<string> unbindProject;

        private readonly Dictionary<string, Panel> pages = new Dictionary<string, Panel>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, NavigationButton> navigationButtons = new Dictionary<string, NavigationButton>(StringComparer.OrdinalIgnoreCase);
        private readonly List<Label> historyStatusLabels = new List<Label>();
        private readonly List<Label> historyPathLabels = new List<Label>();
        private readonly List<Label> historyCountLabels = new List<Label>();
        private readonly List<HistoryVaultEntry> allEntries = new List<HistoryVaultEntry>();
        private readonly List<HistoryLocalDirectory> allLocalDirectories = new List<HistoryLocalDirectory>();
        private readonly List<HistoryProjectInfo> allProjects = new List<HistoryProjectInfo>();

        private readonly Panel sidebar;
        private readonly Label brandTitle;
        private readonly Label brandSubtitle;
        private readonly Label sidebarHint;
        private readonly Label versionLabel;
        private readonly Label pageTitle;
        private readonly AppButton headerRefreshButton;
        private readonly Panel actionBanner;
        private readonly Label actionMessage;
        private readonly Timer toastTimer;
        private readonly ToolTip navigationTips;

        private PillLabel statusPill;
        private RoundedPanel overviewHero;
        private int overviewHeroHeight;
        private bool fittingOverviewStatus;
        private Label statusTitle;
        private Label statusMeta;
        private Label proxyStatus;
        private Label codexStatus;
        private Label updateStatus;
        private Label checkedAt;
        private AppButton launchButton;
        private TableLayoutPanel overviewLayout;
        private TableLayoutPanel overviewMetrics;
        private int overviewMetricColumns;

        private NumericUpDown portInput;
        private ToggleSwitch startupCheck;
        private ToggleSwitch historyEnabledCheck;
        private ToggleSwitch historyAutomaticWriteCheck;
        private ToggleSwitch historyArchivedCheck;
        private ToggleSwitch showArchivedCheck;
        private AppButton historySyncButton;

        private TextBox sessionSearch;
        private ComboBox sessionProjectFilter;
        private readonly Timer sessionSearchTimer;
        private BufferedListView sessionList;
        private Label sessionEmptyLabel;
        private Label sessionSummary;
        private Label sessionDetailTitle;
        private Label sessionDetailMeta;
        private Label sessionDetailPath;
        private AppButton copySessionButton;

        private TextBox localSearch;
        private BufferedListView localDirectoryList;
        private BufferedListView sharedProjectList;
        private TextBox projectPathInput;
        private TextBox projectNameInput;
        private Label projectSummary;
        private Label syncSelectionTitle;
        private Label syncSelectionPath;
        private AppButton createModeButton;
        private AppButton bindModeButton;
        private AppButton projectActionButton;
        private AppButton unbindProjectButton;
        private TableLayoutPanel syncLayout;
        private RoundedPanel syncDetailsPanel;
        private Panel syncPage;

        private Panel settingsFlow;
        private RoundedPanel networkCard;
        private RoundedPanel vaultCard;
        private RoundedPanel appCard;
        private AppButton chooseVaultButton;

        private string currentPage = "overview";
        private bool bindMode;
        private bool updatingProjectFilters;
        private bool syncDetailsVisible;
        private bool resizingSettingsCards;
        private string selectedCodexProjectId;

        internal bool AllowExit;
        internal event EventHandler ExitRequested;

        internal MainWindow(int initialPort, Action<int> savePortAction, Action launchAction, Action refreshAction, Action openLogsAction,
            Action<bool> startupAction, Action configureHistoryAction, Action syncHistoryAction, Action<bool> historyEnabledAction,
            Action<bool> historyAutomaticWriteAction,
            Action<bool> historyArchivedAction, Action openVaultAction, Action openHistoryAction, Action refreshProjectsAction,
            Action<string, string, string> createProjectAction, Action<string, string, string> bindProjectAction, Action<string> unbindProjectAction)
        {
            savePort = savePortAction;
            launch = launchAction;
            refresh = refreshAction;
            openLogs = openLogsAction;
            setStartup = startupAction;
            configureHistory = configureHistoryAction;
            syncHistory = syncHistoryAction;
            setHistoryEnabled = historyEnabledAction;
            setHistoryAutomaticWriteEnabled = historyAutomaticWriteAction;
            setHistoryArchivedEnabled = historyArchivedAction;
            openVault = openVaultAction;
            openHistory = openHistoryAction;
            refreshProjects = refreshProjectsAction;
            createProject = createProjectAction;
            bindProject = bindProjectAction;
            unbindProject = unbindProjectAction;

            SuspendLayout();
            Text = "Codex Proxy";
            ClientSize = new Size(1180, 760);
            MinimumSize = new Size(940, 660);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Ui.Canvas;
            Font = Ui.Font(9F, FontStyle.Regular);
            AutoScaleMode = AutoScaleMode.Dpi;
            AutoScaleDimensions = new SizeF(96F, 96F);
            KeyPreview = true;
            AccessibleName = "Codex Proxy 控制中心";
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            sidebar = new Panel { Dock = DockStyle.Left, Width = 202, BackColor = Ui.Sidebar, Padding = new Padding(12, 0, 12, 0) };
            Panel brand = new Panel { Dock = DockStyle.Top, Height = 104, BackColor = Color.Transparent };
            BrandMark brandMark = new BrandMark { Location = new Point(3, 21), Size = new Size(36, 36), Accent = Ui.Accent };
            brandTitle = Ui.Label("Codex Proxy", 13F, FontStyle.Bold, Ui.Text);
            brandTitle.Font = Ui.LatinFont(13F, FontStyle.Bold);
            brandTitle.Location = new Point(48, 20);
            brandTitle.Size = new Size(128, 25);
            brandSubtitle = Ui.Label("CONTROL CENTER", 7.6F, FontStyle.Bold, Ui.TertiaryText);
            brandSubtitle.Font = Ui.LatinFont(7.6F, FontStyle.Bold);
            brandSubtitle.Location = new Point(49, 45);
            brandSubtitle.Size = new Size(126, 22);
            brand.Controls.AddRange(new Control[] { brandMark, brandTitle, brandSubtitle });
            sidebar.Controls.Add(brand);

            FlowLayoutPanel navigation = new FlowLayoutPanel
            {
                Dock = DockStyle.Top,
                Height = 210,
                FlowDirection = FlowDirection.TopDown,
                WrapContents = false,
                BackColor = Color.Transparent,
                Margin = Padding.Empty,
                Padding = Padding.Empty
            };
            sidebar.Controls.Add(navigation);
            navigation.BringToFront();
            navigationTips = new ToolTip { InitialDelay = 250, ReshowDelay = 100 };
            AddNavigation(navigation, "overview", "首页", AppIconKind.Home, delegate { ShowPage("overview"); });
            AddNavigation(navigation, "sessions", "历史会话", AppIconKind.Sessions, delegate { openHistory(); });
            AddNavigation(navigation, "sync", "历史同步", AppIconKind.Sync, delegate { ShowSyncPage(); });
            AddNavigation(navigation, "settings", "设置", AppIconKind.Settings, delegate { ShowPage("settings"); });

            Panel footer = new Panel { Dock = DockStyle.Bottom, Height = 94, BackColor = Color.Transparent };
            sidebarHint = Ui.Label("关闭后继续在托盘运行", 8.2F, FontStyle.Regular, Ui.TertiaryText);
            sidebarHint.Location = new Point(4, 16);
            sidebarHint.Size = new Size(174, 24);
            versionLabel = Ui.Label("Version 3.5.8", 8.2F, FontStyle.Bold, Ui.TertiaryText);
            versionLabel.Font = Ui.LatinFont(8.2F, FontStyle.Bold);
            versionLabel.Location = new Point(4, 45);
            versionLabel.Size = new Size(150, 24);
            footer.Controls.AddRange(new Control[] { sidebarHint, versionLabel });
            sidebar.Controls.Add(footer);

            Panel workspace = new Panel { Dock = DockStyle.Fill, BackColor = Ui.Canvas };
            Panel topbar = new Panel { Dock = DockStyle.Top, Height = 78, BackColor = Color.White, Padding = new Padding(26, 0, 24, 0) };
            pageTitle = Ui.Label("首页", 21F, FontStyle.Bold, Ui.Text);
            pageTitle.Font = Ui.DisplayFont(21F, FontStyle.Bold);
            pageTitle.Location = new Point(26, 17);
            pageTitle.Size = new Size(560, 42);
            topbar.Controls.Add(pageTitle);
            headerRefreshButton = Button("刷新", AppButtonStyle.Secondary, 82, 36);
            headerRefreshButton.IconKind = AppIconKind.Refresh;
            headerRefreshButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            headerRefreshButton.Location = new Point(850, 21);
            headerRefreshButton.Click += delegate { RefreshCurrentPage(); };
            headerRefreshButton.AccessibleDescription = "刷新当前页面";
            topbar.Controls.Add(headerRefreshButton);
            topbar.Resize += delegate { headerRefreshButton.Left = topbar.ClientSize.Width - headerRefreshButton.Width - 24; };

            actionBanner = new Panel { Dock = DockStyle.Bottom, Height = 50, BackColor = Ui.AccentSoft, Visible = false };
            actionMessage = Ui.Label(string.Empty, 9F, FontStyle.Bold, Ui.Accent);
            actionMessage.Location = new Point(26, 8);
            actionMessage.Size = new Size(760, 34);
            actionMessage.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            AppButton dismissAction = Button("×", AppButtonStyle.Ghost, 38, 32);
            dismissAction.Font = Ui.Font(13F, FontStyle.Regular);
            dismissAction.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            dismissAction.Location = new Point(880, 9);
            dismissAction.Click += delegate { HideAction(); };
            actionBanner.Controls.AddRange(new Control[] { actionMessage, dismissAction });
            actionBanner.Resize += delegate
            {
                dismissAction.Left = actionBanner.ClientSize.Width - dismissAction.Width - 18;
                actionMessage.Width = Math.Max(120, dismissAction.Left - 36);
            };
            toastTimer = new Timer { Interval = 5500 };
            toastTimer.Tick += delegate { HideAction(); };

            Panel pageHost = new Panel { Dock = DockStyle.Fill, BackColor = Ui.Canvas };
            workspace.Controls.Add(pageHost);
            workspace.Controls.Add(actionBanner);
            workspace.Controls.Add(topbar);

            Panel overviewPage = BuildOverviewPage();
            Panel sessionsPage = BuildSessionsPage();
            Panel historySyncPage = BuildSyncPage();
            Panel settingsPage = BuildSettingsPage(initialPort);
            pages.Add("overview", overviewPage);
            pages.Add("sessions", sessionsPage);
            pages.Add("sync", historySyncPage);
            pages.Add("settings", settingsPage);
            pageHost.Controls.AddRange(new Control[] { overviewPage, sessionsPage, historySyncPage, settingsPage });

            Controls.Add(sidebar);
            Controls.Add(workspace);
            workspace.BringToFront();

            sessionSearchTimer = new Timer { Interval = 180 };
            sessionSearchTimer.Tick += delegate { sessionSearchTimer.Stop(); RebuildSessionList(); };

            Resize += delegate { ApplyResponsiveLayout(); };
            KeyDown += OnWindowKeyDown;
            ShowPage("overview");
            SetSyncMode(false);
            ApplyResponsiveLayout();
            ResumeLayout(true);
            FitWindowToScreen();
            ApplyResponsiveLayout();
            Ui.SetCueText(sessionSearch, "搜索会话…");
            Ui.SetCueText(localSearch, "搜索目录…");
            Ui.SetCueText(projectNameInput, "项目名称");
        }

        private Panel BuildOverviewPage()
        {
            Panel page = NewPage();
            page.AutoScroll = true;
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Top, Height = 524, Padding = new Padding(24, 20, 24, 22), ColumnCount = 1, RowCount = 4, BackColor = Ui.Canvas };
            overviewLayout = layout;
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 142F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 144F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 58F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 138F));
            page.Controls.Add(layout);

            RoundedPanel hero = Card();
            overviewHero = hero;
            hero.Dock = DockStyle.Fill;
            hero.Margin = new Padding(0, 0, 0, 12);
            statusPill = new PillLabel { Text = "检查中", Location = new Point(24, 19), Size = new Size(82, 26) };
            statusTitle = Ui.Label("正在读取状态", 17F, FontStyle.Bold, Ui.Text);
            statusTitle.Font = Ui.DisplayFont(17F, FontStyle.Bold);
            statusTitle.Location = new Point(24, 50);
            statusTitle.Size = new Size(700, 36);
            statusTitle.AutoEllipsis = false;
            statusMeta = Ui.Label("", 9.2F, FontStyle.Regular, Ui.SecondaryText);
            statusMeta.Location = new Point(24, 88);
            statusMeta.Size = new Size(760, 36);
            statusMeta.AutoEllipsis = false;
            statusMeta.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            checkedAt = Ui.Label("", 8.5F, FontStyle.Regular, Ui.TertiaryText);
            checkedAt.Size = new Size(160, 26);
            checkedAt.Location = new Point(750, 20);
            checkedAt.TextAlign = ContentAlignment.MiddleRight;
            checkedAt.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            hero.Controls.AddRange(new Control[] { statusPill, statusTitle, statusMeta, checkedAt });
            hero.Resize += delegate
            {
                checkedAt.Left = hero.ClientSize.Width - checkedAt.Width - ScaleLogical(24);
                statusTitle.Width = Math.Max(100, hero.ClientSize.Width - statusTitle.Left - ScaleLogical(24));
                statusMeta.Width = Math.Max(100, hero.ClientSize.Width - statusMeta.Left - ScaleLogical(24));
                FitOverviewStatusText();
            };
            layout.Controls.Add(hero, 0, 0);

            TableLayoutPanel metrics = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, BackColor = Ui.Canvas, Margin = Padding.Empty };
            overviewMetrics = metrics;
            metrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33.333F));
            metrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33.333F));
            metrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33.334F));
            proxyStatus = AddMetric(metrics, 0, "网络代理", "检查中", new Padding(0, 0, 8, 12));
            codexStatus = AddMetric(metrics, 1, "Codex", "检查中", new Padding(4, 0, 4, 12));
            updateStatus = AddMetric(metrics, 2, "应用更新", "检查中", new Padding(8, 0, 0, 12));
            layout.Controls.Add(metrics, 0, 1);

            FlowLayoutPanel actions = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, BackColor = Ui.Canvas, Margin = Padding.Empty };
            launchButton = Button("启动 Codex", AppButtonStyle.Primary, 152, 40);
            launchButton.IconKind = AppIconKind.Launch;
            launchButton.Margin = new Padding(0, 2, 10, 6);
            launchButton.Click += delegate { launch(); };
            AppButton openSessionsButton = Button("查看会话", AppButtonStyle.Secondary, 112, 40);
            openSessionsButton.IconKind = AppIconKind.Sessions;
            openSessionsButton.Margin = new Padding(0, 2, 10, 6);
            openSessionsButton.Click += delegate { openHistory(); };
            AppButton overviewLogs = Button("日志", AppButtonStyle.Ghost, 76, 40);
            overviewLogs.IconKind = AppIconKind.Logs;
            overviewLogs.Margin = new Padding(0, 2, 0, 6);
            overviewLogs.Click += delegate { openLogs(); };
            actions.Controls.AddRange(new Control[] { launchButton, openSessionsButton, overviewLogs });
            layout.Controls.Add(actions, 0, 2);

            RoundedPanel historyCard = Card();
            historyCard.Dock = DockStyle.Fill;
            historyCard.Margin = Padding.Empty;
            Label historyHeading = Ui.Label("最近同步", 11F, FontStyle.Bold, Ui.Text);
            historyHeading.Location = new Point(22, 14);
            historyHeading.Size = new Size(180, 28);
            Label overviewHistoryStatus = Ui.Label("尚未读取", 10F, FontStyle.Bold, Ui.SecondaryText);
            overviewHistoryStatus.Location = new Point(22, 43);
            overviewHistoryStatus.Size = new Size(620, 26);
            Label overviewHistoryCounts = Ui.Label("", 8.8F, FontStyle.Regular, Ui.SecondaryText);
            overviewHistoryCounts.Location = new Point(22, 70);
            overviewHistoryCounts.Size = new Size(680, 26);
            overviewHistoryCounts.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            AppButton goSync = Button("管理同步", AppButtonStyle.Secondary, 112, 34);
            goSync.IconKind = AppIconKind.Sync;
            goSync.Location = new Point(770, 44);
            goSync.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            goSync.Click += delegate { ShowSyncPage(); };
            historyStatusLabels.Add(overviewHistoryStatus);
            historyCountLabels.Add(overviewHistoryCounts);
            historyCard.Controls.AddRange(new Control[] { historyHeading, overviewHistoryStatus, overviewHistoryCounts, goSync });
            historyCard.Resize += delegate
            {
                goSync.Left = historyCard.ClientSize.Width - goSync.Width - ScaleLogical(22);
                int available = Math.Max(120, goSync.Left - overviewHistoryStatus.Left - ScaleLogical(12));
                overviewHistoryStatus.Width = available;
                overviewHistoryCounts.Width = available;
            };
            layout.Controls.Add(historyCard, 0, 3);
            return page;
        }

        private Panel BuildSessionsPage()
        {
            Panel page = NewPage();
            TableLayoutPanel layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(24, 18, 24, 22), ColumnCount = 1, RowCount = 3, BackColor = Ui.Canvas };
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48F));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 112F));
            page.Controls.Add(layout);

            Panel toolbar = new Panel { Dock = DockStyle.Fill, BackColor = Ui.Canvas, Margin = Padding.Empty };
            sessionSearch = TextBox(320);
            sessionSearch.Location = new Point(0, 4);
            sessionSearch.AccessibleName = "搜索历史会话";
            sessionSearch.TextChanged += delegate { if (sessionSearchTimer != null) { sessionSearchTimer.Stop(); sessionSearchTimer.Start(); } };
            toolbar.Controls.Add(sessionSearch);
            sessionProjectFilter = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Font = Ui.Font(9F, FontStyle.Regular), Location = new Point(334, 4), Size = new Size(184, 32), FlatStyle = FlatStyle.Flat, AccessibleName = "按项目筛选会话" };
            sessionProjectFilter.Items.Add("全部项目");
            sessionProjectFilter.SelectedIndex = 0;
            sessionProjectFilter.SelectedIndexChanged += delegate { RebuildSessionList(); };
            toolbar.Controls.Add(sessionProjectFilter);
            Label archivedLabel = Ui.Label("归档", 9F, FontStyle.Regular, Ui.SecondaryText);
            archivedLabel.Size = new Size(44, 28);
            archivedLabel.Location = new Point(540, 5);
            toolbar.Controls.Add(archivedLabel);
            showArchivedCheck = new ToggleSwitch { Location = new Point(584, 6), AccessibleName = "显示已归档会话" };
            showArchivedCheck.CheckedChanged += delegate { RebuildSessionList(); };
            toolbar.Controls.Add(showArchivedCheck);
            layout.Controls.Add(toolbar, 0, 0);

            RoundedPanel listCard = Card();
            listCard.Dock = DockStyle.Fill;
            listCard.Margin = new Padding(0, 0, 0, 12);
            listCard.Padding = new Padding(12, 10, 12, 10);
            sessionList = new BufferedListView { Dock = DockStyle.Fill, ShowGroups = true, AccessibleName = "历史会话列表" };
            sessionList.Columns.Add("会话", 1);
            sessionList.Columns.Add("更新时间", 1);
            sessionList.Columns.Add("项目", 1);
            sessionList.Columns.Add("来源", 1);
            sessionList.Columns.Add("状态", 1);
            sessionList.SelectedIndexChanged += delegate { UpdateSessionDetails(); };
            sessionList.Resize += delegate { ResizeSessionColumns(); };
            sessionEmptyLabel = Ui.Label("这里还没有会话", 12F, FontStyle.Bold, Ui.SecondaryText);
            sessionEmptyLabel.Dock = DockStyle.Fill;
            sessionEmptyLabel.TextAlign = ContentAlignment.MiddleCenter;
            sessionEmptyLabel.Visible = false;
            listCard.Controls.Add(sessionList);
            listCard.Controls.Add(sessionEmptyLabel);
            layout.Controls.Add(listCard, 0, 1);

            RoundedPanel detail = Card();
            detail.Dock = DockStyle.Fill;
            detail.Margin = Padding.Empty;
            sessionDetailTitle = Ui.Label("选择一个会话", 11F, FontStyle.Bold, Ui.Text);
            sessionDetailTitle.Location = new Point(20, 12);
            sessionDetailTitle.Size = new Size(600, 27);
            sessionDetailMeta = Ui.Label("", 8.8F, FontStyle.Regular, Ui.SecondaryText);
            sessionDetailMeta.Location = new Point(20, 40);
            sessionDetailMeta.Size = new Size(660, 24);
            sessionDetailPath = Ui.Label("", 8.5F, FontStyle.Regular, Ui.TertiaryText);
            sessionDetailPath.Location = new Point(20, 65);
            sessionDetailPath.Size = new Size(650, 24);
            sessionDetailPath.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            copySessionButton = Button("复制 ID", AppButtonStyle.Secondary, 94, 34);
            copySessionButton.IconKind = AppIconKind.Copy;
            copySessionButton.Enabled = false;
            copySessionButton.Location = new Point(720, 36);
            copySessionButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            copySessionButton.Click += delegate { CopySelectedSessionId(); };
            AppButton openVaultButton = Button("打开仓库", AppButtonStyle.Ghost, 102, 34);
            openVaultButton.IconKind = AppIconKind.Folder;
            openVaultButton.Location = new Point(824, 36);
            openVaultButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            openVaultButton.Click += delegate { openVault(); };
            sessionSummary = Ui.Label("正在读取历史仓库", 8.5F, FontStyle.Regular, Ui.TertiaryText);
            sessionSummary.Location = new Point(20, 84);
            sessionSummary.Size = new Size(660, 21);
            detail.Controls.AddRange(new Control[] { sessionDetailTitle, sessionDetailMeta, sessionDetailPath, sessionSummary, copySessionButton, openVaultButton });
            detail.Resize += delegate
            {
                openVaultButton.Left = detail.ClientSize.Width - openVaultButton.Width - 18;
                copySessionButton.Left = openVaultButton.Left - copySessionButton.Width - 8;
                sessionDetailTitle.Width = Math.Max(220, copySessionButton.Left - 38);
                sessionDetailMeta.Width = sessionDetailTitle.Width;
                sessionDetailPath.Width = sessionDetailTitle.Width;
                sessionSummary.Width = sessionDetailTitle.Width;
            };
            layout.Controls.Add(detail, 0, 2);
            return page;
        }

        private Panel BuildSyncPage()
        {
            Panel page = NewPage();
            syncPage = page;
            page.AutoScroll = true;
            syncLayout = new TableLayoutPanel { Dock = DockStyle.Top, Height = 590, Padding = new Padding(24, 18, 24, 22), ColumnCount = 1, RowCount = 4, BackColor = Ui.Canvas };
            syncLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            syncLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 114F));
            syncLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            syncLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 104F));
            syncLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 0F));
            page.Controls.Add(syncLayout);
            page.Resize += delegate { ApplySyncLayout(); };

            RoundedPanel hero = Card();
            hero.Dock = DockStyle.Fill;
            hero.Margin = new Padding(0, 0, 0, 12);
            Label syncStatus = Ui.Label("正在读取同步状态", 13F, FontStyle.Bold, Ui.Text);
            syncStatus.Location = new Point(22, 12);
            syncStatus.Size = new Size(560, 29);
            Label syncCounts = Ui.Label("", 9F, FontStyle.Regular, Ui.SecondaryText);
            syncCounts.Location = new Point(22, 43);
            syncCounts.Size = new Size(620, 25);
            Label syncPath = Ui.Label("", 8.5F, FontStyle.Regular, Ui.TertiaryText);
            syncPath.Location = new Point(22, 68);
            syncPath.Size = new Size(620, 23);
            syncPath.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            historyStatusLabels.Add(syncStatus);
            historyPathLabels.Add(syncPath);
            historyCountLabels.Add(syncCounts);
            projectSummary = syncCounts;
            historySyncButton = Button("立即同步", AppButtonStyle.Primary, 108, 36);
            historySyncButton.IconKind = AppIconKind.Sync;
            historySyncButton.Location = new Point(704, 34);
            historySyncButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            historySyncButton.Click += delegate { syncHistory(); };
            AppButton syncDetailsButton = Button("同步原理", AppButtonStyle.Ghost, 92, 36);
            syncDetailsButton.Location = new Point(820, 34);
            syncDetailsButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            syncDetailsButton.Click += delegate { ToggleSyncDetails(); };
            hero.Controls.AddRange(new Control[] { syncStatus, syncCounts, syncPath, historySyncButton, syncDetailsButton });
            hero.Resize += delegate
            {
                syncDetailsButton.Left = hero.ClientSize.Width - syncDetailsButton.Width - 18;
                historySyncButton.Left = syncDetailsButton.Left - historySyncButton.Width - 8;
                syncStatus.Width = Math.Max(220, historySyncButton.Left - 38);
                syncCounts.Width = syncStatus.Width;
                syncPath.Width = syncStatus.Width;
            };
            syncLayout.Controls.Add(hero, 0, 0);

            TableLayoutPanel projectGrid = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, BackColor = Ui.Canvas, Margin = Padding.Empty };
            projectGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            projectGrid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50F));
            RoundedPanel localCard = Card();
            localCard.Dock = DockStyle.Fill;
            localCard.Margin = new Padding(0, 0, 6, 12);
            Label localTitle = Ui.Label("本机 Codex 项目", 11F, FontStyle.Bold, Ui.Text);
            localTitle.Location = new Point(18, 12);
            localTitle.Size = new Size(150, 28);
            localSearch = TextBox(210);
            localSearch.Location = new Point(174, 11);
            localSearch.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            localSearch.AccessibleName = "搜索本机 Codex 项目";
            localSearch.TextChanged += delegate { RebuildProjectLists(); };
            localDirectoryList = new BufferedListView { Location = new Point(14, 50), Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right, AccessibleName = "本机 Codex 项目列表", MultiSelect = false };
            localDirectoryList.Size = new Size(390, 230);
            localDirectoryList.Columns.Add("项目 / 根目录", 1);
            localDirectoryList.Columns.Add("会话", 1);
            localDirectoryList.Columns.Add("状态", 1);
            localDirectoryList.SelectedIndexChanged += delegate { SelectLocalDirectory(); };
            localDirectoryList.Resize += delegate { ResizeProjectColumns(); };
            localCard.Controls.AddRange(new Control[] { localTitle, localSearch, localDirectoryList });
            localCard.Resize += delegate
            {
                int titleRight = localTitle.Left + TextRenderer.MeasureText(localTitle.Text, localTitle.Font).Width;
                bool stackedSearch = localCard.ClientSize.Width < ScaleLogical(420);
                localSearch.Left = stackedSearch ? ScaleLogical(14) : Math.Max(ScaleLogical(174), titleRight + ScaleLogical(12));
                localSearch.Top = stackedSearch ? ScaleLogical(43) : ScaleLogical(11);
                localSearch.Width = Math.Max(ScaleLogical(100), localCard.ClientSize.Width - localSearch.Left - ScaleLogical(16));
                localDirectoryList.Top = stackedSearch ? ScaleLogical(82) : ScaleLogical(50);
                localDirectoryList.Size = new Size(Math.Max(ScaleLogical(100), localCard.ClientSize.Width - ScaleLogical(28)), Math.Max(ScaleLogical(80), localCard.ClientSize.Height - localDirectoryList.Top - ScaleLogical(14)));
            };
            projectGrid.Controls.Add(localCard, 0, 0);

            RoundedPanel sharedCard = Card();
            sharedCard.Dock = DockStyle.Fill;
            sharedCard.Margin = new Padding(6, 0, 0, 12);
            Label sharedTitle = Ui.Label("同步项目", 11F, FontStyle.Bold, Ui.Text);
            sharedTitle.Location = new Point(18, 12);
            sharedTitle.Size = new Size(180, 28);
            sharedProjectList = new BufferedListView { Location = new Point(14, 50), Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right, AccessibleName = "共享同步项目列表", MultiSelect = false };
            sharedProjectList.Size = new Size(390, 230);
            sharedProjectList.Columns.Add("项目", 1);
            sharedProjectList.Columns.Add("会话", 1);
            sharedProjectList.Columns.Add("本机", 1);
            sharedProjectList.SelectedIndexChanged += delegate { SelectSharedProject(); };
            sharedProjectList.Resize += delegate { ResizeProjectColumns(); };
            sharedCard.Controls.AddRange(new Control[] { sharedTitle, sharedProjectList });
            sharedCard.Resize += delegate { sharedProjectList.Size = new Size(Math.Max(ScaleLogical(100), sharedCard.ClientSize.Width - ScaleLogical(28)), Math.Max(ScaleLogical(80), sharedCard.ClientSize.Height - ScaleLogical(64))); };
            projectGrid.Controls.Add(sharedCard, 1, 0);
            syncLayout.Controls.Add(projectGrid, 0, 1);

            RoundedPanel actionCard = Card();
            actionCard.Dock = DockStyle.Fill;
            actionCard.Margin = new Padding(0, 0, 0, 10);
            createModeButton = Button("新建", AppButtonStyle.Secondary, 72, 32);
            createModeButton.IconKind = AppIconKind.Add;
            createModeButton.Location = new Point(16, 14);
            createModeButton.Click += delegate { SetSyncMode(false); };
            bindModeButton = Button("绑定现有", AppButtonStyle.Ghost, 94, 32);
            bindModeButton.IconKind = AppIconKind.Link;
            bindModeButton.Location = new Point(94, 14);
            bindModeButton.Click += delegate { SetSyncMode(true); };
            syncSelectionTitle = Ui.Label("选择一个本机 Codex 项目", 10F, FontStyle.Bold, Ui.Text);
            syncSelectionTitle.Location = new Point(204, 10);
            syncSelectionTitle.Size = new Size(430, 27);
            syncSelectionPath = Ui.Label("", 8.5F, FontStyle.Regular, Ui.TertiaryText);
            syncSelectionPath.Location = new Point(204, 36);
            syncSelectionPath.Size = new Size(430, 24);
            projectPathInput = new TextBox { Visible = false };
            projectNameInput = TextBox(240);
            projectNameInput.Location = new Point(204, 61);
            projectNameInput.AccessibleName = "同步项目名称";
            projectNameInput.TextChanged += delegate { UpdateProjectActionState(); };
            projectActionButton = Button("创建项目", AppButtonStyle.Primary, 112, 36);
            projectActionButton.IconKind = AppIconKind.Add;
            projectActionButton.Location = new Point(716, 34);
            projectActionButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            projectActionButton.Click += delegate { RunProjectPrimaryAction(); };
            unbindProjectButton = Button("停止同步", AppButtonStyle.Danger, 100, 36);
            unbindProjectButton.Location = new Point(834, 34);
            unbindProjectButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            unbindProjectButton.Click += delegate { UnbindSelectedProject(); };
            unbindProjectButton.Visible = false;
            actionCard.Controls.AddRange(new Control[] { createModeButton, bindModeButton, syncSelectionTitle, syncSelectionPath, projectPathInput, projectNameInput, projectActionButton, unbindProjectButton });
            actionCard.Resize += delegate { LayoutProjectActionCard(actionCard); };
            syncLayout.Controls.Add(actionCard, 0, 2);

            syncDetailsPanel = Card();
            syncDetailsPanel.Dock = DockStyle.Fill;
            syncDetailsPanel.Margin = Padding.Empty;
            syncDetailsPanel.Visible = false;
            Label detailsTitle = Ui.Label("同步原理", 10F, FontStyle.Bold, Ui.Text);
            detailsTitle.Location = new Point(18, 10);
            detailsTitle.Size = new Size(140, 25);
            Label detailsText = Ui.Label("运行时只保存完整会话；Codex 退出后再安全合并。只处理你绑定的项目，归档会话默认不参与。", 9F, FontStyle.Regular, Ui.SecondaryText);
            detailsText.Location = new Point(18, 38);
            detailsText.Size = new Size(840, 46);
            detailsText.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            syncDetailsPanel.Controls.AddRange(new Control[] { detailsTitle, detailsText });
            syncLayout.Controls.Add(syncDetailsPanel, 0, 3);
            return page;
        }

        private Panel BuildSettingsPage(int initialPort)
        {
            Panel page = NewPage();
            settingsFlow = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Ui.Canvas };
            page.Controls.Add(settingsFlow);

            networkCard = Card();
            networkCard.Size = new Size(900, 116);
            networkCard.Margin = new Padding(0, 0, 0, 12);
            Label networkTitle = Ui.Label("网络代理", 12F, FontStyle.Bold, Ui.Text);
            networkTitle.Location = new Point(22, 13);
            networkTitle.Size = new Size(180, 30);
            Label portTitle = Ui.Label("端口", 9.5F, FontStyle.Regular, Ui.Text);
            portTitle.Location = new Point(22, 58);
            portTitle.Size = new Size(80, 30);
            portInput = new NumericUpDown { Minimum = 1, Maximum = 65535, Value = Math.Max(1, Math.Min(65535, initialPort)), Font = Ui.Font(10F, FontStyle.Regular), ThousandsSeparator = false, Size = new Size(128, 31), Location = new Point(620, 57), Anchor = AnchorStyles.Top | AnchorStyles.Right, AccessibleName = "网络代理端口" };
            AppButton savePortButton = Button("应用", AppButtonStyle.Primary, 86, 34);
            savePortButton.Location = new Point(762, 55);
            savePortButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            savePortButton.Click += delegate { savePort(Convert.ToInt32(portInput.Value)); };
            networkCard.Controls.AddRange(new Control[] { networkTitle, portTitle, portInput, savePortButton });
            networkCard.Resize += delegate
            {
                savePortButton.Left = networkCard.ClientSize.Width - savePortButton.Width - 20;
                portInput.Left = savePortButton.Left - portInput.Width - 10;
            };
            settingsFlow.Controls.Add(networkCard);

            vaultCard = Card();
            vaultCard.Size = new Size(900, 226);
            vaultCard.Margin = new Padding(0, 0, 0, 12);
            Label vaultTitle = Ui.Label("历史仓库", 12F, FontStyle.Bold, Ui.Text);
            vaultTitle.Location = new Point(22, 13);
            vaultTitle.Size = new Size(180, 30);
            chooseVaultButton = Button("更改…", AppButtonStyle.Secondary, 92, 34);
            chooseVaultButton.IconKind = AppIconKind.Folder;
            chooseVaultButton.Location = new Point(788, 12);
            chooseVaultButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            chooseVaultButton.Click += delegate { configureHistory(); };
            Label settingsHistoryStatus = Ui.Label("尚未配置", 10F, FontStyle.Bold, Ui.SecondaryText);
            settingsHistoryStatus.Location = new Point(22, 48);
            settingsHistoryStatus.Size = new Size(600, 26);
            Label settingsHistoryPath = Ui.Label("", 8.8F, FontStyle.Regular, Ui.TertiaryText);
            settingsHistoryPath.Location = new Point(22, 74);
            settingsHistoryPath.Size = new Size(820, 24);
            settingsHistoryPath.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            Label settingsHistoryCounts = Ui.Label("", 8.8F, FontStyle.Regular, Ui.SecondaryText);
            settingsHistoryCounts.Location = new Point(22, 98);
            settingsHistoryCounts.Size = new Size(820, 24);
            settingsHistoryCounts.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            historyStatusLabels.Add(settingsHistoryStatus);
            historyPathLabels.Add(settingsHistoryPath);
            historyCountLabels.Add(settingsHistoryCounts);
            Label realtimeTitle = Ui.Label("历史会话同步", 9.5F, FontStyle.Regular, Ui.Text);
            realtimeTitle.Location = new Point(22, 130);
            realtimeTitle.Size = new Size(180, 28);
            historyEnabledCheck = new ToggleSwitch { Location = new Point(820, 132), Anchor = AnchorStyles.Top | AnchorStyles.Right, AccessibleName = "启用历史会话同步" };
            historyEnabledCheck.CheckedChanged += delegate { if (historyEnabledCheck.Focused) setHistoryEnabled(historyEnabledCheck.Checked); };
            Label automaticWriteTitle = Ui.Label("后台自动写入", 9.5F, FontStyle.Regular, Ui.Text);
            automaticWriteTitle.Location = new Point(22, 160);
            automaticWriteTitle.Size = new Size(220, 28);
            historyAutomaticWriteCheck = new ToggleSwitch { Location = new Point(820, 162), Anchor = AnchorStyles.Top | AnchorStyles.Right, AccessibleName = "允许后台自动写入历史会话" };
            historyAutomaticWriteCheck.CheckedChanged += delegate { if (historyAutomaticWriteCheck.Focused) setHistoryAutomaticWriteEnabled(historyAutomaticWriteCheck.Checked); };
            Label archivedTitle = Ui.Label("包括归档会话", 9.5F, FontStyle.Regular, Ui.Text);
            archivedTitle.Location = new Point(22, 190);
            archivedTitle.Size = new Size(180, 28);
            historyArchivedCheck = new ToggleSwitch { Location = new Point(820, 192), Anchor = AnchorStyles.Top | AnchorStyles.Right, AccessibleName = "同步已归档会话" };
            historyArchivedCheck.CheckedChanged += delegate { if (historyArchivedCheck.Focused) setHistoryArchivedEnabled(historyArchivedCheck.Checked); };
            vaultCard.Controls.AddRange(new Control[] { vaultTitle, chooseVaultButton, settingsHistoryStatus, settingsHistoryPath, settingsHistoryCounts, realtimeTitle, historyEnabledCheck, automaticWriteTitle, historyAutomaticWriteCheck, archivedTitle, historyArchivedCheck });
            vaultCard.Resize += delegate
            {
                chooseVaultButton.Left = vaultCard.ClientSize.Width - chooseVaultButton.Width - 20;
                historyEnabledCheck.Left = vaultCard.ClientSize.Width - historyEnabledCheck.Width - 22;
                historyAutomaticWriteCheck.Left = historyEnabledCheck.Left;
                historyArchivedCheck.Left = historyEnabledCheck.Left;
            };
            settingsFlow.Controls.Add(vaultCard);

            appCard = Card();
            appCard.Size = new Size(900, 154);
            appCard.Margin = Padding.Empty;
            Label appTitle = Ui.Label("应用", 12F, FontStyle.Bold, Ui.Text);
            appTitle.Location = new Point(22, 13);
            appTitle.Size = new Size(180, 30);
            Label startupTitle = Ui.Label("登录 Windows 后自动运行", 9.5F, FontStyle.Regular, Ui.Text);
            startupTitle.Location = new Point(22, 50);
            startupTitle.Size = new Size(260, 28);
            startupCheck = new ToggleSwitch { Location = new Point(820, 52), Anchor = AnchorStyles.Top | AnchorStyles.Right, AccessibleName = "登录 Windows 后自动运行" };
            startupCheck.CheckedChanged += delegate { if (startupCheck.Focused) setStartup(startupCheck.Checked); };
            Label trayTitle = Ui.Label("关闭窗口后留在托盘", 9.5F, FontStyle.Regular, Ui.Text);
            trayTitle.Location = new Point(22, 80);
            trayTitle.Size = new Size(260, 28);
            PillLabel trayPill = new PillLabel { Text = "已开启", Size = new Size(70, 26), Location = new Point(794, 81), Anchor = AnchorStyles.Top | AnchorStyles.Right, Accent = Ui.Success, Fill = Ui.SuccessSoft };
            AppButton settingsLogs = Button("打开日志", AppButtonStyle.Secondary, 100, 34);
            settingsLogs.IconKind = AppIconKind.Logs;
            settingsLogs.Location = new Point(22, 112);
            settingsLogs.Click += delegate { openLogs(); };
            AppButton exitButton = Button("退出后台", AppButtonStyle.Danger, 100, 34);
            exitButton.Location = new Point(132, 112);
            exitButton.Click += delegate { if (ExitRequested != null) ExitRequested(this, EventArgs.Empty); };
            appCard.Controls.AddRange(new Control[] { appTitle, startupTitle, startupCheck, trayTitle, trayPill, settingsLogs, exitButton });
            appCard.Resize += delegate
            {
                startupCheck.Left = appCard.ClientSize.Width - startupCheck.Width - 22;
                trayPill.Left = appCard.ClientSize.Width - trayPill.Width - 22;
            };
            settingsFlow.Controls.Add(appCard);
            settingsFlow.Resize += delegate { ResizeSettingsCards(); };
            return page;
        }

        private void AddNavigation(FlowLayoutPanel host, string key, string text, AppIconKind iconKind, Action action)
        {
            NavigationButton button = new NavigationButton { Text = text, IconKind = iconKind, Width = 178, Height = 42, Margin = new Padding(0, 0, 0, 5), AccessibleName = text };
            button.Click += delegate { action(); };
            navigationTips.SetToolTip(button, text);
            navigationButtons.Add(key, button);
            host.Controls.Add(button);
        }

        private static Panel NewPage() { return new Panel { Dock = DockStyle.Fill, BackColor = Ui.Canvas, Visible = false }; }
        private static RoundedPanel Card() { return new RoundedPanel { BackColor = Ui.Surface, BorderColor = Ui.Separator, Radius = 16 }; }
        private static AppButton Button(string text, AppButtonStyle style, int width, int height) { return new AppButton { Text = text, Style = style, Size = new Size(width, height), AccessibleName = text }; }
        private static TextBox TextBox(int width) { return new TextBox { Width = width, Height = 31, Font = Ui.Font(9.5F, FontStyle.Regular), BorderStyle = BorderStyle.FixedSingle, BackColor = Color.White, ForeColor = Ui.Text }; }

        private static Label AddMetric(TableLayoutPanel host, int column, string title, string value, Padding margin)
        {
            RoundedPanel card = Card();
            card.Dock = DockStyle.Fill;
            card.Margin = margin;
            Label heading = Ui.Label(title, 9F, FontStyle.Bold, Ui.SecondaryText);
            heading.Location = new Point(20, 15);
            heading.Size = new Size(180, 25);
            Label result = Ui.Label(value, 11F, FontStyle.Bold, Ui.Text);
            result.Font = Ui.DisplayFont(11F, FontStyle.Bold);
            result.Location = new Point(20, 43);
            result.Size = new Size(240, 66);
            result.AutoEllipsis = false;
            card.Controls.AddRange(new Control[] { heading, result });
            card.Resize += delegate { result.Width = Math.Max(100, card.ClientSize.Width - result.Left - Math.Max(12, result.Left)); };
            host.Controls.Add(card, column, 0);
            return result;
        }

        internal void ShowPage(string key)
        {
            string normalized = string.Equals(key, "projects", StringComparison.OrdinalIgnoreCase) ? "sync" : key;
            Panel page;
            if (!pages.TryGetValue(normalized, out page)) return;
            foreach (KeyValuePair<string, Panel> pair in pages) pair.Value.Visible = string.Equals(pair.Key, normalized, StringComparison.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, NavigationButton> pair in navigationButtons) pair.Value.Selected = string.Equals(pair.Key, normalized, StringComparison.OrdinalIgnoreCase);
            currentPage = normalized;
            if (normalized == "overview") pageTitle.Text = "首页";
            else if (normalized == "sessions") pageTitle.Text = "历史会话";
            else if (normalized == "sync") pageTitle.Text = "历史同步";
            else pageTitle.Text = "设置";
            page.BringToFront();
            headerRefreshButton.Visible = true;
            ApplyResponsiveLayout();
        }

        private void ShowSyncPage() { ShowPage("sync"); refreshProjects(); }

        private void RefreshCurrentPage()
        {
            if (currentPage == "sessions") openHistory();
            else if (currentPage == "sync") { refresh(); refreshProjects(); }
            else refresh();
        }

        private void OnWindowKeyDown(object sender, KeyEventArgs e)
        {
            if (e.KeyCode == Keys.F5) { RefreshCurrentPage(); e.Handled = true; }
            else if (e.Control && e.KeyCode == Keys.F)
            {
                if (currentPage == "sessions") sessionSearch.Focus();
                else if (currentPage == "sync") localSearch.Focus();
                e.SuppressKeyPress = true;
            }
            else if (e.KeyCode == Keys.Escape && actionBanner.Visible) { HideAction(); e.Handled = true; }
        }

        private void ApplyResponsiveLayout()
        {
            bool compact = ClientSize.Width < ScaleLogical(1060);
            sidebar.Width = ScaleLogical(compact ? 76 : 202);
            sidebar.Padding = new Padding(ScaleLogical(compact ? 8 : 12), 0, ScaleLogical(compact ? 8 : 12), 0);
            brandTitle.Visible = !compact;
            brandSubtitle.Visible = !compact;
            sidebarHint.Visible = !compact;
            versionLabel.Text = compact ? "3.5.8" : "Version 3.5.8";
            versionLabel.TextAlign = compact ? ContentAlignment.MiddleCenter : ContentAlignment.MiddleLeft;
            versionLabel.Width = ScaleLogical(compact ? 56 : 150);
            foreach (NavigationButton button in navigationButtons.Values) { button.Compact = compact; button.Width = ScaleLogical(compact ? 58 : 178); }
            ApplyOverviewLayout();
            FitOverviewStatusText();
            ApplySyncLayout();
            ResizeSessionColumns();
            ResizeProjectColumns();
            ResizeSettingsCards();
        }

        private int ScaleLogical(int value)
        {
            return Math.Max(1, (int)Math.Round(value * UiScale));
        }

        private float UiScale { get { return Math.Max(1F, CurrentAutoScaleDimensions.Width / 96F); } }

        private void FitWindowToScreen()
        {
            Rectangle working = Screen.FromPoint(Cursor.Position).WorkingArea;
            int maximumWidth = Math.Max(1, working.Width - ScaleLogical(24));
            int maximumHeight = Math.Max(1, working.Height - ScaleLogical(24));
            MinimumSize = new Size(Math.Min(ScaleLogical(940), maximumWidth), Math.Min(ScaleLogical(660), maximumHeight));
            Size = new Size(Math.Min(ScaleLogical(1200), maximumWidth), Math.Min(ScaleLogical(700), maximumHeight));
        }

        private void ApplyOverviewLayout()
        {
            if (overviewLayout == null || overviewMetrics == null || proxyStatus == null || codexStatus == null || updateStatus == null) return;
            int logicalWidth = (int)Math.Round(ClientSize.Width / UiScale);
            int columns = logicalWidth >= 1100 ? 3 : logicalWidth >= 720 ? 2 : 1;
            int rows = (3 + columns - 1) / columns;
            if (overviewMetricColumns != columns)
            {
                Control[] cards = { proxyStatus.Parent, codexStatus.Parent, updateStatus.Parent };
                overviewMetrics.SuspendLayout();
                overviewMetrics.Controls.Clear();
                overviewMetrics.ColumnStyles.Clear();
                overviewMetrics.RowStyles.Clear();
                overviewMetrics.ColumnCount = columns;
                overviewMetrics.RowCount = rows;
                for (int index = 0; index < columns; index++) overviewMetrics.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F / columns));
                for (int index = 0; index < rows; index++) overviewMetrics.RowStyles.Add(new RowStyle(SizeType.Percent, 100F / rows));
                for (int index = 0; index < cards.Length; index++)
                {
                    int row = index / columns;
                    int column = index % columns;
                    cards[index].Margin = new Padding(column == 0 ? 0 : ScaleLogical(6), 0, column == columns - 1 ? 0 : ScaleLogical(6), ScaleLogical(12));
                    overviewMetrics.Controls.Add(cards[index], column, row);
                    overviewMetrics.SetColumnSpan(cards[index], columns == 2 && index == 2 ? 2 : 1);
                }
                overviewMetrics.ResumeLayout(true);
                overviewMetricColumns = columns;
            }
            overviewLayout.Padding = new Padding(ScaleLogical(24), ScaleLogical(20), ScaleLogical(24), ScaleLogical(22));
            int heroHeight = Math.Max(ScaleLogical(142), overviewHeroHeight);
            overviewLayout.RowStyles[0].Height = heroHeight;
            overviewLayout.RowStyles[1].Height = ScaleLogical(rows * 144);
            overviewLayout.RowStyles[2].Height = ScaleLogical(58);
            overviewLayout.RowStyles[3].Height = ScaleLogical(138);
            overviewLayout.Height = ScaleLogical(238 + rows * 144) + heroHeight;
        }

        private void FitOverviewStatusText()
        {
            if (fittingOverviewStatus || overviewHero == null || statusTitle == null || statusMeta == null) return;
            fittingOverviewStatus = true;
            try
            {
                statusTitle.Height = Math.Max(ScaleLogical(36), MeasureWrappedHeight(statusTitle) + ScaleLogical(4));
                statusMeta.Top = statusTitle.Bottom + ScaleLogical(2);
                statusMeta.Height = Math.Max(ScaleLogical(28), MeasureWrappedHeight(statusMeta) + ScaleLogical(4));
                int needed = statusMeta.Bottom + ScaleLogical(16);
                if (overviewHeroHeight != needed)
                {
                    overviewHeroHeight = needed;
                    ApplyOverviewLayout();
                }
            }
            finally { fittingOverviewStatus = false; }
        }

        private static int MeasureWrappedHeight(Label label)
        {
            if (string.IsNullOrWhiteSpace(label.Text)) return 0;
            return TextRenderer.MeasureText(label.Text, label.Font, new Size(Math.Max(1, label.Width), 10000), TextFormatFlags.WordBreak | TextFormatFlags.NoPadding).Height;
        }

        private void ApplySyncLayout()
        {
            if (syncPage == null || syncLayout == null) return;
            syncLayout.Padding = new Padding(ScaleLogical(24), ScaleLogical(18), ScaleLogical(24), ScaleLogical(22));
            syncLayout.RowStyles[0].Height = ScaleLogical(114);
            syncLayout.RowStyles[2].Height = ScaleLogical(104);
            syncLayout.RowStyles[3].Height = syncDetailsVisible ? ScaleLogical(96) : 0;
            syncLayout.Height = Math.Max(syncPage.ClientSize.Height, ScaleLogical(590 + (syncDetailsVisible ? 96 : 0)));
        }

        private void ResizeSettingsCards()
        {
            if (settingsFlow == null || networkCard == null || resizingSettingsCards) return;
            resizingSettingsCards = true;
            try
            {
                int left = ScaleLogical(24);
                int gap = ScaleLogical(12);
                int width = Math.Max(ScaleLogical(300), settingsFlow.ClientSize.Width - ScaleLogical(48) - SystemInformation.VerticalScrollBarWidth - ScaleLogical(4));
                networkCard.Width = width;
                vaultCard.Width = width;
                appCard.Width = width;
                networkCard.Location = new Point(left, ScaleLogical(20));
                vaultCard.Location = new Point(left, networkCard.Bottom + gap);
                appCard.Location = new Point(left, vaultCard.Bottom + gap);
                int contentHeight = appCard.Bottom + ScaleLogical(22);
                settingsFlow.AutoScrollMinSize = new Size(0, contentHeight);
                if (settingsFlow.HorizontalScroll.Visible && settingsFlow.DisplayRectangle.Width > settingsFlow.ClientSize.Width)
                {
                    settingsFlow.AutoScroll = false;
                    settingsFlow.AutoScroll = true;
                    settingsFlow.AutoScrollMinSize = new Size(0, contentHeight);
                }
            }
            finally { resizingSettingsCards = false; }
        }

        internal string CurrentPage { get { return currentPage; } }
        internal bool UsesVectorNavigationIcons
        {
            get
            {
                if (navigationButtons.Count != 4) return false;
                foreach (NavigationButton button in navigationButtons.Values) if (button.IconKind == AppIconKind.None) return false;
                return true;
            }
        }
        internal bool UsesRefinedTypography
        {
            get
            {
                return string.Equals(Font.Name, Ui.ActiveBodyFontFamily, StringComparison.OrdinalIgnoreCase)
                    && string.Equals(pageTitle.Font.Name, Ui.ActiveDisplayFontFamily, StringComparison.OrdinalIgnoreCase);
            }
        }
        internal int VisibleSessionCount { get { return sessionList.Items.Count; } }
        internal string FirstVisibleSessionTitle { get { return sessionList.Items.Count == 0 ? null : sessionList.Items[0].Text; } }
        internal int VisibleLocalProjectCount { get { return localDirectoryList.Items.Count; } }
        internal int VisibleSharedProjectCount { get { return sharedProjectList.Items.Count; } }
        internal bool CompactLayoutActive { get { return sidebar.Width <= ScaleLogical(76); } }
        internal void VerifyOverviewTextLayout()
        {
            if (brandTitle.Visible) VerifyReadableLabel(brandTitle, "品牌名称");
            if (brandSubtitle.Visible) VerifyReadableLabel(brandSubtitle, "品牌副标题");
            if (sidebarHint.Visible) VerifyReadableLabel(sidebarHint, "侧栏说明");
            VerifyReadableLabel(pageTitle, "页面标题");
            VerifyReadableLabel(statusTitle, "运行状态");
            VerifyReadableLabel(statusMeta, "运行说明");
            VerifyReadableLabel(proxyStatus, "网络代理");
            VerifyReadableLabel(codexStatus, "Codex 状态");
            VerifyReadableLabel(updateStatus, "应用更新");
            if (headerRefreshButton.Width < TextRenderer.MeasureText(headerRefreshButton.Text, headerRefreshButton.Font).Width + 42)
                throw new InvalidOperationException("刷新按钮文字空间不足。");
        }

        private void VerifyReadableLabel(Label label, string description)
        {
            if (string.IsNullOrWhiteSpace(label.Text)) return;
            if (label.Width <= 0 || label.Height <= 0) throw new InvalidOperationException(description + "没有可用空间。");
            TextFormatFlags flags = label.AutoEllipsis ? TextFormatFlags.SingleLine : TextFormatFlags.WordBreak;
            Size measured = TextRenderer.MeasureText(label.Text, label.Font, new Size(label.Width, 1000), flags | TextFormatFlags.NoPadding);
            if (measured.Width > label.Width || measured.Height > label.Height)
                throw new InvalidOperationException(description + "文字被截断：" + label.Text + " (" + measured.Width + "x" + measured.Height + " > " + label.Width + "x" + label.Height + "; card=" + (label.Parent == null ? 0 : label.Parent.Width) + "; window=" + ClientSize.Width + "x" + ClientSize.Height + "; scale=" + UiScale + "; columns=" + overviewMetricColumns + ")");
        }
        internal bool HistoryVaultPickerVisible { get { return chooseVaultButton.Parent == vaultCard && chooseVaultButton.Width > 0 && chooseVaultButton.Right <= vaultCard.ClientSize.Width; } }
        internal bool SessionColumnsFit
        {
            get
            {
                int total = 0;
                foreach (ColumnHeader column in sessionList.Columns) total += column.Width;
                return total <= sessionList.ClientSize.Width + 2;
            }
        }
        internal bool ProjectColumnsFit
        {
            get
            {
                int localTotal = 0;
                foreach (ColumnHeader column in localDirectoryList.Columns) localTotal += column.Width;
                int sharedTotal = 0;
                foreach (ColumnHeader column in sharedProjectList.Columns) sharedTotal += column.Width;
                return localTotal <= localDirectoryList.ClientSize.Width + 2 && sharedTotal <= sharedProjectList.ClientSize.Width + 2;
            }
        }
        internal string ProjectColumnDiagnostics
        {
            get
            {
                int localTotal = 0, sharedTotal = 0;
                foreach (ColumnHeader column in localDirectoryList.Columns) localTotal += column.Width;
                foreach (ColumnHeader column in sharedProjectList.Columns) sharedTotal += column.Width;
                return "local=" + localTotal + "/" + localDirectoryList.ClientSize.Width + ", shared=" + sharedTotal + "/" + sharedProjectList.ClientSize.Width + ", scale=" + UiScale;
            }
        }
        internal string SettingsScrollDiagnostics
        {
            get
            {
                return "client=" + settingsFlow.ClientSize.Width + ", display=" + settingsFlow.DisplayRectangle.Width + ", horizontal=" + settingsFlow.HorizontalScroll.Visible + ", cardRight=" + networkCard.Right + ", scrollMin=" + settingsFlow.AutoScrollMinSize.Width;
            }
        }
        internal bool SettingsHorizontalOverflow { get { return settingsFlow.HorizontalScroll.Visible; } }
        internal bool StartupEnabled { get { return startupCheck.Checked; } set { startupCheck.Checked = value; } }

        internal void SetChecking()
        {
            checkedAt.Text = "正在刷新…";
            headerRefreshButton.Enabled = false;
            headerRefreshButton.Text = "刷新中";
        }

        internal void SetLaunching()
        {
            statusPill.Text = "启动中";
            statusPill.Accent = Ui.Accent;
            statusPill.Fill = Ui.AccentSoft;
            statusTitle.Text = "正在启动 Codex";
            launchButton.Enabled = false;
            launchButton.Text = "启动中…";
            ShowActionInfo("正在验证运行环境");
        }

        internal void ApplyStatus(DiagnosticStatus status)
        {
            headerRefreshButton.Enabled = true;
            headerRefreshButton.Text = "刷新";
            statusTitle.Text = status.Title;
            checkedAt.Text = status.CheckedAt.ToString("HH:mm") + " 更新";
            proxyStatus.Text = FormatMetricText(RemovePrefix(status.ProxyDescription, "代理："));
            codexStatus.Text = FormatMetricText(RemovePrefix(status.CodexDescription, "Codex："));
            updateStatus.Text = FormatMetricText(RemovePrefix(status.UpdateDescription, "更新："));
            navigationTips.SetToolTip(statusTitle, status.Title);
            navigationTips.SetToolTip(proxyStatus, status.ProxyDescription);
            navigationTips.SetToolTip(codexStatus, status.CodexDescription);
            navigationTips.SetToolTip(updateStatus, status.UpdateDescription);
            launchButton.Enabled = status.RuntimeReadyNow;
            if (status.CodexRunning) launchButton.Text = "Codex 正在运行";
            else if (status.RuntimeReadyNow) launchButton.Text = "启动 Codex";
            else launchButton.Text = "暂时不可用";
            if (status.CodexRunning || (status.RuntimeReadyNow && !status.UpdatePending))
            {
                statusPill.Text = "正常";
                statusPill.Accent = Ui.Success;
                statusPill.Fill = Ui.SuccessSoft;
                statusMeta.Text = status.CodexRunning ? "代理连接正常，历史会话正在后台保存" : "代理连接正常，可以启动 Codex";
            }
            else if (status.UpdatePending)
            {
                statusPill.Text = "有更新";
                statusPill.Accent = Ui.Warning;
                statusPill.Fill = Ui.WarningSoft;
                statusMeta.Text = status.UpdateDescription;
            }
            else
            {
                statusPill.Text = "需处理";
                statusPill.Accent = Ui.Danger;
                statusPill.Fill = Ui.DangerSoft;
                statusMeta.Text = string.IsNullOrWhiteSpace(status.Remediation) ? status.BlockingMessage : status.Remediation;
            }
            if (!string.IsNullOrWhiteSpace(status.BlockingMessage) && !status.CodexRunning) ShowActionError(statusMeta.Text);
            navigationTips.SetToolTip(statusMeta, statusMeta.Text);
            FitOverviewStatusText();
        }

        internal void ApplyHistoryStatus(HistorySyncStatus status)
        {
            historyEnabledCheck.Checked = status.Enabled;
            historyAutomaticWriteCheck.Checked = status.AutomaticWriteEnabled;
            historyAutomaticWriteCheck.Enabled = status.Configured && status.Enabled;
            historyArchivedCheck.Checked = status.SyncArchived;
            historySyncButton.Enabled = status.Ready;
            historySyncButton.Text = "立即同步";
            string state;
            string path;
            Color color;
            if (!status.Configured) { state = "尚未配置历史仓库"; path = "未选择仓库"; color = Ui.SecondaryText; }
            else if (!status.Enabled) { state = "历史会话已暂停"; path = string.IsNullOrWhiteSpace(status.VaultPath) ? "仓库未连接" : status.VaultPath; color = Ui.Warning; }
            else if (!status.VaultConnected) { state = "历史仓库未连接"; path = "连接移动硬盘后会自动恢复"; color = Ui.Danger; }
            else if (status.SelectedProjectCount == 0) { state = "请选择要同步的项目"; path = status.VaultPath; color = Ui.Warning; }
            else if (!status.AutomaticWriteEnabled) { state = "手动同步模式"; path = status.VaultPath; color = Ui.Warning; }
            else { state = status.CodexRunning ? "正在实时保存" : "同步已就绪"; path = status.VaultPath; color = Ui.Success; }
            string counts = status.SelectedProjectCount + " 个项目 · " + status.SelectedLocalSessionCount + " 个本机会话 · 仓库 " + status.VaultSessionCount + " 个" + LastSyncSuffix(status);
            foreach (Label label in historyStatusLabels) { label.Text = state; label.ForeColor = color; }
            foreach (Label label in historyPathLabels) { label.Text = Ui.CompactPath(path, 84); navigationTips.SetToolTip(label, path); }
            foreach (Label label in historyCountLabels) { label.Text = counts; navigationTips.SetToolTip(label, counts); }
        }

        internal void SetHistoryWorking(string message)
        {
            foreach (Label label in historyStatusLabels) { label.Text = "正在同步"; label.ForeColor = Ui.Accent; }
            historySyncButton.Enabled = false;
            historySyncButton.Text = "同步中…";
            ShowActionInfo(message);
        }

        internal void SetHistoryListLoading() { sessionSummary.Text = "正在读取…"; sessionSummary.ForeColor = Ui.Accent; }

        internal void ApplyHistoryList(HistoryVaultListResult result)
        {
            allEntries.Clear();
            if (result.Success) allEntries.AddRange(result.Entries);
            if (!result.Success)
            {
                sessionList.Items.Clear();
                sessionSummary.Text = result.Message;
                sessionSummary.ForeColor = Ui.Danger;
                sessionEmptyLabel.Text = "无法读取历史会话";
                sessionEmptyLabel.Visible = true;
                sessionEmptyLabel.BringToFront();
                ShowActionError(result.Message);
                return;
            }
            PopulateSessionProjectFilter();
            sessionSummary.ForeColor = Ui.TertiaryText;
            RebuildSessionList();
        }

        private void PopulateSessionProjectFilter()
        {
            string selected = sessionProjectFilter.SelectedItem == null ? "全部项目" : Convert.ToString(sessionProjectFilter.SelectedItem);
            HashSet<string> values = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (HistoryVaultEntry entry in allEntries) values.Add(SessionProjectName(entry));
            List<string> sorted = new List<string>(values);
            sorted.Sort(StringComparer.CurrentCultureIgnoreCase);
            sessionProjectFilter.BeginUpdate();
            sessionProjectFilter.Items.Clear();
            sessionProjectFilter.Items.Add("全部项目");
            foreach (string value in sorted) sessionProjectFilter.Items.Add(value);
            int index = sessionProjectFilter.Items.IndexOf(selected);
            sessionProjectFilter.SelectedIndex = index >= 0 ? index : 0;
            sessionProjectFilter.EndUpdate();
        }

        private void RebuildSessionList()
        {
            if (sessionList == null) return;
            string query = sessionSearch.Text.Trim();
            string projectFilter = sessionProjectFilter.SelectedItem == null ? "全部项目" : Convert.ToString(sessionProjectFilter.SelectedItem);
            List<HistoryVaultEntry> visible = new List<HistoryVaultEntry>();
            int archivedHidden = 0;
            foreach (HistoryVaultEntry entry in allEntries)
            {
                if (entry.Archived && !showArchivedCheck.Checked) { archivedHidden++; continue; }
                string project = SessionProjectName(entry);
                if (!string.Equals(projectFilter, "全部项目", StringComparison.OrdinalIgnoreCase) && !string.Equals(project, projectFilter, StringComparison.OrdinalIgnoreCase)) continue;
                string directory = SessionDirectory(entry);
                string haystack = entry.Title + " " + entry.MachineNames + " " + entry.ThreadId + " " + directory + " " + project;
                if (query.Length > 0 && haystack.IndexOf(query, StringComparison.OrdinalIgnoreCase) < 0) continue;
                visible.Add(entry);
            }
            visible.Sort(delegate(HistoryVaultEntry left, HistoryVaultEntry right) { return right.UpdatedAt.CompareTo(left.UpdatedAt); });
            sessionList.BeginUpdate();
            sessionList.Items.Clear();
            sessionList.Groups.Clear();
            Dictionary<string, List<HistoryVaultEntry>> grouped = new Dictionary<string, List<HistoryVaultEntry>>(StringComparer.OrdinalIgnoreCase);
            foreach (HistoryVaultEntry entry in visible)
            {
                string key = string.IsNullOrWhiteSpace(entry.ProjectId) ? "未归属项目" : entry.ProjectId;
                List<HistoryVaultEntry> entries;
                if (!grouped.TryGetValue(key, out entries)) { entries = new List<HistoryVaultEntry>(); grouped.Add(key, entries); }
                entries.Add(entry);
            }
            foreach (KeyValuePair<string, List<HistoryVaultEntry>> pair in grouped)
            {
                HistoryVaultEntry first = pair.Value[0];
                string project = SessionProjectName(first);
                ListViewGroup group = new ListViewGroup(project + "  (" + pair.Value.Count + ")", HorizontalAlignment.Left);
                sessionList.Groups.Add(group);
                foreach (HistoryVaultEntry entry in pair.Value)
                {
                    string state = entry.IsConflict ? "冲突" : (entry.Archived ? "归档" : "正常");
                    ListViewItem item = new ListViewItem(entry.Title, group);
                    item.SubItems.Add(FriendlyTime(entry.UpdatedAt));
                    item.SubItems.Add(project);
                    item.SubItems.Add(entry.MachineNames);
                    item.SubItems.Add(state);
                    item.Tag = entry;
                    if (entry.IsConflict) item.ForeColor = Ui.Warning;
                    else if (entry.Archived) item.ForeColor = Ui.TertiaryText;
                    sessionList.Items.Add(item);
                }
            }
            sessionList.EndUpdate();
            sessionEmptyLabel.Text = query.Length > 0 || projectFilter != "全部项目" ? "没有符合条件的会话" : "这里还没有会话";
            sessionEmptyLabel.Visible = sessionList.Items.Count == 0;
            if (sessionEmptyLabel.Visible) sessionEmptyLabel.BringToFront(); else sessionList.BringToFront();
            sessionSummary.Text = sessionList.Items.Count + " 个会话" + (archivedHidden > 0 ? " · 隐藏 " + archivedHidden + " 个归档" : "");
            UpdateSessionDetails();
        }

        private void UpdateSessionDetails()
        {
            HistoryVaultEntry entry = SelectedSession();
            copySessionButton.Enabled = entry != null && !string.IsNullOrWhiteSpace(entry.ThreadId);
            if (entry == null)
            {
                sessionDetailTitle.Text = "选择一个会话";
                sessionDetailMeta.Text = string.Empty;
                sessionDetailPath.Text = string.Empty;
                return;
            }
            sessionDetailTitle.Text = entry.Title;
            string status = entry.IsConflict ? "冲突副本" : (entry.Archived ? "已归档" : "正常");
            string updated = entry.UpdatedAt == DateTime.MinValue ? "时间未知" : entry.UpdatedAt.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
            sessionDetailMeta.Text = updated + " · " + entry.MachineNames + " · " + status + " · " + FormatBytes(entry.ContentLength);
            sessionDetailPath.Text = SessionDirectory(entry);
            navigationTips.SetToolTip(sessionDetailTitle, entry.Title);
            navigationTips.SetToolTip(sessionDetailMeta, sessionDetailMeta.Text);
            navigationTips.SetToolTip(sessionDetailPath, sessionDetailPath.Text);
        }

        private HistoryVaultEntry SelectedSession() { return sessionList.SelectedItems.Count == 0 ? null : sessionList.SelectedItems[0].Tag as HistoryVaultEntry; }

        private void CopySelectedSessionId()
        {
            HistoryVaultEntry entry = SelectedSession();
            if (entry == null || string.IsNullOrWhiteSpace(entry.ThreadId)) return;
            try { Clipboard.SetText(entry.ThreadId); ShowActionSuccess("会话 ID 已复制"); }
            catch (Exception ex) { ShowActionError("复制失败：" + ex.Message); }
        }

        private void ResizeSessionColumns()
        {
            if (sessionList == null || sessionList.Columns.Count < 5) return;
            int width = Math.Max(ScaleLogical(400), sessionList.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - ScaleLogical(12));
            int updated = ScaleLogical(126);
            int source = ScaleLogical(92);
            int status = ScaleLogical(72);
            int remaining = Math.Max(ScaleLogical(260), width - updated - source - status);
            sessionList.Columns[0].Width = Math.Max(ScaleLogical(180), (int)(remaining * 0.58));
            sessionList.Columns[1].Width = updated;
            sessionList.Columns[2].Width = Math.Max(ScaleLogical(120), remaining - sessionList.Columns[0].Width);
            sessionList.Columns[3].Width = source;
            sessionList.Columns[4].Width = status;
        }

        internal void SetProjectCatalogLoading(string message) { projectSummary.Text = "正在读取项目…"; projectSummary.ForeColor = Ui.Accent; projectActionButton.Enabled = false; }

        internal void ApplyProjectCatalog(HistoryProjectCatalogResult result)
        {
            allLocalDirectories.Clear();
            allProjects.Clear();
            if (!result.Success)
            {
                localDirectoryList.Items.Clear();
                sharedProjectList.Items.Clear();
                projectSummary.Text = "无法读取同步项目";
                projectSummary.ForeColor = Ui.Danger;
                ShowActionError(result.Message);
                return;
            }
            allLocalDirectories.AddRange(result.LocalDirectories);
            allProjects.AddRange(result.Projects);
            int codexProjectCount = result.CodexProjectCount > 0 ? result.CodexProjectCount : result.LocalDirectories.Count;
            projectSummary.Text = result.BoundProjectCount + " 个同步项目已连接 · 本机发现 " + codexProjectCount + " 个 Codex 项目";
            projectSummary.ForeColor = Ui.SecondaryText;
            RebuildProjectLists();
        }

        private void RebuildProjectLists()
        {
            if (localDirectoryList == null || updatingProjectFilters) return;
            updatingProjectFilters = true;
            string selectedPath = projectPathInput.Text;
            string selectedProjectId = SelectedProjectId();
            string query = localSearch.Text.Trim();
            localDirectoryList.BeginUpdate();
            sharedProjectList.BeginUpdate();
            localDirectoryList.Items.Clear();
            sharedProjectList.Items.Clear();
            Dictionary<string, int> localDisplayCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (HistoryLocalDirectory directory in allLocalDirectories)
            {
                string rootSummary = Ui.CompactPath(directory.Path, 52);
                if (directory.RootPaths.Count > 1) rootSummary += "  +" + (directory.RootPaths.Count - 1).ToString(CultureInfo.CurrentCulture) + " 个根目录";
                string displayKey = (string.IsNullOrWhiteSpace(directory.CodexProjectName) ? directory.Path : directory.CodexProjectName + "  ·  " + rootSummary);
                int count;
                localDisplayCounts.TryGetValue(displayKey, out count);
                localDisplayCounts[displayKey] = count + 1;
            }
            foreach (HistoryLocalDirectory directory in allLocalDirectories)
            {
                string rootSummary = Ui.CompactPath(directory.Path, 52);
                if (directory.RootPaths.Count > 1) rootSummary += "  +" + (directory.RootPaths.Count - 1).ToString(CultureInfo.CurrentCulture) + " 个根目录";
                string displayKey = string.IsNullOrWhiteSpace(directory.CodexProjectName) ? directory.Path : directory.CodexProjectName + "  ·  " + rootSummary;
                string displayName = displayKey;
                if (localDisplayCounts[displayKey] > 1 && !string.IsNullOrWhiteSpace(directory.CodexProjectId))
                {
                    string shortId = directory.CodexProjectId.Length > 8 ? directory.CodexProjectId.Substring(0, 8) : directory.CodexProjectId;
                    displayName = displayKey + "  ·  " + shortId;
                }
                string haystack = directory.Path + " " + directory.ProjectName + " " + directory.CodexProjectName + " " + string.Join(" ", directory.RootPaths.ToArray());
                if (query.Length > 0 && haystack.IndexOf(query, StringComparison.OrdinalIgnoreCase) < 0) continue;
                ListViewItem item = new ListViewItem(displayName);
                item.SubItems.Add(directory.ActiveSessionCount.ToString(CultureInfo.CurrentCulture));
                item.SubItems.Add(directory.Selected ? "已同步" : "未同步");
                item.Tag = directory;
                if (directory.Selected) item.ForeColor = Ui.Success;
                localDirectoryList.Items.Add(item);
                if ((!string.IsNullOrWhiteSpace(selectedCodexProjectId) && string.Equals(directory.CodexProjectId, selectedCodexProjectId, StringComparison.OrdinalIgnoreCase)) ||
                    (string.IsNullOrWhiteSpace(selectedCodexProjectId) && !string.IsNullOrWhiteSpace(selectedPath) && string.Equals(directory.Path, selectedPath, StringComparison.OrdinalIgnoreCase))) item.Selected = true;
            }
            foreach (HistoryProjectInfo project in allProjects)
            {
                ListViewItem item = new ListViewItem(project.Name);
                item.SubItems.Add(project.SessionCount.ToString(CultureInfo.CurrentCulture));
                item.SubItems.Add(project.Bound ? "已连接" : "未连接");
                item.Tag = project;
                if (project.Bound) item.ForeColor = Ui.Success;
                sharedProjectList.Items.Add(item);
                if (!string.IsNullOrWhiteSpace(selectedProjectId) && string.Equals(project.ProjectId, selectedProjectId, StringComparison.OrdinalIgnoreCase)) item.Selected = true;
            }
            localDirectoryList.EndUpdate();
            sharedProjectList.EndUpdate();
            updatingProjectFilters = false;
            ResizeProjectColumns();
            UpdateProjectActionState();
        }

        private void SelectLocalDirectory()
        {
            if (updatingProjectFilters || localDirectoryList.SelectedItems.Count == 0) return;
            HistoryLocalDirectory directory = localDirectoryList.SelectedItems[0].Tag as HistoryLocalDirectory;
            if (directory == null) return;
            selectedCodexProjectId = directory.CodexProjectId;
            projectPathInput.Text = directory.Path;
            string projectName = string.IsNullOrWhiteSpace(directory.CodexProjectName) ? Path.GetFileName(directory.Path.TrimEnd(Path.DirectorySeparatorChar)) : directory.CodexProjectName;
            syncSelectionTitle.Text = directory.Selected ? "已同步：" + projectName : projectName;
            syncSelectionPath.Text = directory.RootPaths.Count > 1 ? string.Join("；", directory.RootPaths.ToArray()) : directory.Path;
            if (!directory.Selected && string.IsNullOrWhiteSpace(projectNameInput.Text)) projectNameInput.Text = projectName;
            UpdateProjectActionState();
        }

        private void SelectSharedProject()
        {
            if (updatingProjectFilters || sharedProjectList.SelectedItems.Count == 0) { UpdateProjectActionState(); return; }
            HistoryProjectInfo project = sharedProjectList.SelectedItems[0].Tag as HistoryProjectInfo;
            if (project == null) return;
            SetSyncMode(true);
            if (project.Bound && string.IsNullOrWhiteSpace(projectPathInput.Text))
            {
                projectPathInput.Text = project.LocalPath;
                syncSelectionPath.Text = project.LocalPath;
            }
            if (!string.IsNullOrWhiteSpace(project.CodexProjectId)) selectedCodexProjectId = project.CodexProjectId;
            syncSelectionTitle.Text = project.Bound ? project.Name + " 已连接" : "绑定到 " + project.Name;
            UpdateProjectActionState();
        }

        private void SetSyncMode(bool useBindMode)
        {
            bindMode = useBindMode;
            if (createModeButton == null) return;
            createModeButton.Style = bindMode ? AppButtonStyle.Ghost : AppButtonStyle.Secondary;
            bindModeButton.Style = bindMode ? AppButtonStyle.Secondary : AppButtonStyle.Ghost;
            projectNameInput.Visible = !bindMode;
            projectActionButton.Text = bindMode ? "绑定项目" : "创建项目";
            projectActionButton.IconKind = bindMode ? AppIconKind.Link : AppIconKind.Add;
            UpdateProjectActionState();
        }

        private void UpdateProjectActionState()
        {
            if (projectActionButton == null) return;
            bool hasPath = !string.IsNullOrWhiteSpace(projectPathInput.Text);
            HistoryProjectInfo project = SelectedProject();
            if (bindMode)
            {
                projectActionButton.Enabled = hasPath && project != null && !project.Bound;
                unbindProjectButton.Visible = project != null && project.Bound;
                if (project == null && hasPath) syncSelectionTitle.Text = "再选择一个同步项目";
            }
            else
            {
                projectActionButton.Enabled = hasPath && !string.IsNullOrWhiteSpace(projectNameInput.Text);
                unbindProjectButton.Visible = false;
            }
        }

        private void RunProjectPrimaryAction()
        {
            string path = projectPathInput.Text.Trim();
            if (path.Length == 0) { ShowActionError("请先选择本机 Codex 项目"); return; }
            if (!bindMode)
            {
                string name = projectNameInput.Text.Trim();
                if (name.Length == 0) { ShowActionError("请输入项目名称"); projectNameInput.Focus(); return; }
                createProject(selectedCodexProjectId, path, name);
                return;
            }
            HistoryProjectInfo project = SelectedProject();
            if (project == null) { ShowActionError("请选择要绑定的同步项目"); return; }
            bindProject(project.ProjectId, selectedCodexProjectId, path);
        }

        private HistoryProjectInfo SelectedProject() { return sharedProjectList.SelectedItems.Count == 0 ? null : sharedProjectList.SelectedItems[0].Tag as HistoryProjectInfo; }
        private string SelectedProjectId() { HistoryProjectInfo project = SelectedProject(); return project == null ? null : project.ProjectId; }

        private void UnbindSelectedProject()
        {
            HistoryProjectInfo project = SelectedProject();
            if (project == null || !project.Bound) { ShowActionError("请选择已连接的项目"); return; }
            DialogResult result = MessageBox.Show(this, "停止同步“" + project.Name + "”？\r\n\r\n本机和仓库中的会话都不会被删除。", "停止同步", MessageBoxButtons.OKCancel, MessageBoxIcon.Information, MessageBoxDefaultButton.Button2);
            if (result == DialogResult.OK) unbindProject(project.ProjectId);
        }

        private void ResizeProjectColumns()
        {
            if (localDirectoryList != null && localDirectoryList.Columns.Count == 3)
            {
                int width = Math.Max(1, localDirectoryList.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - ScaleLogical(8));
                localDirectoryList.Columns[1].Width = Math.Min(ScaleLogical(58), Math.Max(ScaleLogical(38), width / 5));
                localDirectoryList.Columns[2].Width = Math.Min(ScaleLogical(74), Math.Max(ScaleLogical(62), width / 3));
                localDirectoryList.Columns[0].Width = Math.Max(1, width - localDirectoryList.Columns[1].Width - localDirectoryList.Columns[2].Width);
            }
            if (sharedProjectList != null && sharedProjectList.Columns.Count == 3)
            {
                int width = Math.Max(1, sharedProjectList.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - ScaleLogical(8));
                sharedProjectList.Columns[1].Width = Math.Min(ScaleLogical(58), Math.Max(ScaleLogical(38), width / 5));
                sharedProjectList.Columns[2].Width = Math.Min(ScaleLogical(82), Math.Max(ScaleLogical(62), width / 3));
                sharedProjectList.Columns[0].Width = Math.Max(1, width - sharedProjectList.Columns[1].Width - sharedProjectList.Columns[2].Width);
            }
        }

        private void LayoutProjectActionCard(Control card)
        {
            projectActionButton.Left = card.ClientSize.Width - projectActionButton.Width - 18;
            unbindProjectButton.Left = projectActionButton.Left - unbindProjectButton.Width - 8;
            int actionLeft = unbindProjectButton.Visible ? unbindProjectButton.Left : projectActionButton.Left;
            syncSelectionTitle.Width = Math.Max(150, actionLeft - syncSelectionTitle.Left - 16);
            syncSelectionPath.Width = syncSelectionTitle.Width;
            projectNameInput.Width = Math.Max(150, Math.Min(280, actionLeft - projectNameInput.Left - 16));
        }

        private void ToggleSyncDetails()
        {
            syncDetailsVisible = !syncDetailsVisible;
            syncDetailsPanel.Visible = syncDetailsVisible;
            ApplySyncLayout();
        }

        internal void ShowActionSuccess(string message) { SetAction(message, Ui.Success, Ui.SuccessSoft, true); }
        internal void ShowActionError(string message) { SetAction(message, Ui.Danger, Ui.DangerSoft, false); }
        private void ShowActionInfo(string message) { SetAction(message, Ui.Accent, Ui.AccentSoft, false); }

        private void SetAction(string message, Color color, Color background, bool autoHide)
        {
            toastTimer.Stop();
            actionMessage.Text = message;
            actionMessage.ForeColor = color;
            actionBanner.BackColor = background;
            actionBanner.Visible = true;
            if (autoHide) toastTimer.Start();
        }

        private void HideAction() { toastTimer.Stop(); actionBanner.Visible = false; }

        private static string SessionDirectory(HistoryVaultEntry entry)
        {
            if (!string.IsNullOrWhiteSpace(entry.LocalWorkingDirectory)) return entry.LocalWorkingDirectory;
            if (!string.IsNullOrWhiteSpace(entry.WorkingDirectory)) return entry.WorkingDirectory;
            return "未识别目录";
        }

        private static string SessionProjectName(HistoryVaultEntry entry)
        {
            if (!string.IsNullOrWhiteSpace(entry.ProjectName)) return entry.ProjectName;
            string directory = SessionDirectory(entry);
            try { string value = Path.GetFileName(directory.TrimEnd(Path.DirectorySeparatorChar)); return string.IsNullOrWhiteSpace(value) ? directory : value; }
            catch { return directory; }
        }

        private static string FriendlyTime(DateTime value)
        {
            if (value == DateTime.MinValue) return "未知";
            DateTime local = value.ToLocalTime();
            DateTime today = DateTime.Today;
            if (local.Date == today) return "今天 " + local.ToString("HH:mm");
            if (local.Date == today.AddDays(-1)) return "昨天 " + local.ToString("HH:mm");
            if (local.Year == today.Year) return local.ToString("MM-dd HH:mm");
            return local.ToString("yyyy-MM-dd");
        }

        private static string LastSyncSuffix(HistorySyncStatus status)
        {
            if (string.IsNullOrWhiteSpace(status.LastSyncUtc)) return "";
            DateTime parsed;
            if (!DateTime.TryParse(status.LastSyncUtc, out parsed)) return "";
            bool successful = string.Equals(status.LastSyncOutcome, "Succeeded", StringComparison.OrdinalIgnoreCase) || string.Equals(status.LastSyncOutcome, "LiveSnapshot", StringComparison.OrdinalIgnoreCase);
            return " · " + parsed.ToLocalTime().ToString("HH:mm") + (successful ? " 完成" : " 失败");
        }

        private static string FormatBytes(long bytes)
        {
            if (bytes >= 1024L * 1024L) return (bytes / (1024D * 1024D)).ToString("0.0", CultureInfo.CurrentCulture) + " MB";
            if (bytes >= 1024L) return (bytes / 1024D).ToString("0.0", CultureInfo.CurrentCulture) + " KB";
            return bytes.ToString(CultureInfo.CurrentCulture) + " B";
        }

        private static string RemovePrefix(string value, string prefix)
        {
            if (string.IsNullOrWhiteSpace(value)) return "未知";
            return value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ? value.Substring(prefix.Length) : value;
        }

        private static string FormatMetricText(string value)
        {
            return value.Replace(" · ", Environment.NewLine);
        }
    }
}
