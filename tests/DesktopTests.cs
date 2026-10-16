using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CodexProxyDesktop.Tests
{
    internal sealed class FakeRuntime : IRuntimeBridge
    {
        internal int Port = 7891, LaunchCalls, SaveCalls, FullChecks;
        internal bool Startup, FailLaunch, Disposed;
        internal ManualResetEvent LaunchGate;
        internal DiagnosticStatus Status = Ready();
        internal static DiagnosticStatus Ready()
        {
            return new DiagnosticStatus { ProxyReady = true, ProxyUrl = "http://127.0.0.1:7891", ProxyProcess = "verge-mihomo", ApplicationInstalled = true, ApplicationReady = true, AppxAvailable = true, ShortcutReady = true, ApplicationVersion = "26.1013.3656.0", RuntimeReadyNow = true, RuntimeReadyAfterExit = true, CheckedAt = DateTime.Now };
        }
        public int ReadSavedPort() { return Port; }
        public void SavePort(int port) { SaveCalls++; Port = port; Status.ProxyUrl = "http://127.0.0.1:" + port; }
        public DiagnosticStatus GetStatus(bool full = false) { if (full) FullChecks++; return Status; }
        internal ApplicationCatalog Catalog = new ApplicationCatalog();
        internal string LastCheckedId, LastLaunchedId;
        public ApplicationCatalog LoadApplications() { return Catalog.Copy(); }
        public void SaveApplications(ApplicationCatalog catalog) { Catalog = catalog.Copy(); }
        public string ApplicationWarning { get { return ""; } }
        public string ResolveExecutable(ApplicationProfile profile) { return profile.ExecutablePath ?? ""; }
        public DiagnosticStatus GetStatus(ApplicationProfile profile, bool full = false) { LastCheckedId = profile.Id; return GetStatus(full); }
        public LaunchResult LaunchApplication(ApplicationProfile profile) { LastLaunchedId = profile.Id; return LaunchCodex(); }
        public LaunchResult LaunchCodex() { Interlocked.Increment(ref LaunchCalls); if (LaunchGate != null) LaunchGate.WaitOne(5000); return new LaunchResult(!FailLaunch, FailLaunch ? "模拟启动失败" : "Codex 已启动"); }
        public bool IsStartupEnabled() { return Startup; }
        public void SetStartup(bool enabled) { Startup = enabled; }
        public void OpenLogDirectory() { }
        public void Dispose() { Disposed = true; if (LaunchGate != null) LaunchGate.Set(); }
    }
    internal sealed class BindingErrors : TraceListener
    {
        internal readonly List<string> Messages = new List<string>();
        public override void Write(string message) { }
        public override void WriteLine(string message) { if (!string.IsNullOrWhiteSpace(message)) Messages.Add(message); }
    }
    internal static class Program
    {
        private static string output;
        [STAThread]
        private static void Main(string[] args)
        {
            int fixture = Array.IndexOf(args, "--proxy-fixture");
            if (fixture >= 0) { MultiApplicationTests.Fixture(args, fixture); return; }
            output = Path.GetFullPath(args[0]); Directory.CreateDirectory(output);
            Environment.SetEnvironmentVariable("CODEX_PROXY_DATA_DIRECTORY", Path.Combine(output, "isolated-data"));
            Application app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            app.Startup += async delegate
            {
                try { await Run(); File.WriteAllText(Path.Combine(output, "result.txt"), "PASS: WPF bindings, multi-application adapters, isolated launches, arguments, proxy environments, concurrency, preferences, logs and visual states."); app.Shutdown(0); }
                catch (Exception ex) { File.WriteAllText(Path.Combine(output, "error.txt"), ex.ToString()); app.Shutdown(1); }
            };
            app.Run();
        }
        private static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        private static async Task Until(Func<bool> condition)
        {
            Stopwatch timer = Stopwatch.StartNew();
            while (!condition()) { if (timer.Elapsed.TotalSeconds > 10) throw new TimeoutException("An asynchronous desktop operation did not finish."); await Task.Delay(15); }
        }
        private static async Task Run()
        {
            Ui.AnimationsEnabled = false; Ui.Initialize();
            BindingErrors bindingErrors = new BindingErrors();
            PresentationTraceSources.DataBindingSource.Listeners.Add(bindingErrors);
            PresentationTraceSources.DataBindingSource.Switch.Level = SourceLevels.Error;
            string data = Path.Combine(output, "unit-data"); Directory.CreateDirectory(data);
            FakeRuntime fake = new FakeRuntime();
            PreferencesStore store = new PreferencesStore(Path.Combine(data, "preferences.json"));
            using (WorkspaceViewModel model = new WorkspaceViewModel(fake, store, Path.Combine(data, "logs")))
            using (MainWindow window = new MainWindow(model))
            {
                window.View.ShowInTaskbar = false; window.View.ShowActivated = false; window.View.Left = -15000; window.View.Top = 0; window.View.Show();
                await model.RefreshAsync(false);
                Assert(model.CanLaunch, "Ready status should enable launch.");
                Layout(window, 1100, 800);
                foreach (string old in new[] { "sessions", "sync", "projects" }) { model.Navigate(old); Assert(model.SelectedPage == "overview", "A retired page can still be opened."); }
                foreach (TextBlock text in Visuals(window.View.Content as DependencyObject).OfType<TextBlock>()) Assert(!text.Text.Contains("历史") && !text.Text.Contains("同步"), "A retired history control remains.");
                window.Find<RadioButton>("SettingsNav").Command.Execute("settings");
                Assert(model.SelectedPage == "settings", "Settings navigation is not bound.");
                TextBox input = window.Find<TextBox>("PortInput");
                input.Text = "70000"; input.GetBindingExpression(TextBox.TextProperty).UpdateSource();
                Assert(model.PortError.Length > 0 && !model.SavePortCommand.CanExecute(null), "Invalid ports must not be saved.");
                input.Text = "9001"; input.GetBindingExpression(TextBox.TextProperty).UpdateSource();
                Assert(model.SavePortCommand.CanExecute(null), "A valid changed port should be saveable.");
                window.Find<Button>("SavePortButton").Command.Execute(null);
                await Until(() => !model.IsWorking && fake.SaveCalls == 1);
                Assert(fake.Port == 9001 && model.ProxyEndpoint.EndsWith(":9001"), "Saved port was not applied to status.");
                model.StartupEnabled = true; Assert(fake.Startup, "Startup control is not bound.");
                model.CloseToTray = false; model.AutoRefresh = false; model.SidebarCollapsed = true; model.SetTheme("dark");
                DesktopPreferences restored = store.Load();
                Assert(restored.Theme == "dark" && !restored.CloseToTray && !restored.AutoRefresh && restored.SidebarCollapsed, "Preferences did not persist.");
                model.SidebarCollapsed = false; model.AutoRefresh = true; model.CloseToTray = true; model.SetTheme("light");
                using (ManualResetEvent gate = new ManualResetEvent(false))
                {
                    fake.LaunchGate = gate;
                    model.LaunchCommand.Execute(null); model.LaunchCommand.Execute(null);
                    await Until(() => fake.LaunchCalls == 1);
                    Assert(model.IsLaunching && !model.CanLaunch && !model.LaunchCommand.CanExecute(null), "Concurrent launch was not blocked.");
                    gate.Set(); await Until(() => !model.IsLaunching);
                    Assert(fake.LaunchCalls == 1 && model.ToastKind == "success", "Launch did not finish correctly."); fake.LaunchGate = null;
                }
                fake.FailLaunch = true; await model.LaunchAsync(); Assert(model.ToastKind == "error" && model.Toast.Contains("模拟启动失败"), "Launch failure is not visible.");
                fake.FailLaunch = false;
                await model.RefreshAsync(true); Assert(fake.FullChecks == 1, "Full diagnostics did not reach the runtime.");
                WriteLogs(Path.Combine(data, "logs")); await model.LoadLogsAsync();
                Assert(model.Logs.Count == 500, "Log entries should be bounded to 500.");
                model.Level = "ERROR"; Assert(model.LogsView.Cast<LogEntry>().All(entry => entry.Level == "ERROR"), "Log level filter failed.");
                model.Search = "check-598"; Assert(model.LogsView.Cast<LogEntry>().Count() == 1, "Log search failed.");
                Assert(model.ExportLogs().Contains("check-598") && !model.ExportLogs().Contains("check-597"), "Export did not respect filters.");
                model.Search = ""; model.Level = "全部";
                model.PortText = "7891"; await model.SavePortAsync();
                foreach (string theme in new[] { "light", "dark" })
                {
                    model.SetTheme(theme); model.DismissToast();
                    if (!SystemParameters.HighContrast)
                        foreach (string pair in new[] { "OnAccent/Accent", "OnAccent/AccentHover", "Secondary/Canvas", "Muted/Canvas", "Secondary/Surface", "Muted/Surface", "Success/SuccessSoft", "Danger/DangerSoft" })
                        {
                            string[] tokens = pair.Split('/');
                            double first = Luminance(((SolidColorBrush)Application.Current.FindResource(tokens[0])).Color);
                            double second = Luminance(((SolidColorBrush)Application.Current.FindResource(tokens[1])).Color);
                            double ratio = (Math.Max(first, second) + 0.05) / (Math.Min(first, second) + 0.05);
                            Assert(ratio >= 4.5, theme + " theme text contrast is too low: " + pair + " (" + ratio + ")");
                        }
                    foreach (int width in new[] { 1100, 820 })
                        foreach (string page in new[] { "overview", "applications", "diagnostics", "logs", "settings" })
                        {
                            model.Navigate(page); await Task.Delay(20); Render(window, width, width == 1100 ? 800 : 650, theme + "-" + width + "-" + page);
                        }
                    model.Navigate("overview"); await Task.Delay(20);
                    Render(window, 1100, 800, theme + "-150dpi-overview", 144);
                }
                fake.Status = DiagnosticStatus.FromError("PROXY_NOT_LISTENING", "本地代理端口未监听"); fake.Status.Remediation = "请先启动代理客户端，确认 HTTP / Mixed 端口与这里保存的端口一致。";
                model.ApplyStatus(fake.Status, 0.2); model.Navigate("overview"); model.SetTheme("light"); model.DismissToast();
                await Task.Delay(25);
                Render(window, 1100, 800, "light-error-overview"); Assert(!model.CanLaunch && !window.Find<Button>("LaunchButton").IsEnabled, "An unavailable proxy should disable launch.");
                Assert(bindingErrors.Messages.Count == 0, "WPF binding errors: " + string.Join(Environment.NewLine, bindingErrors.Messages));
                await MultiApplicationTests.VerifyWorkspace(model, window, fake, (name) => Render(window, 1100, 800, name), output);
                Assert(bindingErrors.Messages.Count == 0, "Multi-application binding errors: " + string.Join(Environment.NewLine, bindingErrors.Messages));
                window.View.Close();
            }
            Assert(fake.Disposed, "The runtime service was not disposed.");
            File.WriteAllText(Path.Combine(data, "preferences.json"), "broken json");
            Assert(store.Load().Theme == "system" && store.ReadWarning != null, "Corrupt preferences should fall back with a warning.");
            Assert(File.ReadAllText(Path.Combine(data, "preferences.json")) == "broken json", "Loading corrupt preferences must not overwrite them.");
            using (WorkspaceViewModel failing = new WorkspaceViewModel(new FakeRuntime(), new PreferencesStore(data), Path.Combine(data, "logs")))
            {
                failing.SetTheme("dark"); Assert(failing.Theme == "system" && failing.ToastKind == "error", "Failed preference writes should not change the effective setting.");
            }
            await VerifyBridge(Path.Combine(data, "bridge"));
            await MultiApplicationTests.VerifyRuntime(Path.Combine(data, "applications"));
            PresentationTraceSources.DataBindingSource.Listeners.Remove(bindingErrors);
        }
        private static void WriteLogs(string directory)
        {
            Directory.CreateDirectory(directory); StringBuilder text = new StringBuilder();
            for (int i = 0; i < 600; i++) text.Append(DateTime.Today.AddSeconds(i).ToString("yyyy-MM-dd HH:mm:ss.fff")).Append(i % 2 == 0 ? " [ERROR] " : " [INFO] ").Append("check-").Append(i).Append(' ', 950).AppendLine();
            File.WriteAllText(Path.Combine(directory, "launcher.log"), text.ToString(), new UTF8Encoding(false));
        }
        private static double Luminance(Color color)
        {
            Func<byte, double> linear = value => { double normalized = value / 255.0; return normalized <= 0.04045 ? normalized / 12.92 : Math.Pow((normalized + 0.055) / 1.055, 2.4); };
            return 0.2126 * linear(color.R) + 0.7152 * linear(color.G) + 0.0722 * linear(color.B);
        }
        private static void Layout(MainWindow window, int width, int height)
        {
            window.View.Width = width; window.View.Height = height;
            window.UpdateLayoutMode();
            window.View.Measure(new Size(width, height)); window.View.Arrange(new Rect(0, 0, width, height)); window.View.UpdateLayout();
            FrameworkElement root = (FrameworkElement)window.View.Content;
            root.Measure(new Size(width, height)); root.Arrange(new Rect(0, 0, width, height)); root.UpdateLayout();
        }
        private static void Render(MainWindow window, int width, int height, string name, int dpi = 96)
        {
            Layout(window, width, height);
            FrameworkElement root = (FrameworkElement)window.View.Content;
            foreach (TextBox input in VisibleVisuals(root).OfType<TextBox>()) VerifyTextViewport(input);
            foreach (TextBlock text in VisibleVisuals(root).OfType<TextBlock>())
            {
                if (string.IsNullOrWhiteSpace(text.Text) || text.TextWrapping != TextWrapping.NoWrap || text.TextTrimming != TextTrimming.None || text.ActualWidth == 0) continue;
                FormattedText measured = new FormattedText(text.Text, System.Globalization.CultureInfo.CurrentCulture, text.FlowDirection,
                    new Typeface(text.FontFamily, text.FontStyle, text.FontWeight, text.FontStretch), text.FontSize, Brushes.Black, 1.0);
                Assert(measured.Width <= text.ActualWidth + 2, "Text is clipped at " + width + " on " + name + ": " + text.Text + " (" + measured.Width + " > " + text.ActualWidth + ")");
            }
            foreach (ScrollViewer scroll in VisibleVisuals(root).OfType<ScrollViewer>()) Assert(scroll.ComputedHorizontalScrollBarVisibility != Visibility.Visible, "An unexpected horizontal scrollbar is visible.");
            RenderTargetBitmap bitmap = new RenderTargetBitmap(width * dpi / 96, height * dpi / 96, dpi, dpi, PixelFormats.Pbgra32); bitmap.Render(root);
            PngBitmapEncoder encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream file = File.Create(Path.Combine(output, name + ".png"))) encoder.Save(file);
            Assert(root.ActualWidth > 0 && root.ActualHeight > 0, "The rendered window has no layout.");
        }
        internal static void VerifyTextViewport(TextBox input)
        {
            ScrollViewer host = input.Template.FindName("PART_ContentHost", input) as ScrollViewer;
            Assert(host != null && host.ActualHeight >= input.FontSize * 1.2 + input.Padding.Top + input.Padding.Bottom, "Text input has insufficient space to display its content: " + input.Name);
        }
        private static IEnumerable<DependencyObject> Visuals(DependencyObject root)
        {
            if (root == null) yield break;
            yield return root;
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (DependencyObject child in Visuals(VisualTreeHelper.GetChild(root, i))) yield return child;
        }
        private static IEnumerable<DependencyObject> VisibleVisuals(DependencyObject root)
        {
            if (root == null || root is UIElement && ((UIElement)root).Visibility != Visibility.Visible) yield break;
            yield return root;
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (DependencyObject child in VisibleVisuals(VisualTreeHelper.GetChild(root, i))) yield return child;
        }
        private static async Task VerifyBridge(string root)
        {
            Directory.CreateDirectory(root);
            File.WriteAllText(Path.Combine(root, "CodexProxy.user.psd1"), "@{\r\n    ProxyHost = 'localhost'\r\n    ProxyPort = 8123\r\n}\r\n");
            File.WriteAllText(Path.Combine(root, "Test-CodexProxy.ps1"), "param([switch]$Json,[switch]$Monitor,[int]$ProxyPort)\r\n[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'diagnostic-port.txt'),[string]$ProxyPort)\r\n'{\"ProxyReady\":true,\"RuntimeReadyNow\":true,\"CodexInstalled\":true,\"CodexApplicationReady\":true}'\r\n");
            string launcher = Path.Combine(root, "Start-CodexProxy.ps1");
            File.WriteAllText(launcher, "param([switch]$NoUI,[int]$ProxyPort)\r\n[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'launch-port.txt'),[string]$ProxyPort)\r\nif (-not $NoUI) { exit 19 }\r\nexit 0\r\n");
            using (RuntimeBridge bridge = new RuntimeBridge(root))
            {
                bridge.SavePort(9001); Assert(bridge.ReadSavedPort() == 9001 && File.ReadAllText(Path.Combine(root, "CodexProxy.user.psd1")).Contains("ProxyHost = 'localhost'"), "Port persistence lost another configuration value.");
                DiagnosticStatus status = await Task.Run(() => bridge.GetStatus()); Assert(status.RuntimeReadyNow && status.ApplicationReady, "Diagnostic protocol failed.");
                Assert((await Task.Run(() => bridge.LaunchCodex())).Success, "Proxy launch protocol failed.");
                ApplicationProfile codex = ApplicationProfile.Defaults()[0]; codex.ProxyPort = 8777;
                Assert((await Task.Run(() => bridge.GetStatus(codex))).RuntimeReadyNow && File.ReadAllText(Path.Combine(root, "diagnostic-port.txt")) == "8777", "Codex independent diagnostic port was not forwarded.");
                Assert((await Task.Run(() => bridge.LaunchApplication(codex))).Success && File.ReadAllText(Path.Combine(root, "launch-port.txt")) == "8777" && bridge.ReadSavedPort() == 9001, "Codex independent launch port changed or bypassed the global configuration.");
                File.WriteAllText(launcher, "param([switch]$NoUI)\r\n[Console]::Error.WriteLine('fixture launch failure')\r\nexit 17\r\n");
                LaunchResult result = await Task.Run(() => bridge.LaunchCodex()); Assert(!result.Success && result.Message.Contains("fixture launch failure"), "Launch failure protocol failed.");
            }
        }
    }
}
