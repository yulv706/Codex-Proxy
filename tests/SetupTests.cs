using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CodexProxyDesktop;

namespace CodexProxySetup.Tests
{
    internal sealed class FakeInstaller : IInstallerRuntime
    {
        internal InstallationDetectionResult Detection = new InstallationDetectionResult { Found = false, Errors = new string[0] };
        internal bool Fail;
        internal int Calls, Launches;
        internal ManualResetEvent Gate;
        public InstallationDetectionResult Detect() { return Detection; }
        public ProcessResult Install(string directory, bool desktopShortcut, bool startMenuShortcut) { Interlocked.Increment(ref Calls); if (Gate != null) Gate.WaitOne(5000); return new ProcessResult(Fail ? 1 : 0, "", Fail ? "fixture install failure" : ""); }
        public void Launch(string directory) { Launches++; }
        public void Dispose() { }
    }
    internal static class Program
    {
        private static string output;
        [STAThread]
        private static void Main(string[] args)
        {
            output = Path.GetFullPath(args[0]); Directory.CreateDirectory(output);
            Environment.SetEnvironmentVariable("CODEX_PROXY_DATA_DIRECTORY", Path.Combine(output, "isolated-data"));
            Application app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            app.Startup += async delegate
            {
                try { await Run(); File.WriteAllText(Path.Combine(output, "result.txt"), "PASS: WPF setup, upgrade directory lock, validation, installation concurrency, errors, completion and shared themes."); app.Shutdown(0); }
                catch (Exception ex) { File.WriteAllText(Path.Combine(output, "error.txt"), ex.ToString()); app.Shutdown(1); }
            }; app.Run();
        }
        private static void Assert(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
        private static async Task Run()
        {
            Ui.Initialize(); Ui.AnimationsEnabled = false;
            FakeInstaller fake = new FakeInstaller();
            using (SetupViewModel model = new SetupViewModel(fake))
            {
                Assert(!model.CanInstall, "Installation must wait for detection.");
                await model.DetectAsync();
                model.InstallDirectory = "relative-path"; Assert(model.PathError.Length > 0 && !model.CanInstall, "Relative paths must be rejected.");
                model.InstallDirectory = "C:\\"; Assert(model.PathError.Length > 0, "Drive roots must be rejected.");
                model.InstallDirectory = "C:\\Apps\\CodexProxy"; Assert(model.CanInstall && model.CanBrowse, "A valid fresh installation should be configurable.");
                fake.Detection = new InstallationDetectionResult { Found = true, InstallDirectory = "D:\\install\\CodexProxy", InstalledVersion = "3.5.9.0", Errors = new string[0] };
                await model.DetectAsync(); model.InstallDirectory = "C:\\Elsewhere";
                Assert(model.IsUpgrade && model.InstallDirectory == "D:\\install\\CodexProxy" && !model.CanBrowse, "Upgrade directory must remain locked.");
                SetupWindow window = new SetupWindow(model, false);
                Render(window.View, "light", "options"); Render(window.View, "dark", "options");
                using (ManualResetEvent gate = new ManualResetEvent(false))
                {
                    fake.Gate = gate; model.InstallCommand.Execute(null); model.InstallCommand.Execute(null);
                    await Task.Delay(100);
                    Assert(model.Stage == "installing" && !model.CanClose && fake.Calls == 1, "Concurrent installation was not prevented.");
                    Render(window.View, "light", "installing"); gate.Set();
                    Stopwatch timeout = Stopwatch.StartNew();
                    while (model.Stage == "installing") { if (timeout.Elapsed.TotalSeconds > 5) throw new TimeoutException("Setup did not finish."); await Task.Delay(15); }
                    fake.Gate = null;
                }
                Assert(model.Stage == "complete" && fake.Launches == 1 && model.CanClose, "Successful installation did not finish or launch.");
                Render(window.View, "light", "complete"); Render(window.View, "dark", "complete"); window.View.Close();
            }
            fake = new FakeInstaller { Fail = true };
            using (SetupViewModel model = new SetupViewModel(fake))
            {
                await model.DetectAsync(); await model.InstallAsync();
                Assert(model.Stage == "options" && model.Error.Contains("fixture install failure") && model.CanClose, "Installation errors should remain visible and retryable.");
                fake.Detection = new InstallationDetectionResult { Found = false, Errors = new[] { "fixture detection error" } };
                await model.DetectAsync(); int calls = fake.Calls; await model.InstallAsync();
                Assert(fake.Calls == calls && model.ActionLabel == "重试检测", "Incomplete detection must not start a fresh installation.");
            }
        }
        private static void Render(Window view, string theme, string state)
        {
            Ui.ApplyTheme(theme); view.Measure(new Size(830, 620)); view.Arrange(new Rect(0, 0, 830, 620)); view.UpdateLayout();
            FrameworkElement root = (FrameworkElement)view.Content; root.Measure(new Size(830, 620)); root.Arrange(new Rect(0, 0, 830, 620)); root.UpdateLayout();
            RenderTargetBitmap bitmap = new RenderTargetBitmap(830, 620, 96, 96, PixelFormats.Pbgra32); bitmap.Render(root);
            PngBitmapEncoder encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream file = File.Create(Path.Combine(output, theme + "-setup-" + state + ".png"))) encoder.Save(file);
        }
    }
}
