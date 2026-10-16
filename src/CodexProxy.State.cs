using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Input;

namespace CodexProxyDesktop
{
    internal static class Product
    {
        internal const string Version = "4.1.0";
        internal static string DataDirectory
        {
            get
            {
                string directory = Environment.GetEnvironmentVariable("CODEX_PROXY_DATA_DIRECTORY");
                return string.IsNullOrWhiteSpace(directory) ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexProxy") : Path.GetFullPath(directory);
            }
        }
    }

    internal abstract class Observable : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        protected void Changed(params string[] names)
        {
            foreach (string name in names)
            {
                PropertyChangedEventHandler handler = PropertyChanged;
                if (handler != null) handler(this, new PropertyChangedEventArgs(name));
            }
            CommandManager.InvalidateRequerySuggested();
        }
    }

    internal sealed class ActionCommand : ICommand
    {
        private readonly Action<object> execute;
        private readonly Predicate<object> canExecute;
        internal ActionCommand(Action<object> action, Predicate<object> enabled = null) { execute = action; canExecute = enabled; }
        public bool CanExecute(object parameter) { return canExecute == null || canExecute(parameter); }
        public void Execute(object parameter) { if (CanExecute(parameter)) execute(parameter); }
        public event EventHandler CanExecuteChanged { add { CommandManager.RequerySuggested += value; } remove { CommandManager.RequerySuggested -= value; } }
    }

    internal sealed class AsyncCommand : ICommand
    {
        private readonly Func<Task> execute;
        private readonly Func<bool> canExecute;
        private readonly Action<Exception> onError;
        private bool running;
        internal AsyncCommand(Func<Task> action, Func<bool> enabled, Action<Exception> error) { execute = action; canExecute = enabled; onError = error; }
        public bool CanExecute(object parameter) { return !running && (canExecute == null || canExecute()); }
        public async void Execute(object parameter)
        {
            if (!CanExecute(parameter)) return;
            running = true;
            CommandManager.InvalidateRequerySuggested();
            try { await execute(); }
            catch (Exception ex) { onError(ex); }
            finally { running = false; CommandManager.InvalidateRequerySuggested(); }
        }
        public event EventHandler CanExecuteChanged { add { CommandManager.RequerySuggested += value; } remove { CommandManager.RequerySuggested -= value; } }
    }

    public sealed class DesktopPreferences
    {
        public string Theme { get; set; }
        public bool CloseToTray { get; set; }
        public bool AutoRefresh { get; set; }
        public bool SidebarCollapsed { get; set; }
        public double WindowWidth { get; set; }
        public double WindowHeight { get; set; }
        public DesktopPreferences() { Theme = "system"; CloseToTray = true; AutoRefresh = true; WindowWidth = 1100; WindowHeight = 760; }
        internal DesktopPreferences Copy() { return (DesktopPreferences)MemberwiseClone(); }
    }

    internal sealed class PreferencesStore
    {
        private readonly string path;
        internal string ReadWarning { get; private set; }
        internal PreferencesStore(string file) { path = file; }
        internal DesktopPreferences Load()
        {
            ReadWarning = null;
            try
            {
                if (!File.Exists(path)) return new DesktopPreferences();
                DesktopPreferences value = new JavaScriptSerializer().Deserialize<DesktopPreferences>(File.ReadAllText(path));
                if (value == null) throw new InvalidDataException("设置文件为空。");
                if (value.Theme != "light" && value.Theme != "dark" && value.Theme != "system") value.Theme = "system";
                value.WindowWidth = Clamp(value.WindowWidth, 820, 2000, 1100);
                value.WindowHeight = Clamp(value.WindowHeight, 600, 1400, 760);
                return value;
            }
            catch (Exception ex) { ReadWarning = "界面偏好读取失败，暂时使用默认设置：" + ex.Message; return new DesktopPreferences(); }
        }
        internal void Save(DesktopPreferences value)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path)));
            string temporary = path + ".writing-" + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(value), new UTF8Encoding(true));
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        private static double Clamp(double value, double min, double max, double fallback) { return double.IsNaN(value) || double.IsInfinity(value) ? fallback : Math.Max(min, Math.Min(max, value)); }
    }

    internal sealed class LogEntry
    {
        public DateTime Time { get; set; }
        public string Level { get; set; }
        public string Message { get; set; }
        public string Source { get; set; }
        public string TimeText { get { return Time == DateTime.MinValue ? "—" : Time.ToString("HH:mm:ss"); } }
        public string DateText { get { return Time == DateTime.MinValue ? "" : Time.ToString("MM-dd"); } }
    }

    internal static class LogStore
    {
        private static readonly object Gate = new object();
        private static readonly Regex EntryPattern = new Regex(@"^(?<time>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?)\s+\[(?<level>\w+)\]\s*(?<body>.*)$", RegexOptions.Compiled);
        internal static void Append(string directory, string level, string message)
        {
            try
            {
                lock (Gate)
                {
                    Directory.CreateDirectory(directory);
                    string path = Path.Combine(directory, "desktop.log");
                    if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024)
                    {
                        string rotated = path + ".1";
                        if (File.Exists(rotated)) File.Delete(rotated);
                        File.Move(path, rotated);
                    }
                    File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " [" + level + "] " + message.Replace("\r", " ").Replace("\n", " ") + Environment.NewLine, new UTF8Encoding(false));
                }
            }
            catch { /* Logging must never block a launch or hide its original error. */ }
        }
        internal static List<LogEntry> Read(string directory)
        {
            List<LogEntry> entries = new List<LogEntry>();
            foreach (string name in new[] { "launcher.log", "desktop.log" })
            {
                string path = Path.Combine(directory, name);
                if (!File.Exists(path)) continue;
                using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    bool truncated = stream.Length > 512 * 1024;
                    if (truncated) stream.Seek(-512 * 1024, SeekOrigin.End);
                    using (StreamReader reader = new StreamReader(stream, Encoding.UTF8, true))
                    {
                        if (truncated) reader.ReadLine();
                        string line;
                        while ((line = reader.ReadLine()) != null)
                        {
                            Match match = EntryPattern.Match(line);
                            DateTime time;
                            if (!match.Success || !DateTime.TryParse(match.Groups["time"].Value, out time)) continue;
                            entries.Add(new LogEntry { Time = time, Level = match.Groups["level"].Value.ToUpperInvariant(), Message = match.Groups["body"].Value, Source = name });
                        }
                    }
                }
            }
            return entries.OrderByDescending(entry => entry.Time).Take(500).ToList();
        }
        internal static string Format(IEnumerable<LogEntry> entries)
        {
            return string.Join(Environment.NewLine, entries.Select(entry => entry.Time.ToString("yyyy-MM-dd HH:mm:ss.fff") + " [" + entry.Level + "] [" + entry.Source + "] " + entry.Message));
        }
    }
}
