using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;

namespace CodexProxyDesktop
{
    internal sealed class ApplicationEditorModel : Observable
    {
        private readonly ApplicationProfile original;
        private string name, executable, arguments, port, failure = "";
        private bool automatic, defaultPort, electron;
        internal ApplicationEditorModel(ApplicationProfile profile, string detectedPath, int defaultProxyPort = 7891)
        {
            original = profile == null ? new ApplicationProfile { Id = "custom-" + Guid.NewGuid().ToString("N"), Name = "", ExecutablePath = "", Mode = "environment", Arguments = new string[0] } : profile.Copy();
            name = original.Name; executable = original.ExecutablePath ?? ""; arguments = string.Join(Environment.NewLine, original.Arguments);
            automatic = original.IsBuiltIn && string.IsNullOrEmpty(executable); defaultPort = original.ProxyPort == 0;
            port = (defaultPort ? defaultProxyPort : original.ProxyPort).ToString(CultureInfo.InvariantCulture); electron = original.Mode == "electron";
            DetectedPath = string.IsNullOrWhiteSpace(detectedPath) ? "尚未识别到安装位置，可以手动选择程序文件。" : detectedPath;
        }
        public string Title { get { return original.IsBuiltIn ? original.Name + " · 启动配置" : original.Name.Length == 0 ? "添加应用" : "编辑应用"; } }
        public string Name { get { return name; } set { name = value ?? ""; Update(); } }
        public string Executable { get { return executable; } set { executable = value ?? ""; Update(); } }
        public string Arguments { get { return arguments; } set { arguments = value ?? ""; Update(); } }
        public string Port { get { return port; } set { port = value ?? ""; Update(); } }
        public bool UseAutomatic { get { return automatic; } set { automatic = value; Update(); } }
        public bool UseDefaultPort { get { return defaultPort; } set { defaultPort = value; Update(); } }
        public bool ElectronMode { get { return electron; } set { electron = value; Update(); } }
        public bool EnvironmentMode { get { return !electron; } set { if (value) { electron = false; Update(); } } }
        public bool CanRename { get { return !original.IsBuiltIn; } }
        public bool CanRemove { get { return !original.IsBuiltIn && original.Name.Length > 0; } }
        public bool IsDesktopExe { get { return !original.IsCodex; } }
        public bool CanAutoDetect { get { return original.IsBuiltIn && !original.IsCodex; } }
        public bool CanChooseExecutable { get { return IsDesktopExe && !automatic; } }
        public bool CanChoosePort { get { return !defaultPort; } }
        public string DetectedPath { get; private set; }
        public string ModeHint { get { return electron ? "适合 Cursor、Grok Bot、VS Code 等 Electron 应用，同时设置代理参数和环境变量。" : "适合支持代理环境变量的程序。此模式的实际联网行为由应用自身决定。"; } }
        public bool CanSave { get { return ValidationError.Length == 0; } }
        public string Error { get { return failure.Length > 0 ? failure : ValidationError; } }
        public bool HasError { get { return Error.Length > 0; } }
        private string ValidationError
        {
            get
            {
                try { Build(); return ""; }
                catch (Exception ex) { return ex.Message; }
            }
        }
        internal ApplicationProfile Build()
        {
            ApplicationProfile result = original.Copy();
            result.Name = name.Trim(); result.ExecutablePath = original.IsCodex || automatic ? "" : executable.Trim();
            result.Mode = original.IsCodex ? "codex" : electron ? "electron" : "environment";
            result.Arguments = original.IsCodex ? new string[0] : arguments.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.None).Where(arg => arg.Length > 0).ToArray();
            int parsed;
            if (!defaultPort && (!int.TryParse(port, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) || parsed < 1 || parsed > 65535)) throw new InvalidDataException("请输入 1–65535 之间的代理端口。");
            result.ProxyPort = defaultPort ? 0 : int.Parse(port, CultureInfo.InvariantCulture);
            ApplicationProfile.Validate(result);
            if (!string.IsNullOrEmpty(result.ExecutablePath) && !File.Exists(result.ExecutablePath)) throw new FileNotFoundException("选中的程序文件不存在，请重新选择。");
            return result;
        }
        internal void Fail(Exception ex) { failure = ex.Message; Changed(""); }
        private void Update() { failure = ""; Changed(""); }
    }

    internal sealed class ApplicationEditor
    {
        internal readonly Window View;
        internal readonly ApplicationEditorModel Model;
        internal ApplicationEditor(Window owner, WorkspaceViewModel workspace, ApplicationProfile profile)
        {
            Model = new ApplicationEditorModel(profile, profile == null || profile.IsCodex ? "" : workspace.ResolveExecutable(profile), workspace.DefaultProxyPort);
            View = (Window)Ui.ReadXaml("ApplicationEditor.xaml"); View.Owner = owner; View.DataContext = Model;
            View.Height = Math.Min(View.Height, Math.Max(View.MinHeight, SystemParameters.WorkArea.Height - 48));
            Ui.ConfigureWindow(View);
            Find<Button>("CancelButton").Click += delegate { View.DialogResult = false; };
            Find<Button>("CloseEditorButton").Click += delegate { View.DialogResult = false; };
            Find<Button>("BrowseButton").Click += delegate {
                OpenFileDialog dialog = new OpenFileDialog { Title = "选择应用程序", Filter = "Windows 应用程序 (*.exe)|*.exe", CheckFileExists = true, Multiselect = false };
                if (dialog.ShowDialog(View) == true) { Model.Executable = dialog.FileName; if (Model.Name.Length == 0) Model.Name = Path.GetFileNameWithoutExtension(dialog.FileName); }
            };
            Find<Button>("SaveApplicationButton").Click += delegate { try { workspace.SaveApplication(Model.Build()); View.DialogResult = true; } catch (Exception ex) { Model.Fail(ex); } };
            Find<Button>("RemoveApplicationButton").Click += delegate { try { workspace.RemoveApplication(profile); View.DialogResult = true; } catch (Exception ex) { Model.Fail(ex); } };
        }
        private T Find<T>(string name) where T : class { return (T)View.FindName(name); }
    }
}
