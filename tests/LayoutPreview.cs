using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace LayoutPreview
{
    internal static class Program
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [STAThread]
        private static void Main(string[] args)
        {
            if (args.Length != 1) throw new ArgumentException("Output directory required.");
            SetProcessDPIAware();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Directory.CreateDirectory(args[0]);
            using (CodexProxyDesktop.MainWindow window = new CodexProxyDesktop.MainWindow(7891,
                delegate(int unused) { }, delegate { }, delegate { }, delegate { }, delegate(bool unused) { },
                delegate { }, delegate { }, delegate(bool unused) { }, delegate(bool unused) { }, delegate(bool unused) { },
                delegate { }, delegate { }, delegate { },
                delegate(string unusedId, string unusedPath, string unusedName) { },
                delegate(string unusedId, string unusedCodexId, string unusedPath) { }, delegate(string unusedId) { }))
            {
                window.Show();
                window.ApplyStatus(new CodexProxyDesktop.DiagnosticStatus
                {
                    ProxyReady = true, ProxyUrl = "http://127.0.0.1:7891", CodexInstalled = true,
                    CodexRunning = true, RuntimeReadyNow = true, CodexVersion = "26.917.6896.0",
                    ReportedUpdateVersion = "26.917.8451.0", UpdatePending = true,
                    CheckedAt = DateTime.Now, Title = "Codex 正在运行"
                });
                foreach (string page in new[] { "overview", "settings", "sessions", "sync" })
                {
                    window.ShowPage(page);
                    Application.DoEvents();
                    if (page == "overview") window.VerifyOverviewTextLayout();
                    if (page == "settings" && window.SettingsHorizontalOverflow) throw new InvalidOperationException("Settings page has a horizontal scrollbar: " + window.SettingsScrollDiagnostics);
                    if (page == "sessions" && !window.SessionColumnsFit) throw new InvalidOperationException("Session columns overflow the list.");
                    if (page == "sync" && !window.ProjectColumnsFit) throw new InvalidOperationException("Project columns overflow the lists: " + window.ProjectColumnDiagnostics);
                    if (page == "sync") File.WriteAllText(Path.Combine(args[0], "sync-layout.txt"), window.ProjectColumnDiagnostics + "; fit=" + window.ProjectColumnsFit);
                    if (page == "settings") File.WriteAllText(Path.Combine(args[0], "settings-layout.txt"), window.SettingsScrollDiagnostics);
                    using (Bitmap bitmap = new Bitmap(window.Width, window.Height))
                    {
                        window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, window.Size));
                        bitmap.Save(Path.Combine(args[0], page + ".png"), ImageFormat.Png);
                    }
                }
                window.MinimumSize = Size.Empty;
                float scale;
                using (Graphics graphics = window.CreateGraphics()) scale = graphics.DpiX / 96F;
                window.Size = new Size((int)Math.Round(790 * scale), (int)Math.Round(550 * scale));
                foreach (string page in new[] { "overview", "settings", "sessions", "sync" })
                {
                    window.ShowPage(page);
                    Application.DoEvents();
                    if (page == "overview") window.VerifyOverviewTextLayout();
                    if (page == "settings" && window.SettingsHorizontalOverflow) throw new InvalidOperationException("Compact settings page has a horizontal scrollbar: " + window.SettingsScrollDiagnostics);
                    if (page == "sessions" && !window.SessionColumnsFit) throw new InvalidOperationException("Compact session columns overflow the list.");
                    if (page == "sync" && !window.ProjectColumnsFit) throw new InvalidOperationException("Compact project columns overflow the lists: " + window.ProjectColumnDiagnostics);
                    if (page == "settings") File.WriteAllText(Path.Combine(args[0], "compact-settings-layout.txt"), window.SettingsScrollDiagnostics);
                    using (Bitmap bitmap = new Bitmap(window.Width, window.Height))
                    {
                        window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, window.Size));
                        bitmap.Save(Path.Combine(args[0], "compact-" + page + ".png"), ImageFormat.Png);
                    }
                }
            }
        }
    }
}
