using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using CodexProxyDesktop;

[assembly: System.Reflection.AssemblyTitle("Codex Proxy Setup")]
[assembly: System.Reflection.AssemblyDescription("Codex Proxy Windows 安装向导")]
[assembly: System.Reflection.AssemblyCompany("Codex Proxy Community")]
[assembly: System.Reflection.AssemblyProduct("Codex Proxy")]
[assembly: System.Reflection.AssemblyVersion("4.1.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("4.1.0.0")]

namespace CodexProxySetup
{
    internal interface IInstallerRuntime : IDisposable
    {
        InstallationDetectionResult Detect();
        ProcessResult Install(string directory, bool desktopShortcut, bool startMenuShortcut);
        void Launch(string directory);
    }
    internal sealed class InstallerRuntime : IInstallerRuntime
    {
        private readonly RuntimeBridge bridge = new RuntimeBridge(AppDomain.CurrentDomain.BaseDirectory);
        public InstallationDetectionResult Detect() { return bridge.DetectInstallation(); }
        public ProcessResult Install(string directory, bool desktopShortcut, bool startMenuShortcut) { return bridge.Install(directory, desktopShortcut, startMenuShortcut); }
        public void Launch(string directory) { Process.Start(new ProcessStartInfo(Path.Combine(directory, "CodexProxy.exe")) { WorkingDirectory = directory, UseShellExecute = true }); }
        public void Dispose() { bridge.Dispose(); }
    }
    internal sealed class SetupViewModel : Observable, IDisposable
    {
        private readonly IInstallerRuntime runtime;
        private bool detecting = true, installing, complete, detectionFailed;
        private string path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexProxy");
        private string error = "", detectedPath;
        public string DetectionText { get; private set; }
        public bool DesktopShortcut { get; set; }
        public bool StartMenuShortcut { get; set; }
        public bool LaunchAfterInstall { get; set; }
        public ICommand InstallCommand { get; private set; }
        internal event EventHandler FinishRequested;
        internal SetupViewModel(IInstallerRuntime service)
        {
            runtime = service; DesktopShortcut = true; StartMenuShortcut = true; LaunchAfterInstall = true;
            DetectionText = "正在检查已有安装…";
            InstallCommand = new AsyncCommand(InstallAsync, () => CanInstall, ex => { error = ex.Message; Changed(""); });
        }
        public string Version { get { return Product.Version; } }
        public string Stage { get { return complete ? "complete" : installing ? "installing" : "options"; } }
        public string Title { get { return complete ? "安装完成" : installing ? "正在准备你的工作空间" : IsUpgrade ? "升级 Codex Proxy" : "安装 Codex Proxy"; } }
        public string Description { get { return complete ? "欢迎使用全新的 Codex Proxy。" : installing ? "请稍候，通常只需要几秒钟。" : IsUpgrade ? "在原目录更新程序，保留你的代理端口与偏好。" : "设置一次，让每次启动都更轻松。"; } }
        public string ActionLabel { get { return complete ? "完成" : detectionFailed ? "重试检测" : installing ? "正在安装…" : IsUpgrade ? "升级到 " + Version : "开始安装"; } }
        public bool IsUpgrade { get { return !string.IsNullOrWhiteSpace(detectedPath); } }
        public bool OptionsEnabled { get { return !detecting && !installing && !complete; } }
        public bool CanBrowse { get { return OptionsEnabled && !IsUpgrade; } }
        public bool CanClose { get { return !installing; } }
        public bool ShowCancel { get { return !complete; } }
        public bool CanInstall { get { return complete || !detecting && !installing && (detectionFailed || PathError.Length == 0); } }
        public string InstallDirectory { get { return path; } set { if (!IsUpgrade) path = value; Changed("InstallDirectory", "PathError", "CanInstall"); } }
        public string Error { get { return error; } }
        public string PathError
        {
            get
            {
                try
                {
                    if (string.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) || Path.GetPathRoot(path).Length < 3) return "请选择完整的安装目录路径。";
                    string full = Path.GetFullPath(path).TrimEnd('\\');
                    return full.Equals(Path.GetPathRoot(full).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) ? "请使用磁盘根目录下的子文件夹。" : "";
                }
                catch { return "安装目录包含无效字符。"; }
            }
        }
        internal async Task DetectAsync()
        {
            detecting = true; error = ""; Changed("");
            try { ApplyDetection(await Task.Run(() => runtime.Detect())); }
            catch (Exception ex) { detecting = false; detectionFailed = true; error = ex.Message; DetectionText = "无法确认已有安装，请重试检测。"; Changed(""); }
        }
        internal void ReportError(string message) { error = message; Changed("Error"); }
        internal void ApplyDetection(InstallationDetectionResult detected)
        {
            detecting = false; detectionFailed = false;
            if (detected.Found && !string.IsNullOrWhiteSpace(detected.InstallDirectory))
            {
                detectedPath = Path.GetFullPath(detected.InstallDirectory); path = detectedPath;
                DetectionText = "已发现版本 " + detected.InstalledVersion + " · 将在原目录覆盖升级。";
            }
            else if (detected.Errors != null && detected.Errors.Length > 0)
            {
                detectionFailed = true; DetectionText = "部分安装记录读取失败，请重试检测。"; error = string.Join("；", detected.Errors);
            }
            else DetectionText = "准备全新安装 · 安装后可在设置中修改代理端口。";
            Changed("");
        }
        internal async Task InstallAsync()
        {
            if (complete) { if (FinishRequested != null) FinishRequested(this, EventArgs.Empty); return; }
            if (detectionFailed) { await DetectAsync(); return; }
            if (!CanInstall) return;
            installing = true; error = ""; path = Path.GetFullPath(path).TrimEnd('\\'); Changed("");
            try
            {
                ProcessResult result = await Task.Run(() => runtime.Install(path, DesktopShortcut, StartMenuShortcut));
                if (result.ExitCode != 0) throw new InvalidOperationException(string.IsNullOrWhiteSpace(result.StandardError) ? result.StandardOutput.Trim() : result.StandardError.Trim());
                complete = true;
                if (LaunchAfterInstall)
                {
                    try { runtime.Launch(path); }
                    catch (Exception ex) { error = "安装成功，但打开程序失败：" + ex.Message; }
                }
            }
            catch (Exception ex) { error = "安装未完成：" + ex.Message; LogStore.Append(Path.Combine(Product.DataDirectory, "logs"), "ERROR", error); }
            finally { installing = false; Changed(""); }
        }
        public void Dispose() { runtime.Dispose(); }
    }
    internal sealed class SetupWindow
    {
        internal readonly Window View;
        internal SetupWindow(SetupViewModel model, bool detectOnLoad)
        {
            Ui.Initialize(); Ui.ApplyTheme("system");
            View = (Window)Ui.ReadXaml("SetupWindow.xaml"); View.DataContext = model; Ui.ConfigureWindow(View);
            ((Button)View.FindName("CloseButton")).Click += delegate { View.Close(); };
            ((Button)View.FindName("CancelButton")).Click += delegate { View.Close(); };
            ((Button)View.FindName("BrowseButton")).Click += delegate
            {
                try { string selected = NativeFolderPicker.Select(View, "选择 Codex Proxy 安装目录"); if (selected != null) model.InstallDirectory = selected; }
                catch (Exception ex) { model.ReportError("目录选择器无法打开：" + ex.Message); }
            };
            ((Button)View.FindName("OpenFolderButton")).Click += delegate
            {
                try { Process.Start("explorer.exe", "\"" + model.InstallDirectory + "\""); }
                catch (Exception ex) { model.ReportError("打开目录失败：" + ex.Message); }
            };
            View.Closing += delegate(object sender, System.ComponentModel.CancelEventArgs e) { e.Cancel = !model.CanClose; };
            model.FinishRequested += delegate { View.Close(); };
            if (detectOnLoad) View.Loaded += async delegate { await model.DetectAsync(); };
        }
    }
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            IntPtr existing = FindWindow(null, "Codex Proxy 安装向导");
            if (existing != IntPtr.Zero) { ShowWindow(existing, 9); SetForegroundWindow(existing); return; }
            bool created;
            using (Mutex mutex = new Mutex(true, "Local\\CodexProxy.Setup.Instance", out created))
            {
                if (!created) return;
                try
                {
                    Application app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
                    using (SetupViewModel model = new SetupViewModel(new InstallerRuntime())) app.Run(new SetupWindow(model, true).View);
                }
                catch (Exception ex) { MessageBox.Show("安装向导无法打开：" + ex.Message, "Codex Proxy", MessageBoxButton.OK, MessageBoxImage.Error); Environment.ExitCode = 1; }
            }
        }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr FindWindow(string className, string title);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    }
    internal static class NativeFolderPicker
    {
        internal static string Select(Window owner, string title)
        {
            IFileDialog dialog = (IFileDialog)new FileOpenDialog();
            try
            {
                dialog.SetOptions(0x20 | 0x40 | 0x800); // Pick folders, filesystem only, existing directory.
                dialog.SetTitle(title);
                int result = dialog.Show(new WindowInteropHelper(owner).Handle);
                if (result == unchecked((int)0x800704C7)) return null;
                Marshal.ThrowExceptionForHR(result);
                IShellItem item; dialog.GetResult(out item);
                try { string path; item.GetDisplayName(0x80058000, out path); return path; }
                finally { Marshal.ReleaseComObject(item); }
            }
            finally { Marshal.ReleaseComObject(dialog); }
        }
        [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")] private class FileOpenDialog { }
        [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IFileDialog
        {
            [PreserveSig] int Show(IntPtr owner);
            void SetFileTypes(uint count, IntPtr specs); void SetFileTypeIndex(uint index); void GetFileTypeIndex(out uint index);
            void Advise(IntPtr events, out uint cookie); void Unadvise(uint cookie); void SetOptions(uint options); void GetOptions(out uint options);
            void SetDefaultFolder(IShellItem item); void SetFolder(IShellItem item); void GetFolder(out IShellItem item); void GetCurrentSelection(out IShellItem item);
            void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name); void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title); void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label); void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
            void GetResult(out IShellItem item); void AddPlace(IShellItem item, uint alignment); void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
            void Close(int result); void SetClientGuid(ref Guid guid); void ClearClientData(); void SetFilter(IntPtr filter);
        }
        [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem
        {
            void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr value); void GetParent(out IShellItem parent);
            void GetDisplayName(uint type, [MarshalAs(UnmanagedType.LPWStr)] out string name); void GetAttributes(uint mask, out uint attributes); void Compare(IShellItem item, uint hint, out int order);
        }
    }
}
