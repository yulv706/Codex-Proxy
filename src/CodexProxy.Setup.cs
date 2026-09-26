using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Codex Proxy Setup")]
[assembly: System.Reflection.AssemblyDescription("Codex Proxy Windows 安装向导")]
[assembly: System.Reflection.AssemblyCompany("Codex Proxy Community")]
[assembly: System.Reflection.AssemblyProduct("Codex Proxy")]
[assembly: System.Reflection.AssemblyVersion("3.5.8.0")]
[assembly: System.Reflection.AssemblyFileVersion("3.5.8.0")]

namespace CodexProxySetup
{
    internal static class Program
    {
        private const string InstanceMutexName = "Local\\CodexProxy.Setup.Instance";

        [STAThread]
        private static void Main()
        {
            if (ActivateExistingInstaller())
            {
                MessageBox.Show("检测到另一个 Codex Proxy 安装向导（可能是旧版本）。请先关闭已有窗口，再重新打开当前安装包。", "Codex Proxy 安装向导", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            bool createdNew;
            using (Mutex instanceMutex = new Mutex(true, InstanceMutexName, out createdNew))
            {
                if (!createdNew)
                {
                    ActivateExistingInstaller();
                    MessageBox.Show("Codex Proxy 安装向导已经在运行，请先完成或关闭现有窗口。", "Codex Proxy 安装向导", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new SetupForm());
            }
        }

        private static bool ActivateExistingInstaller()
        {
            IntPtr window = NativeMethods.FindWindow(null, "Codex Proxy 安装向导");
            if (window == IntPtr.Zero) return false;
            NativeMethods.ShowWindow(window, 9);
            NativeMethods.SetForegroundWindow(window);
            return true;
        }
    }

    internal static class NativeMethods
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr FindWindow(string className, string windowName);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool ShowWindow(IntPtr window, int command);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetForegroundWindow(IntPtr window);
    }

    internal sealed class InstallationDetectionResult
    {
        public bool Found { get; set; }
        public string InstallDirectory { get; set; }
        public string Source { get; set; }
        public string SourceDescription { get; set; }
        public string InstalledVersion { get; set; }
        public string[] Errors { get; set; }
    }

    internal sealed class SetupForm : Form
    {
        private readonly Panel content;
        private readonly Label pageTitle;
        private readonly Label pageDescription;
        private readonly Button backButton;
        private readonly Button nextButton;
        private readonly Button cancelButton;
        private readonly ProgressBar progress;
        private readonly TextBox installPath;
        private readonly CheckBox desktopShortcut;
        private readonly CheckBox startMenuShortcut;
        private readonly CheckBox launchAfterInstall;
        private readonly Label summary;
        private readonly Button browseButton;
        private readonly Label existingInstallHint;
        private int page;
        private bool installing;
        private string installResultPath;
        private string detectedInstallDirectory;
        private bool upgradingExistingInstall;
        private InstallationDetectionResult detectedInstallation;

        internal SetupForm()
        {
            Text = "Codex Proxy 安装向导";
            Icon = LoadIcon();
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(760, 500);
            MinimumSize = new Size(700, 460);
            MaximizeBox = false;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            AutoScaleMode = AutoScaleMode.Dpi;
            BackColor = Color.White;

            Panel banner = new Panel { Dock = DockStyle.Top, Height = 92, BackColor = Color.FromArgb(15, 23, 42) };
            Label brand = new Label { Text = "Codex Proxy", ForeColor = Color.White, Font = new Font("Microsoft YaHei UI", 22F, FontStyle.Bold), AutoSize = true, Location = new Point(30, 18) };
            Label brandSub = new Label { Text = "Windows 安装向导 · v3.5.8", ForeColor = Color.FromArgb(186, 230, 253), Font = new Font("Microsoft YaHei UI", 10F), AutoSize = true, Location = new Point(33, 57) };
            banner.Controls.Add(brand); banner.Controls.Add(brandSub); Controls.Add(banner);

            pageTitle = new Label { AutoSize = true, Font = new Font("Microsoft YaHei UI", 16F, FontStyle.Bold), ForeColor = Color.FromArgb(15, 23, 42), Location = new Point(34, 116) };
            pageDescription = new Label { AutoSize = true, Font = new Font("Microsoft YaHei UI", 9.5F), ForeColor = Color.FromArgb(71, 85, 105), Location = new Point(36, 149) };
            Controls.Add(pageTitle); Controls.Add(pageDescription);

            content = new Panel { Location = new Point(34, 184), Size = new Size(692, 230), Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Bottom };
            Controls.Add(content);

            Panel footer = new Panel { Dock = DockStyle.Bottom, Height = 62, BackColor = Color.FromArgb(248, 250, 252) };
            cancelButton = new Button { Text = "取消", Width = 92, Height = 34, Location = new Point(626, 14), FlatStyle = FlatStyle.System };
            nextButton = new Button { Text = "下一步", Width = 104, Height = 34, Location = new Point(510, 14), FlatStyle = FlatStyle.System, BackColor = Color.FromArgb(37, 99, 235), ForeColor = Color.White };
            backButton = new Button { Text = "上一步", Width = 92, Height = 34, Location = new Point(406, 14), FlatStyle = FlatStyle.System, Enabled = false };
            progress = new ProgressBar { Visible = false, Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 24, Width = 190, Height = 18, Location = new Point(28, 22) };
            footer.Controls.Add(progress); footer.Controls.Add(backButton); footer.Controls.Add(nextButton); footer.Controls.Add(cancelButton);
            footer.Resize += delegate
            {
                cancelButton.Left = footer.ClientSize.Width - cancelButton.Width - 28;
                nextButton.Left = cancelButton.Left - nextButton.Width - 12;
                backButton.Left = nextButton.Left - backButton.Width - 12;
            };
            Controls.Add(footer);
            footer.BringToFront();
            cancelButton.Left = footer.ClientSize.Width - cancelButton.Width - 28;
            nextButton.Left = cancelButton.Left - nextButton.Width - 12;
            backButton.Left = nextButton.Left - backButton.Width - 12;
            footer.PerformLayout();

            installPath = new TextBox { Width = 530, Location = new Point(0, 36), Font = new Font("Microsoft YaHei UI", 10F) };
            browseButton = new Button { Text = "浏览…", Width = 92, Height = 30, Location = new Point(544, 34), FlatStyle = FlatStyle.System };
            browseButton.Click += delegate { BrowseInstallPath(); };
            existingInstallHint = new Label { AutoSize = true, ForeColor = Color.FromArgb(22, 101, 52), Font = new Font("Microsoft YaHei UI", 9F), Location = new Point(145, 8), Visible = false };
            desktopShortcut = new CheckBox { Text = "创建桌面快捷方式", AutoSize = true, Checked = true, Location = new Point(0, 88), Font = new Font("Microsoft YaHei UI", 9.5F) };
            startMenuShortcut = new CheckBox { Text = "创建开始菜单快捷方式", AutoSize = true, Checked = true, Location = new Point(220, 88), Font = new Font("Microsoft YaHei UI", 9.5F) };
            launchAfterInstall = new CheckBox { Text = "安装完成后启动 Codex Proxy", AutoSize = true, Checked = true, Location = new Point(0, 122), Font = new Font("Microsoft YaHei UI", 9.5F) };
            summary = new Label { AutoSize = false, Size = new Size(660, 180), Font = new Font("Microsoft YaHei UI", 10F), ForeColor = Color.FromArgb(51, 65, 85) };

            nextButton.Click += delegate { NextPage(); };
            backButton.Click += delegate { PreviousPage(); };
            cancelButton.Click += delegate { Close(); };
            FormClosing += delegate(object sender, FormClosingEventArgs e) { if (installing) e.Cancel = true; };
            detectedInstallation = DetectExistingInstallation();
            detectedInstallDirectory = detectedInstallation.Found ? detectedInstallation.InstallDirectory : null;
            installPath.Text = detectedInstallDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexProxy");
            if (!string.IsNullOrWhiteSpace(detectedInstallDirectory))
            {
                upgradingExistingInstall = true;
                string versionText = string.IsNullOrWhiteSpace(detectedInstallation.InstalledVersion) ? string.Empty : " v" + detectedInstallation.InstalledVersion;
                existingInstallHint.Text = "检测到已有安装" + versionText + "（" + GetDetectionSourceText(detectedInstallation.Source) + "），将在原目录升级";
                existingInstallHint.ForeColor = Color.FromArgb(22, 101, 52);
                installPath.ReadOnly = true;
                browseButton.Enabled = false;
            }
            else
            {
                bool incomplete = detectedInstallation.Errors != null && detectedInstallation.Errors.Length > 0;
                existingInstallHint.Text = incomplete ? "未完整读取安装记录，将按全新安装处理" : "未检测到已有安装，将执行全新安装";
                existingInstallHint.ForeColor = incomplete ? Color.FromArgb(180, 83, 9) : Color.FromArgb(100, 116, 139);
            }
            existingInstallHint.Visible = true;
            ShowPage(0);
        }

        private static InstallationDetectionResult DetectExistingInstallation()
        {
            InstallationDetectionResult failure = new InstallationDetectionResult { Found = false, Errors = new string[0] };
            string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Detect-CodexProxyInstallation.ps1");
            if (!File.Exists(script))
            {
                failure.Errors = new string[] { "安装检测组件缺失" };
                return failure;
            }
            try
            {
                string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
                ProcessStartInfo info = new ProcessStartInfo(powershell, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -AsJson");
                info.WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory;
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.WindowStyle = ProcessWindowStyle.Hidden;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                info.StandardOutputEncoding = Encoding.UTF8;
                info.StandardErrorEncoding = Encoding.UTF8;
                using (Process process = Process.Start(info))
                {
                    string output = process.StandardOutput.ReadToEnd();
                    string error = process.StandardError.ReadToEnd();
                    process.WaitForExit();
                    if (process.ExitCode != 0 || string.IsNullOrWhiteSpace(output))
                    {
                        failure.Errors = new string[] { string.IsNullOrWhiteSpace(error) ? "安装检测没有返回结果" : error.Trim() };
                        return failure;
                    }
                    InstallationDetectionResult result = new JavaScriptSerializer().Deserialize<InstallationDetectionResult>(output.Trim());
                    if (result == null) return failure;
                    if (result.Errors == null) result.Errors = new string[0];
                    return result;
                }
            }
            catch (Exception ex)
            {
                failure.Errors = new string[] { ex.Message };
                return failure;
            }
        }

        private static string GetDetectionSourceText(string source)
        {
            if (!string.IsNullOrWhiteSpace(source) && source.StartsWith("Registry", StringComparison.OrdinalIgnoreCase)) return "Windows 已安装应用记录";
            if (!string.IsNullOrWhiteSpace(source) && source.IndexOf("StartMenu", StringComparison.OrdinalIgnoreCase) >= 0) return "开始菜单快捷方式";
            if (!string.IsNullOrWhiteSpace(source) && source.IndexOf("Desktop", StringComparison.OrdinalIgnoreCase) >= 0) return "桌面快捷方式";
            if (string.Equals(source, "DefaultDirectory", StringComparison.OrdinalIgnoreCase)) return "默认安装目录";
            return "已有安装记录";
        }

        private static bool PathsEqual(string left, string right)
        {
            if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return false;
            try
            {
                return Path.GetFullPath(left).TrimEnd('\\').Equals(Path.GetFullPath(right).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        private Icon LoadIcon()
        {
            try
            {
                string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "assets", "codex-proxy.ico");
                if (File.Exists(path)) return new Icon(path);
            }
            catch { }
            return SystemIcons.Application;
        }

        private void BrowseInstallPath()
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "选择 Codex Proxy 的安装目录";
                dialog.SelectedPath = installPath.Text;
                dialog.ShowNewFolderButton = true;
                if (dialog.ShowDialog(this) == DialogResult.OK) installPath.Text = dialog.SelectedPath;
            }
        }

        private void ShowPage(int target)
        {
            page = target;
            content.Controls.Clear();
            if (page == 0)
            {
                pageTitle.Text = "欢迎使用 Codex Proxy";
                pageDescription.Text = "这个向导会帮助你完成安装，并保留现有配置。";
                Label text = new Label { AutoSize = false, Size = new Size(650, 150), Text = "Codex Proxy 提供本地代理启动、状态监控和跨电脑历史会话同步。\r\n\r\n点击“下一步”确认安装目录和快捷方式。安装完成后可在 Codex Proxy 设置中修改代理端口。安装过程中不会修改系统代理设置。", Font = new Font("Microsoft YaHei UI", 11F), ForeColor = Color.FromArgb(51, 65, 85) };
                content.Controls.Add(text);
                backButton.Enabled = false; nextButton.Text = "下一步";
            }
            else if (page == 1)
            {
                pageTitle.Text = "安装选项";
                pageDescription.Text = upgradingExistingInstall ? "已检测到旧版本，安装目录已锁定，将直接覆盖升级并保留用户配置。" : "选择安装位置和快捷方式。代理端口可在程序设置中修改。";
                Label pathLabel = new Label { Text = "安装目录", AutoSize = true, Location = new Point(0, 8), Font = new Font("Microsoft YaHei UI", 9.5F, FontStyle.Bold) };
                content.Controls.Add(pathLabel); content.Controls.Add(existingInstallHint); content.Controls.Add(installPath); content.Controls.Add(browseButton); content.Controls.Add(desktopShortcut); content.Controls.Add(startMenuShortcut); content.Controls.Add(launchAfterInstall);
                backButton.Enabled = true; nextButton.Text = "下一步";
            }
            else if (page == 2)
            {
                pageTitle.Text = "准备安装";
                pageDescription.Text = upgradingExistingInstall ? "将保留原目录中的用户配置并完成覆盖升级。" : "请确认以下设置，然后开始安装。";
                summary.Text = (upgradingExistingInstall ? "升级目录：\r\n  " : "安装目录：\r\n  ") + installPath.Text + "\r\n\r\n快捷方式：" + (desktopShortcut.Checked ? "桌面 " : "") + (startMenuShortcut.Checked ? "开始菜单" : "无") + "\r\n安装完成后：" + (launchAfterInstall.Checked ? "启动 Codex Proxy" : "返回桌面") + "\r\n\r\n代理端口可在安装完成后从 Codex Proxy 设置中修改。";
                content.Controls.Add(summary);
                backButton.Enabled = true; nextButton.Text = "安装";
            }
            else if (page == 3)
            {
                pageTitle.Text = "正在安装 Codex Proxy";
                pageDescription.Text = "请稍候，安装程序正在复制文件并创建快捷方式。";
                Label text = new Label { Text = "安装进行中，请不要关闭此窗口。", AutoSize = true, Location = new Point(0, 12), Font = new Font("Microsoft YaHei UI", 10F) };
                content.Controls.Add(text); progress.Visible = true; backButton.Enabled = false; nextButton.Enabled = false; cancelButton.Enabled = false;
            }
            else
            {
                pageTitle.Text = "安装完成";
                pageDescription.Text = "Codex Proxy 已经安装完成。";
                Label text = new Label { AutoSize = false, Size = new Size(650, 120), Text = "安装已完成。\r\n\r\n你可以从桌面或开始菜单启动 Codex Proxy。", Font = new Font("Microsoft YaHei UI", 11F), ForeColor = Color.FromArgb(22, 101, 52) };
                content.Controls.Add(text);
                progress.Visible = false; backButton.Enabled = false; nextButton.Enabled = false; cancelButton.Text = "关闭";
                if (!string.IsNullOrWhiteSpace(installResultPath))
                {
                    Button open = new Button { Text = "打开安装目录", Width = 130, Height = 32, Location = new Point(0, 140), FlatStyle = FlatStyle.System };
                    open.Click += delegate { try { Process.Start("explorer.exe", installResultPath); } catch { } };
                    content.Controls.Add(open);
                }
            }
        }

        private void NextPage()
        {
            if (page == 0) { ShowPage(1); return; }
            if (page == 1)
            {
                string path = installPath.Text.Trim();
                if (string.IsNullOrWhiteSpace(path)) { MessageBox.Show(this, "请选择安装目录。", "安装选项", MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
                try
                {
                    string full = Path.GetFullPath(path).TrimEnd('\\');
                    if (full.Equals(Path.GetPathRoot(full).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("请选择磁盘根目录下的一个子目录。\r\n例如：C:\\Users\\Public\\CodexProxy");
                    installPath.Text = full;
                    upgradingExistingInstall = PathsEqual(full, detectedInstallDirectory);
                }
                catch (Exception ex) { MessageBox.Show(this, ex.Message, "安装目录无效", MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
                ShowPage(2); return;
            }
            if (page == 2) { ShowPage(3); BeginInstall(); }
            else if (page == 4) Close();
        }

        private void PreviousPage()
        {
            if (page == 1) ShowPage(0); else if (page == 2) ShowPage(1);
        }

        private void BeginInstall()
        {
            installing = true;
            string script = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "Install-CodexProxy.ps1");
            string args = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -InstallDirectory " + Quote(installPath.Text);
            if (!desktopShortcut.Checked) args += " -NoDesktopShortcut";
            if (!startMenuShortcut.Checked) args += " -NoStartMenuShortcut";
            if (!launchAfterInstall.Checked) args += " -NoLaunch";
            Task.Run(delegate
            {
                int exitCode = -1; string error = string.Empty;
                try
                {
                    ProcessStartInfo info = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe"), args);
                    info.WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory; info.UseShellExecute = false; info.CreateNoWindow = true; info.WindowStyle = ProcessWindowStyle.Hidden; info.RedirectStandardOutput = true; info.RedirectStandardError = true; info.StandardOutputEncoding = Encoding.UTF8; info.StandardErrorEncoding = Encoding.UTF8;
                    using (Process process = Process.Start(info))
                    {
                        Task<string> output = process.StandardOutput.ReadToEndAsync();
                        Task<string> stderr = process.StandardError.ReadToEndAsync();
                        process.WaitForExit(); Task.WaitAll(output, stderr); exitCode = process.ExitCode; error = string.IsNullOrWhiteSpace(stderr.Result) ? output.Result : stderr.Result;
                    }
                }
                catch (Exception ex) { error = ex.Message; }
                BeginInvoke((Action)delegate
                {
                    installing = false;
                    if (exitCode == 0)
                    {
                        installResultPath = installPath.Text; ShowPage(4);
                    }
                    else
                    {
                        progress.Visible = false; backButton.Enabled = true; nextButton.Enabled = true; cancelButton.Enabled = true; ShowPage(2);
                        MessageBox.Show(this, "安装失败：\r\n" + error.Trim(), "Codex Proxy 安装失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                });
            });
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }
    }
}
