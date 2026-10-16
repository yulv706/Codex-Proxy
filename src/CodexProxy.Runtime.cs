using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace CodexProxyDesktop
{
    internal interface IRuntimeBridge : IDisposable
    {
        int ReadSavedPort();
        void SavePort(int port);
        DiagnosticStatus GetStatus(bool full = false);
        LaunchResult LaunchCodex();
        ApplicationCatalog LoadApplications();
        void SaveApplications(ApplicationCatalog catalog);
        string ApplicationWarning { get; }
        string ResolveExecutable(ApplicationProfile profile);
        DiagnosticStatus GetStatus(ApplicationProfile profile, bool full = false);
        LaunchResult LaunchApplication(ApplicationProfile profile);
        bool IsStartupEnabled();
        void SetStartup(bool enabled);
        void OpenLogDirectory();
    }

    internal sealed class RuntimeBridge : IRuntimeBridge
    {
        private const string RunRegistryPath = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
        private const string RunValueName = "CodexProxy";
        private readonly string root;
        private readonly string diagnosticPath;
        private readonly string launcherPath;
        private readonly string userConfigPath;
        private readonly string defaultConfigPath;
        private readonly string logPath;
        private readonly ApplicationStore applications;
        private readonly object processGate = new object();
        private readonly List<Process> activeProcesses = new List<Process>();
        private bool disposed;

        internal RuntimeBridge(string applicationRoot)
        {
            root = Path.GetFullPath(applicationRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            diagnosticPath = Path.Combine(root, "Test-CodexProxy.ps1");
            launcherPath = Path.Combine(root, "Start-CodexProxy.ps1");
            userConfigPath = Path.Combine(root, "CodexProxy.user.psd1");
            defaultConfigPath = Path.Combine(root, "CodexProxy.config.psd1");
            logPath = Path.Combine(Product.DataDirectory, "logs", "launcher.log");
            applications = new ApplicationStore(Path.Combine(Product.DataDirectory, "applications.json"));
        }

        public ApplicationCatalog LoadApplications() { return applications.Load(); }
        public void SaveApplications(ApplicationCatalog catalog) { applications.Save(catalog); }
        public string ApplicationWarning { get { return applications.ReadWarning; } }
        public string ResolveExecutable(ApplicationProfile profile) { return ApplicationDiscovery.Resolve(profile); }
        public DiagnosticStatus GetStatus(ApplicationProfile profile, bool full = false)
        {
            if (!profile.IsCodex) return ApplicationLauncher.Check(profile, profile.EffectivePort(ReadSavedPort()));
            return GetCodexStatus(full, profile.ProxyPort);
        }
        public LaunchResult LaunchApplication(ApplicationProfile profile)
        {
            lock (processGate) { if (disposed) return new LaunchResult(false, "启动器正在退出，操作已取消。"); }
            return profile.IsCodex ? LaunchCodex(profile.ProxyPort) : ApplicationLauncher.Launch(profile, profile.EffectivePort(ReadSavedPort()), StartApplication);
        }
        private Process StartApplication(ProcessStartInfo info)
        {
            lock (processGate)
            {
                if (disposed) throw new ObjectDisposedException("Codex Proxy", "启动器正在退出，操作已取消。");
                return Process.Start(info);
            }
        }

        public int ReadSavedPort()
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

        public void SavePort(int port)
        {
            if (port < 1 || port > 65535) throw new ArgumentOutOfRangeException("port");
            string temporaryPath = userConfigPath + ".writing-" + Guid.NewGuid().ToString("N") + ".tmp";
            string contents = File.Exists(userConfigPath) ? File.ReadAllText(userConfigPath) : "@{\r\n}\r\n";
            if (Regex.IsMatch(contents, @"(?im)^\s*ProxyPort\s*=\s*\d+\s*$"))
                contents = Regex.Replace(contents, @"(?im)^(\s*ProxyPort\s*=\s*)\d+(\s*)$", match => match.Groups[1].Value + port + match.Groups[2].Value);
            else
            {
                int closing = contents.LastIndexOf('}');
                if (closing < 0) throw new InvalidDataException("代理配置格式不正确，请修复安装后重试。");
                contents = contents.Insert(closing, "    ProxyPort = " + port + "\r\n");
            }
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

        public DiagnosticStatus GetStatus(bool full = false)
        {
            return GetCodexStatus(full, 0);
        }

        private DiagnosticStatus GetCodexStatus(bool full, int port)
        {
            if (!File.Exists(diagnosticPath)) return DiagnosticStatus.FromError("DIAGNOSTIC_MISSING", "找不到状态诊断脚本，请重新安装 Codex Proxy。");
            ProcessResult result = RunPowerShell("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(diagnosticPath) + " -Json" + (full ? string.Empty : " -Monitor") + (port == 0 ? "" : " -ProxyPort " + port), true);
            string json = result.StandardOutput.Trim();
            if (json.Length == 0) return DiagnosticStatus.FromError("DIAGNOSTIC_FAILED", FirstUseful(result.StandardError, "状态检查没有返回结果。"));
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> values = serializer.Deserialize<Dictionary<string, object>>(json);
                return DiagnosticStatus.FromValues(values);
            }
            catch (Exception ex)
            {
                return DiagnosticStatus.FromError("DIAGNOSTIC_JSON_INVALID", "无法读取状态结果：" + ex.Message);
            }
        }

        public LaunchResult LaunchCodex()
        {
            return LaunchCodex(0);
        }

        private LaunchResult LaunchCodex(int port)
        {
            if (!File.Exists(launcherPath)) return new LaunchResult(false, "找不到启动脚本，请重新安装 Codex Proxy。");
            ProcessResult result = RunPowerShell("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(launcherPath) + " -NoUI" + (port == 0 ? "" : " -ProxyPort " + port), true);
            if (result.ExitCode == 0) return new LaunchResult(true, "Codex 已启动。");
            return new LaunchResult(false, FirstUseful(result.StandardError, FirstUseful(result.StandardOutput, "启动失败，退出码 " + result.ExitCode + "。")));
        }

        public void OpenLogDirectory()
        {
            string directory = Path.GetDirectoryName(logPath);
            Directory.CreateDirectory(directory);
            Process.Start("explorer.exe", Quote(directory));
        }

        internal InstallationDetectionResult DetectInstallation()
        {
            string script = Path.Combine(root, "Detect-CodexProxyInstallation.ps1");
            if (!File.Exists(script)) throw new FileNotFoundException("缺少安装检测组件，请重新解压完整安装包。");
            ProcessResult result = RunPowerShell("-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -AsJson", true);
            if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.StandardOutput)) throw new InvalidOperationException(FirstUseful(result.StandardError, "无法检查已有安装。"));
            InstallationDetectionResult detected = new JavaScriptSerializer().Deserialize<InstallationDetectionResult>(result.StandardOutput.Trim());
            if (detected == null) throw new InvalidDataException("安装检测返回了空结果。");
            return detected;
        }

        internal ProcessResult Install(string directory, bool desktopShortcut, bool startMenuShortcut)
        {
            string script = Path.Combine(root, "Install-CodexProxy.ps1");
            if (!File.Exists(script)) return new ProcessResult(1, "", "缺少安装脚本，请重新解压完整安装包。");
            string arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -InstallDirectory " + Quote(directory) + " -NoLaunch";
            if (!desktopShortcut) arguments += " -NoDesktopShortcut";
            if (!startMenuShortcut) arguments += " -NoStartMenuShortcut";
            return RunPowerShell(arguments, true);
        }

        public bool IsStartupEnabled()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunRegistryPath, false))
            {
                string current = key == null ? null : key.GetValue(RunValueName) as string;
                return string.Equals(current, StartupCommand(), StringComparison.OrdinalIgnoreCase);
            }
        }

        public void SetStartup(bool enabled)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunRegistryPath))
            {
                if (enabled) key.SetValue(RunValueName, StartupCommand(), RegistryValueKind.String);
                else key.DeleteValue(RunValueName, false);
            }
        }

        private string StartupCommand()
        {
            return Quote(System.Reflection.Assembly.GetEntryAssembly().Location) + " --background";
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
                if (!process.WaitForExit(180000))
                {
                    try { process.Kill(); } catch { }
                    return new ProcessResult(-1, string.Empty, "操作等待超时，请查看日志后重试。");
                }
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

    internal sealed class InstallationDetectionResult
    {
        public bool Found { get; set; }
        public string InstallDirectory { get; set; }
        public string Source { get; set; }
        public string InstalledVersion { get; set; }
        public string[] Errors { get; set; }
    }

    internal sealed class DiagnosticStatus
    {
        internal bool HasRuntimeData = true;
        internal bool ProxyReady;
        internal bool ApplicationInstalled;
        internal bool ApplicationRunning;
        internal bool RuntimeReadyNow;
        internal bool RuntimeReadyAfterExit;
        internal bool UpdatePending;
        internal bool ApplicationReady;
        internal bool AppxAvailable;
        internal bool ShortcutReady;
        internal string ProxyUrl;
        internal string ProxyProcess;
        internal string ExecutablePath;
        internal string ApplicationVersion;
        internal string ReportedUpdateVersion;
        internal string BlockingCode;
        internal string BlockingMessage;
        internal string Remediation;
        internal DateTime CheckedAt;

        internal static DiagnosticStatus FromValues(Dictionary<string, object> values)
        {
            DiagnosticStatus status = new DiagnosticStatus();
            status.ProxyReady = Bool(values, "ProxyReady");
            status.ApplicationInstalled = Bool(values, "CodexInstalled");
            status.ApplicationRunning = Bool(values, "CodexCurrentlyRunning");
            status.RuntimeReadyNow = Bool(values, "RuntimeReadyNow", Bool(values, "ReadyToLaunchNow"));
            status.RuntimeReadyAfterExit = Bool(values, "RuntimeReadyAfterCodexExit", Bool(values, "ReadyToLaunchAfterCodexExit"));
            status.UpdatePending = Bool(values, "AutomaticUpdatePending");
            status.ApplicationReady = Bool(values, "CodexApplicationReady");
            status.AppxAvailable = Bool(values, "AppxLaunchCommandAvailable");
            status.ShortcutReady = Bool(values, "DesktopShortcutReady");
            status.ProxyUrl = Text(values, "ProxyUrl", "未配置");
            status.ProxyProcess = Text(values, "ProxyProcess", null);
            status.ApplicationVersion = Text(values, "CodexVersion", null);
            status.ReportedUpdateVersion = Text(values, "ReportedUpdateVersion", null);
            status.BlockingCode = Text(values, "BlockingCode", null);
            status.BlockingMessage = Text(values, "BlockingMessage", null);
            status.Remediation = Text(values, "Remediation", null);
            status.CheckedAt = DateTime.Now;

            return status;
        }

        internal static DiagnosticStatus FromError(string code, string message)
        {
            return new DiagnosticStatus
            {
                HasRuntimeData = false,
                CheckedAt = DateTime.Now,
                BlockingCode = code,
                BlockingMessage = message,
                ProxyUrl = "未知"
            };
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

}
