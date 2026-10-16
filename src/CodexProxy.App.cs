using System;
using System.ComponentModel;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Threading;
using Forms = System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Codex Proxy")]
[assembly: System.Reflection.AssemblyDescription("Codex、Cursor、Grok Bot 多应用本地代理启动与连接管理")]
[assembly: System.Reflection.AssemblyCompany("Codex Proxy Community")]
[assembly: System.Reflection.AssemblyProduct("Codex Proxy")]
[assembly: System.Reflection.AssemblyVersion("4.1.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("4.1.0.0")]

namespace CodexProxyDesktop
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            try
            {
                if (Has(args, "--self-test-powershell") || Has(args, "--self-test-process-cleanup"))
                {
                    using (RuntimeBridge bridge = new RuntimeBridge(AppDomain.CurrentDomain.BaseDirectory))
                        Environment.ExitCode = (Has(args, "--self-test-powershell") ? bridge.HasPowerShellDataFileCommand() : bridge.VerifyOutstandingProcessCleanup()) ? 0 : 1;
                    return;
                }
                if (Has(args, "--self-test-ui"))
                {
                    new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                    Ui.AnimationsEnabled = false;
                    using (WorkspaceViewModel model = new WorkspaceViewModel(new RuntimeBridge(AppDomain.CurrentDomain.BaseDirectory), new PreferencesStore(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".json")), Path.GetTempPath()))
                    using (MainWindow window = new MainWindow(model))
                    {
                        foreach (string page in new[] { "overview", "applications", "diagnostics", "logs", "settings" }) { model.Navigate(page); window.View.Measure(new System.Windows.Size(1100, 760)); window.View.Arrange(new Rect(0, 0, 1100, 760)); window.View.UpdateLayout(); }
                        window.View.Close();
                    }
                    return;
                }
                string suffix = Suffix(args);
                bool background = Has(args, "--background") || Has(args, "/background");
                bool created;
                using (Mutex mutex = new Mutex(true, "Local\\CodexProxy.Tray.Instance" + suffix, out created))
                {
                    if (!created) { if (!background) Signal("Local\\CodexProxy.Tray.Show" + suffix); return; }
                    Application app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                    using (EventWaitHandle show = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\CodexProxy.Tray.Show" + suffix))
                    using (EventWaitHandle exit = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\CodexProxy.Tray.Exit" + suffix))
                    using (DesktopHost host = new DesktopHost(app, background))
                    {
                        RegisteredWaitHandle showWait = ThreadPool.RegisterWaitForSingleObject(show, delegate { app.Dispatcher.BeginInvoke(new Action(host.Show)); }, null, Timeout.Infinite, false);
                        RegisteredWaitHandle exitWait = ThreadPool.RegisterWaitForSingleObject(exit, delegate { app.Dispatcher.BeginInvoke(new Action(host.Exit)); }, null, Timeout.Infinite, false);
                        try { app.Run(); }
                        finally { showWait.Unregister(null); exitWait.Unregister(null); }
                    }
                }
            }
            catch (Exception ex)
            {
                Environment.ExitCode = 1;
                try { LogStore.Append(Path.Combine(Product.DataDirectory, "logs"), "ERROR", ex.ToString()); File.WriteAllText(Path.Combine(Path.GetTempPath(), "CodexProxy-ui-selftest.log"), ex.ToString()); } catch { }
                if (!Has(args, "--self-test-ui")) MessageBox.Show("Codex Proxy 无法打开。\n" + ex.Message + "\n请查看本地日志，或重新运行安装包修复。", "Codex Proxy", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }
        private static bool Has(string[] args, string value) { return Array.Exists(args, arg => string.Equals(arg, value, StringComparison.OrdinalIgnoreCase)); }
        private static string Suffix(string[] args)
        {
            foreach (string arg in args)
            {
                if (!arg.StartsWith("--instance-suffix=", StringComparison.OrdinalIgnoreCase)) continue;
                string suffix = Regex.Replace(arg.Substring(18), "[^A-Za-z0-9_-]", "");
                return suffix.Length == 0 ? "" : "." + suffix.Substring(0, Math.Min(40, suffix.Length));
            }
            return "";
        }
        private static void Signal(string name) { try { using (EventWaitHandle handle = EventWaitHandle.OpenExisting(name)) handle.Set(); } catch { } }
    }

    internal sealed class DesktopHost : IDisposable
    {
        private readonly Application app;
        private readonly WorkspaceViewModel model;
        private readonly MainWindow window;
        private readonly Forms.NotifyIcon tray;
        private readonly Forms.ContextMenuStrip menu;
        private readonly Forms.ToolStripMenuItem trayStatus;
        private readonly Forms.ToolStripMenuItem trayLaunch;
        private readonly Forms.ToolStripMenuItem trayApplications;
        private readonly DispatcherTimer monitor;
        private Icon icon;
        private bool exiting, closeTipShown, disposed;
        internal DesktopHost(Application application, bool background)
        {
            app = application;
            RuntimeBridge bridge = new RuntimeBridge(AppDomain.CurrentDomain.BaseDirectory);
            model = new WorkspaceViewModel(bridge, new PreferencesStore(Path.Combine(Product.DataDirectory, "desktop-settings.json")), Path.Combine(Product.DataDirectory, "logs"));
            window = new MainWindow(model); app.MainWindow = window.View;
            window.View.Closing += OnClosing;
            model.ExitRequested += delegate { Exit(); };
            model.PropertyChanged += OnModelStateChanged;
            app.DispatcherUnhandledException += OnUnexpectedError;
            menu = new Forms.ContextMenuStrip { ShowImageMargin = false };
            trayStatus = new Forms.ToolStripMenuItem("正在检查连接…") { Enabled = false };
            menu.Items.Add(trayStatus); menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("打开 Codex Proxy", null, delegate { Show(); });
            trayLaunch = new Forms.ToolStripMenuItem(model.LaunchLabel, null, delegate { model.LaunchCommand.Execute(null); }); menu.Items.Add(trayLaunch);
            trayApplications = new Forms.ToolStripMenuItem("切换应用"); menu.Items.Add(trayApplications);
            menu.Items.Add("应用管理", null, delegate { model.Navigate("applications"); Show(); });
            menu.Items.Add("重新检测", null, delegate { model.RefreshCommand.Execute(null); });
            menu.Items.Add(new Forms.ToolStripSeparator());
            menu.Items.Add("运行诊断", null, delegate { model.Navigate("diagnostics"); Show(); });
            menu.Items.Add("运行日志", null, delegate { model.Navigate("logs"); Show(); });
            menu.Items.Add("设置", null, delegate { model.Navigate("settings"); Show(); });
            menu.Items.Add(new Forms.ToolStripSeparator()); menu.Items.Add("退出 Codex Proxy", null, delegate { Exit(); });
            menu.Opening += delegate {
                trayLaunch.Enabled = model.CanLaunch; trayLaunch.Text = model.LaunchLabel;
                while (trayApplications.DropDownItems.Count > 0) { Forms.ToolStripItem item = trayApplications.DropDownItems[0]; trayApplications.DropDownItems.RemoveAt(0); item.Dispose(); }
                foreach (ApplicationProfile profile in model.Applications)
                {
                    ApplicationProfile target = profile;
                    trayApplications.DropDownItems.Add(new Forms.ToolStripMenuItem(profile.Name, null, delegate { model.SelectedApplication = target; }) { Checked = profile.Id == model.SelectedApplication.Id, Enabled = model.CanChangeApplication });
                }
            };
            tray = new Forms.NotifyIcon { Text = "Codex Proxy · 正在检查连接", ContextMenuStrip = menu };
            tray.DoubleClick += delegate { Show(); };
            SetIcon(Color.FromArgb(120, 130, 150)); tray.Visible = true;
            Ui.ThemeChanged += OnThemeChanged; ApplyTrayTheme();
            monitor = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
            monitor.Tick += async delegate { if (model.AutoRefresh) await model.RefreshAsync(false); };
            monitor.Start();
            if (!background) Show();
            app.Dispatcher.BeginInvoke(new Action(async () => await model.RefreshAsync(false)), DispatcherPriority.Background);
            LogStore.Append(model.LogDirectory, "INFO", "Codex Proxy " + Product.Version + " 已启动。");
        }
        internal void Show()
        {
            if (exiting) return;
            window.View.Show(); if (window.View.WindowState == WindowState.Minimized) window.View.WindowState = WindowState.Normal;
            window.View.Activate();
        }
        internal void Exit()
        {
            if (exiting) return;
            exiting = true; monitor.Stop();
            if (window.View.WindowState == WindowState.Normal) model.SaveWindowSize(window.View.Width, window.View.Height);
            model.Dispose(); tray.Visible = false; window.View.Close(); app.Shutdown();
        }
        private void OnClosing(object sender, CancelEventArgs e)
        {
            if (exiting) return;
            if (!model.CloseToTray) { e.Cancel = true; app.Dispatcher.BeginInvoke(new Action(Exit)); return; }
            e.Cancel = true;
            if (window.View.WindowState == WindowState.Normal) model.SaveWindowSize(window.View.Width, window.View.Height);
            window.View.Hide();
            if (!closeTipShown) { closeTipShown = true; tray.ShowBalloonTip(2200, "Codex Proxy 正在后台运行", "双击托盘图标可重新打开。", Forms.ToolTipIcon.Info); }
        }
        private void OnStatusChanged(object sender, EventArgs e)
        {
            trayStatus.Text = model.ApplicationName + " · " + model.StatusBadge + " · " + model.ProxyState;
            string text = "Codex Proxy · " + trayStatus.Text; tray.Text = text.Length > 63 ? text.Substring(0, 63) : text;
            trayLaunch.Enabled = model.CanLaunch;
            trayLaunch.Text = model.LaunchLabel;
            SetIcon(model.StatusKind == "success" ? Color.FromArgb(34, 180, 100) : model.StatusKind == "error" ? Color.FromArgb(230, 80, 80) : Color.FromArgb(120, 130, 150));
        }
        private void OnModelStateChanged(object sender, PropertyChangedEventArgs e) { if (string.IsNullOrEmpty(e.PropertyName)) OnStatusChanged(sender, EventArgs.Empty); }
        private void SetIcon(Color state)
        {
            using (Bitmap bitmap = new Bitmap(32, 32))
            using (Graphics graphics = Graphics.FromImage(bitmap))
            {
                graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                graphics.Clear(Color.Transparent);
                using (Brush background = new SolidBrush(Color.FromArgb(37, 99, 235))) graphics.FillEllipse(background, 1, 1, 29, 29);
                using (Pen mark = new Pen(Color.White, 3)) graphics.DrawArc(mark, 8, 8, 14, 14, 45, 270);
                using (Brush rim = new SolidBrush(Color.White)) graphics.FillEllipse(rim, 20, 20, 12, 12);
                using (Brush dot = new SolidBrush(state)) graphics.FillEllipse(dot, 22, 22, 8, 8);
                IntPtr handle = bitmap.GetHicon();
                Icon next;
                try { using (Icon native = Icon.FromHandle(handle)) next = (Icon)native.Clone(); }
                finally { DestroyIcon(handle); }
                tray.Icon = next; if (icon != null) icon.Dispose(); icon = next;
            }
        }
        private void ApplyTrayTheme()
        {
            if (SystemParameters.HighContrast)
            {
                menu.Renderer = new Forms.ToolStripSystemRenderer();
                menu.BackColor = System.Drawing.SystemColors.Menu;
                menu.ForeColor = System.Drawing.SystemColors.MenuText;
                return;
            }
            menu.Renderer = new Forms.ToolStripProfessionalRenderer(new TrayColors(Ui.IsDark));
            menu.BackColor = Ui.IsDark ? Color.FromArgb(34, 36, 42) : Color.White;
            menu.ForeColor = Ui.IsDark ? Color.FromArgb(231, 233, 239) : Color.FromArgb(32, 34, 40);
        }
        private void OnThemeChanged(object sender, EventArgs e) { ApplyTrayTheme(); }
        private void OnUnexpectedError(object sender, DispatcherUnhandledExceptionEventArgs e) { e.Handled = true; model.ShowToast("操作未完成：" + e.Exception.Message, "error"); }
        public void Dispose()
        {
            if (disposed) return; disposed = true;
            monitor.Stop(); model.Dispose(); window.Dispose(); Ui.ThemeChanged -= OnThemeChanged;
            app.DispatcherUnhandledException -= OnUnexpectedError;
            model.PropertyChanged -= OnModelStateChanged;
            tray.Dispose(); menu.Dispose(); if (icon != null) icon.Dispose();
        }
        [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr handle);
    }
    internal sealed class TrayColors : Forms.ProfessionalColorTable
    {
        private readonly bool dark;
        internal TrayColors(bool isDark) { dark = isDark; UseSystemColors = false; }
        private Color Surface { get { return dark ? Color.FromArgb(34, 36, 42) : Color.White; } }
        public override Color ToolStripDropDownBackground { get { return Surface; } }
        public override Color ImageMarginGradientBegin { get { return Surface; } }
        public override Color ImageMarginGradientMiddle { get { return Surface; } }
        public override Color ImageMarginGradientEnd { get { return Surface; } }
        public override Color MenuItemSelected { get { return dark ? Color.FromArgb(49, 52, 61) : Color.FromArgb(235, 242, 255); } }
        public override Color MenuItemBorder { get { return MenuItemSelected; } }
        public override Color MenuBorder { get { return dark ? Color.FromArgb(54, 57, 67) : Color.FromArgb(228, 229, 235); } }
    }
}
