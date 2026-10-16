using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using Microsoft.Win32;

namespace CodexProxyDesktop
{
    public sealed class ApplicationProfile
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string ExecutablePath { get; set; }
        public string Mode { get; set; }
        public string[] Arguments { get; set; }
        public int ProxyPort { get; set; }
        [ScriptIgnore] public bool IsCodex { get { return Id == "codex"; } }
        [ScriptIgnore] public bool IsBuiltIn { get { return Id == "codex" || Id == "cursor" || Id == "grokbot"; } }
        [ScriptIgnore] public string Monogram { get { return Id == "codex" ? "C" : Id == "cursor" ? "↗" : Id == "grokbot" ? "G" : Name.Substring(0, 1).ToUpperInvariant(); } }
        [ScriptIgnore] public string KindLabel { get { return IsCodex ? "Microsoft Store" : Mode == "electron" ? "Electron 应用" : "环境变量代理"; } }
        [ScriptIgnore] public string RouteLabel { get { return ProxyPort == 0 ? "使用默认代理端口" : "独立端口 · " + ProxyPort; } }
        [ScriptIgnore] public string LocationLabel { get { return IsCodex ? "官方 Store 应用包" : string.IsNullOrWhiteSpace(ExecutablePath) ? "自动识别安装位置" : ExecutablePath; } }
        public override string ToString() { return Name; }
        internal ApplicationProfile Copy() { var copy = (ApplicationProfile)MemberwiseClone(); copy.Arguments = (Arguments ?? new string[0]).ToArray(); return copy; }
        internal int EffectivePort(int fallback) { return ProxyPort == 0 ? fallback : ProxyPort; }
        internal static List<ApplicationProfile> Defaults()
        {
            return new List<ApplicationProfile> {
                new ApplicationProfile { Id = "codex", Name = "Codex", Mode = "codex", Arguments = new string[0] },
                new ApplicationProfile { Id = "cursor", Name = "Cursor", Mode = "electron", Arguments = new string[0] },
                new ApplicationProfile { Id = "grokbot", Name = "Grok Bot", Mode = "electron", Arguments = new string[0] }
            };
        }
        internal static void Validate(ApplicationProfile profile)
        {
            if (profile == null || !Regex.IsMatch(profile.Id ?? "", @"^(codex|cursor|grokbot|custom-[a-f0-9]{32})$")) throw new InvalidDataException("应用标识无效。");
            if (string.IsNullOrWhiteSpace(profile.Name) || profile.Name.Length > 40 || profile.Name.Any(char.IsControl)) throw new InvalidDataException("应用名称需要为 1–40 个可见字符。");
            if (profile.ProxyPort < 0 || profile.ProxyPort > 65535) throw new InvalidDataException("代理端口需要为 1–65535，或使用默认端口。");
            if (profile.IsCodex ? profile.Mode != "codex" : profile.Mode != "electron" && profile.Mode != "environment") throw new InvalidDataException("不支持的代理启动方式。");
            if (!string.IsNullOrWhiteSpace(profile.ExecutablePath) && (!Path.IsPathRooted(profile.ExecutablePath) || Path.GetPathRoot(profile.ExecutablePath).Length < 3 || !string.Equals(Path.GetExtension(profile.ExecutablePath), ".exe", StringComparison.OrdinalIgnoreCase))) throw new InvalidDataException("请选择具有完整路径的 .exe 程序。");
            if (!profile.IsBuiltIn && string.IsNullOrWhiteSpace(profile.ExecutablePath)) throw new InvalidDataException("请选择要启动的程序。");
            if (profile.Arguments == null) profile.Arguments = new string[0];
            if (profile.Arguments.Length > 128 || profile.Arguments.Any(arg => arg == null || arg.IndexOf('\0') >= 0 || arg.IndexOfAny(new[] { '\r', '\n' }) >= 0) || profile.Arguments.Sum(arg => arg.Length + 3) > 16000) throw new InvalidDataException("启动参数过长，或包含无效字符。");
            if (profile.Arguments.Any(arg => Regex.IsMatch(arg, @"^--(?:proxy-server|proxy-pac-url|proxy-bypass-list|no-proxy-server)(?:=|$)", RegexOptions.IgnoreCase))) throw new InvalidDataException("代理参数由启动器管理，请移除启动参数中的代理开关。");
            if (profile.IsCodex && profile.Arguments.Length != 0) throw new InvalidDataException("Codex 使用官方应用包启动，无需额外参数。");
        }
    }

    public sealed class ApplicationCatalog
    {
        public int SchemaVersion { get; set; }
        public string SelectedId { get; set; }
        public List<ApplicationProfile> Applications { get; set; }
        public ApplicationCatalog() { SchemaVersion = 1; SelectedId = "codex"; Applications = ApplicationProfile.Defaults(); }
        internal ApplicationCatalog Copy() { return new ApplicationCatalog { SchemaVersion = SchemaVersion, SelectedId = SelectedId, Applications = Applications.Select(app => app.Copy()).ToList() }; }
    }

    internal sealed class ApplicationStore
    {
        private readonly string path;
        internal string ReadWarning { get; private set; }
        internal ApplicationStore(string file) { path = file; }
        internal ApplicationCatalog Load()
        {
            ReadWarning = "";
            if (!File.Exists(path)) return new ApplicationCatalog();
            try
            {
                ApplicationCatalog saved = new JavaScriptSerializer().Deserialize<ApplicationCatalog>(File.ReadAllText(path));
                Validate(saved);
                ApplicationCatalog result = new ApplicationCatalog();
                foreach (ApplicationProfile profile in saved.Applications)
                {
                    int index = result.Applications.FindIndex(app => app.Id == profile.Id);
                    if (index < 0) result.Applications.Add(profile);
                    else { profile.Name = result.Applications[index].Name; result.Applications[index] = profile; }
                }
                result.SelectedId = result.Applications.Any(app => app.Id == saved.SelectedId) ? saved.SelectedId : "codex";
                return result;
            }
            catch (Exception ex)
            {
                ReadWarning = "应用配置未能读取，暂时使用内置列表。原文件已保留：" + ex.Message;
                return new ApplicationCatalog();
            }
        }
        internal void Save(ApplicationCatalog value)
        {
            Validate(value);
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
            string temporary = path + ".writing-" + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(value), new UTF8Encoding(true));
                if (File.Exists(path)) File.Replace(temporary, path, string.IsNullOrEmpty(ReadWarning) ? null : path + ".invalid-" + DateTime.Now.ToString("yyyyMMddHHmmssfff") + ".bak");
                else File.Move(temporary, path);
                ReadWarning = "";
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        private static void Validate(ApplicationCatalog value)
        {
            if (value == null || value.SchemaVersion != 1 || value.Applications == null || value.Applications.Count > 100) throw new InvalidDataException("应用配置版本或数量无效。");
            HashSet<string> ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (ApplicationProfile profile in value.Applications) { ApplicationProfile.Validate(profile); if (!ids.Add(profile.Id)) throw new InvalidDataException("应用标识重复。"); }
        }
    }

    internal static class ApplicationDiscovery
    {
        internal static string Resolve(ApplicationProfile profile)
        {
            if (!string.IsNullOrWhiteSpace(profile.ExecutablePath)) return Path.GetFullPath(profile.ExecutablePath);
            if (profile.IsCodex || !profile.IsBuiltIn) return "";
            string executable = profile.Id == "cursor" ? "Cursor.exe" : "Grok Bot.exe";
            string displayPattern = profile.Id == "cursor" ? @"^Cursor(?: \((?:User|System)\))?$" : @"^Grok\s?Bot(?:\s|$)";
            HashSet<string> candidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (RegistryHive hive in new[] { RegistryHive.CurrentUser, RegistryHive.LocalMachine })
            foreach (RegistryView view in new[] { RegistryView.Registry64, RegistryView.Registry32 })
            {
                try
                {
                    using (RegistryKey root = RegistryKey.OpenBaseKey(hive, view))
                    {
                        using (RegistryKey key = root.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\App Paths\" + executable))
                        {
                            string candidate = key == null ? "" : Convert.ToString(key.GetValue(""));
                            if (IsExecutable(candidate)) candidates.Add(Path.GetFullPath(candidate.Trim('"')));
                        }
                        using (RegistryKey uninstall = root.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall"))
                        {
                            if (uninstall == null) continue;
                            foreach (string name in uninstall.GetSubKeyNames())
                            using (RegistryKey entry = uninstall.OpenSubKey(name))
                            {
                                if (entry == null || !Regex.IsMatch(Convert.ToString(entry.GetValue("DisplayName")), displayPattern, RegexOptions.IgnoreCase)) continue;
                                string location = Environment.ExpandEnvironmentVariables(Convert.ToString(entry.GetValue("InstallLocation"))).Trim('"');
                                if (!string.IsNullOrEmpty(location)) { string found = InDirectory(location, executable); if (found != null) candidates.Add(found); }
                                string icon = Environment.ExpandEnvironmentVariables(Convert.ToString(entry.GetValue("DisplayIcon")));
                                Match match = Regex.Match(icon, "^\\\"(?<path>[^\\\"]+\\.exe)\\\"(?:,.*)?$|^(?<path>.*?\\.exe)(?:,\\s*-?\\d+)?$", RegexOptions.IgnoreCase);
                                if (match.Success && IsExecutable(match.Groups["path"].Value) && string.Equals(Path.GetFileName(match.Groups["path"].Value), executable, StringComparison.OrdinalIgnoreCase)) candidates.Add(Path.GetFullPath(match.Groups["path"].Value));
                            }
                        }
                    }
                }
                catch (System.Security.SecurityException) { }
                catch (UnauthorizedAccessException) { }
                catch (IOException) { }
                catch (ArgumentException) { }
            }
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            foreach (string directory in new[] { Path.Combine(local, "Programs", profile.Id == "cursor" ? "cursor" : "Grok Bot"), Path.Combine(local, profile.Id == "cursor" ? "Cursor" : "GrokBot"), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), profile.Id == "cursor" ? "Cursor" : "Grok Bot") })
            { string found = InDirectory(directory, executable); if (found != null) candidates.Add(found); }
            return candidates.OrderByDescending(ExecutableVersion).FirstOrDefault() ?? "";
        }
        internal static Version ExecutableVersion(string path)
        {
            try { FileVersionInfo info = FileVersionInfo.GetVersionInfo(path); return new Version(Math.Max(0, info.FileMajorPart), Math.Max(0, info.FileMinorPart), Math.Max(0, info.FileBuildPart), Math.Max(0, info.FilePrivatePart)); }
            catch (IOException) { return new Version(0, 0); }
        }
        private static bool IsExecutable(string path) { return !string.IsNullOrWhiteSpace(path) && string.Equals(Path.GetExtension(path.Trim('"')), ".exe", StringComparison.OrdinalIgnoreCase) && File.Exists(path.Trim('"')); }
        private static string InDirectory(string directory, string executable)
        {
            string direct = Path.Combine(directory, executable);
            if (!Directory.Exists(directory)) return null;
            try
            {
                return Directory.GetDirectories(directory, "app-*").Select(path => Path.Combine(path, executable)).Concat(new[] { direct }).Where(File.Exists).OrderByDescending(ExecutableVersion).Select(Path.GetFullPath).FirstOrDefault();
            }
            catch (UnauthorizedAccessException) { return File.Exists(direct) ? Path.GetFullPath(direct) : null; }
        }
    }

    internal static class ApplicationLauncher
    {
        internal static DiagnosticStatus Check(ApplicationProfile profile, int port)
        {
            ApplicationProfile.Validate(profile);
            string path = ApplicationDiscovery.Resolve(profile);
            var status = new DiagnosticStatus { CheckedAt = DateTime.Now, ProxyUrl = "http://127.0.0.1:" + port, ExecutablePath = path, ApplicationInstalled = File.Exists(path), ApplicationReady = File.Exists(path) };
            string proxyError;
            status.ProxyReady = Probe(port, profile.Id == "cursor" || profile.Id == "grokbot" ? "api2.cursor.sh" : "www.example.com", out proxyError);
            status.ProxyProcess = status.ProxyReady ? "HTTP CONNECT 连接通过" : proxyError;
            try { if (status.ApplicationInstalled) { status.ApplicationVersion = FileVersionInfo.GetVersionInfo(path).ProductVersion; status.ApplicationRunning = IsRunning(path, profile); } }
            catch (Exception ex) { status.BlockingCode = "PROCESS_INSPECTION_FAILED"; status.BlockingMessage = "无法确认应用进程状态：" + ex.Message; status.Remediation = "请关闭该应用后重新检测，或检查应用与启动器的运行权限。"; return status; }
            status.RuntimeReadyAfterExit = status.ApplicationReady && status.ProxyReady;
            status.RuntimeReadyNow = status.RuntimeReadyAfterExit && !status.ApplicationRunning;
            status.BlockingCode = !status.ApplicationInstalled ? "APPLICATION_NOT_FOUND" : !status.ProxyReady ? "PROXY_UNAVAILABLE" : status.ApplicationRunning ? "APPLICATION_RUNNING" : "READY";
            status.BlockingMessage = !status.ApplicationInstalled ? "未找到 " + profile.Name : !status.ProxyReady ? proxyError : status.ApplicationRunning ? profile.Name + " 已在运行" : "启动环境已就绪";
            status.Remediation = !status.ApplicationInstalled ? "打开应用设置，选择 " + profile.Name + " 的 .exe 文件，或安装后重新检测。" : !status.ProxyReady ? "请启动本地代理客户端，并检查 HTTP / Mixed 端口。" : status.ApplicationRunning ? "请完全退出 " + profile.Name + "（包括托盘进程）后重新通过代理启动。" : "";
            return status;
        }
        internal static bool Probe(int port, string host, out string error)
        {
            error = "";
            using (TcpClient client = new TcpClient())
            {
                try
                {
                    IAsyncResult pending = client.BeginConnect("127.0.0.1", port, null, null);
                    using (WaitHandle handle = pending.AsyncWaitHandle) { if (!handle.WaitOne(4000)) throw new IOException("本地代理连接超时。"); client.EndConnect(pending); }
                    using (NetworkStream stream = client.GetStream())
                    {
                        stream.ReadTimeout = 4000; stream.WriteTimeout = 4000;
                        Stopwatch responseTimer = Stopwatch.StartNew();
                        byte[] request = Encoding.ASCII.GetBytes("CONNECT " + host + ":443 HTTP/1.1\r\nHost: " + host + ":443\r\n\r\n");
                        stream.Write(request, 0, request.Length);
                        StringBuilder response = new StringBuilder();
                        int value;
                        while (response.Length < 1024)
                        {
                            int remaining = 4000 - (int)responseTimer.ElapsedMilliseconds;
                            if (remaining <= 0) throw new IOException("代理响应超时。");
                            stream.ReadTimeout = remaining; value = stream.ReadByte();
                            if (value < 0 || value == '\n') break;
                            response.Append((char)value);
                        }
                        if (!Regex.IsMatch(response.ToString(), @"^HTTP/\d(?:\.\d)?\s+2\d\d\b")) throw new IOException("代理未接受 CONNECT 请求：" + response.ToString().Trim());
                        return true;
                    }
                }
                catch (Exception ex) { error = ex.Message; return false; }
            }
        }
        internal static bool IsRunning(string path, ApplicationProfile profile = null)
        {
            string expected = Path.GetFullPath(path);
            bool builtIn = profile != null && profile.IsBuiltIn && !profile.IsCodex;
            string canonicalName = builtIn ? profile.Id == "cursor" ? "Cursor" : "Grok Bot" : Path.GetFileNameWithoutExtension(path);
            Process[] processes = new[] { Path.GetFileNameWithoutExtension(path), canonicalName }.Distinct(StringComparer.OrdinalIgnoreCase).SelectMany(Process.GetProcessesByName).ToArray();
            try
            {
                foreach (Process process in processes)
                {
                    try
                    {
                        if (process.HasExited) continue;
                        string runningPath = Path.GetFullPath(process.MainModule.FileName);
                        if (string.Equals(runningPath, expected, StringComparison.OrdinalIgnoreCase)) return true;
                        if (builtIn && string.Equals(Regex.Replace(FileVersionInfo.GetVersionInfo(runningPath).ProductName ?? "", @"\s", ""), Regex.Replace(canonicalName, @"\s", ""), StringComparison.OrdinalIgnoreCase)) return true;
                    }
                    catch (InvalidOperationException) { }
                }
                // Access denied is propagated: starting a second Electron instance
                // could hand off to a process that has no proxy environment.
            }
            finally { foreach (Process process in processes) process.Dispose(); }
            return false;
        }
        internal static ProcessStartInfo StartInfo(ApplicationProfile profile, string path, int port)
        {
            ApplicationProfile.Validate(profile);
            if (port < 1 || port > 65535) throw new ArgumentOutOfRangeException("port");
            string proxy = "http://127.0.0.1:" + port;
            List<string> arguments = new List<string>();
            if (profile.Mode == "electron") arguments.Add("--proxy-server=" + proxy);
            arguments.AddRange(profile.Arguments);
            var info = new ProcessStartInfo(path, string.Join(" ", arguments.Select(QuoteArgument))) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(path) };
            foreach (string key in new[] { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "WS_PROXY", "WSS_PROXY", "http_proxy", "https_proxy", "all_proxy", "ws_proxy", "wss_proxy" }) info.EnvironmentVariables[key] = proxy;
            string bypass = info.EnvironmentVariables["NO_PROXY"] ?? info.EnvironmentVariables["no_proxy"] ?? "";
            string localBypass = string.Join(",", (bypass + ",localhost,127.0.0.1,::1").Split(',').Select(value => value.Trim()).Where(value => value.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase));
            info.EnvironmentVariables["NO_PROXY"] = localBypass; info.EnvironmentVariables["no_proxy"] = localBypass;
            info.EnvironmentVariables["NODE_USE_ENV_PROXY"] = "1";
            if (profile.Mode == "electron") info.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
            if (profile.Id == "grokbot")
            {
                info.EnvironmentVariables["SAND_SYSTEM_PROXY"] = "1";
                info.EnvironmentVariables["SAND_HTTPS_PROXY"] = proxy;
                info.EnvironmentVariables["SAND_NO_PROXY"] = localBypass;
            }
            return info;
        }
        // Windows command-line quoting follows CommandLineToArgvW / CRT rules,
        // including backslashes immediately before quotes or the closing quote.
        internal static string QuoteArgument(string value)
        {
            StringBuilder result = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { result.Append('\\', slashes * 2 + 1); result.Append('"'); }
                else { result.Append('\\', slashes); result.Append(c); }
                slashes = 0;
            }
            result.Append('\\', slashes * 2); result.Append('"'); return result.ToString();
        }
        internal static LaunchResult Launch(ApplicationProfile profile, int port, Func<ProcessStartInfo, Process> start = null)
        {
            string path = ApplicationDiscovery.Resolve(profile);
            string identity;
            using (SHA256 hash = SHA256.Create()) identity = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(path.ToUpperInvariant()))).Replace("-", "");
            using (Mutex launchLock = new Mutex(false, "Local\\CodexProxy.Application." + identity))
            {
                bool entered = false;
                try
                {
                    try { entered = launchLock.WaitOne(0); } catch (AbandonedMutexException) { entered = true; }
                    if (!entered) return new LaunchResult(false, "这个应用正在启动，请稍候。");
                    DiagnosticStatus status = Check(profile, port);
                    if (!status.RuntimeReadyNow) return new LaunchResult(false, status.Remediation + " " + status.BlockingMessage);
                    path = status.ExecutablePath;
                    using (Process process = start == null ? Process.Start(StartInfo(profile, path, port)) : start(StartInfo(profile, path, port)))
                    {
                        if (process == null) return new LaunchResult(false, "系统未能创建应用进程。");
                        bool exited = process.WaitForExit(1500);
                        if (exited && (process.ExitCode != 0 || profile.Mode == "electron" && !IsRunning(path, profile))) return new LaunchResult(false, profile.Name + " 启动后立即退出（退出码 " + process.ExitCode + "），请查看应用自身的日志。");
                        return new LaunchResult(true, profile.Name + " 已在代理环境中启动。");
                    }
                }
                catch (Exception ex) { return new LaunchResult(false, "启动 " + profile.Name + " 失败：" + ex.Message); }
                finally { if (entered) launchLock.ReleaseMutex(); }
            }
        }
    }
}
