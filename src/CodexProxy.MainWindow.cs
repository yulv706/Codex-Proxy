using System;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Microsoft.Win32;

namespace CodexProxyDesktop
{
    internal sealed class MainWindow : IDisposable
    {
        internal readonly Window View;
        private readonly WorkspaceViewModel model;
        private readonly DispatcherTimer toastTimer;
        internal MainWindow(WorkspaceViewModel viewModel)
        {
            model = viewModel;
            Ui.Initialize(); Ui.ApplyTheme(model.Theme);
            View = (Window)Ui.ReadXaml("MainWindow.xaml"); View.DataContext = model;
            View.Width = Math.Min(model.SavedWidth, Math.Max(820, SystemParameters.WorkArea.Width - 32));
            View.Height = Math.Min(model.SavedHeight, Math.Max(600, SystemParameters.WorkArea.Height - 32));
            Ui.ConfigureWindow(View);
            Find<Button>("MinimizeButton").Click += delegate { View.WindowState = WindowState.Minimized; };
            Find<Button>("MaximizeButton").Click += delegate { View.WindowState = View.WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized; };
            Find<Button>("CloseButton").Click += delegate { View.Close(); };
            Find<Button>("CopyDiagnosticButton").Click += delegate { CopyDiagnostic(); };
            Find<Button>("ExportLogsButton").Click += delegate { ExportLogs(); };
            View.InputBindings.Add(new KeyBinding(model.RefreshCommand, Key.F5, ModifierKeys.None));
            View.InputBindings.Add(new KeyBinding(model.LaunchCommand, Key.Enter, ModifierKeys.Control));
            View.PreviewKeyDown += OnKeyDown;
            View.SizeChanged += delegate { UpdateLayoutMode(); };
            model.AppearanceChanged += OnAppearanceChanged; model.PropertyChanged += OnModelChanged; model.ToastChanged += OnToastChanged;
            model.EditApplicationRequested += OnEditApplication;
            SystemEvents.UserPreferenceChanged += OnSystemThemeChanged;
            toastTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4) };
            toastTimer.Tick += delegate { toastTimer.Stop(); model.DismissToast(); };
            UpdateLayoutMode();
        }
        internal T Find<T>(string name) where T : class { return (T)View.FindName(name); }
        internal void UpdateLayoutMode()
        {
            bool compact = model.SidebarCollapsed || View.Width < 940;
            Find<ColumnDefinition>("SidebarColumn").Width = new GridLength(compact ? 72 : 210);
            foreach (string name in new[] { "BrandCaption", "WorkspaceCaption", "SidebarVersion" }) Find<UIElement>(name).Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
            foreach (string name in new[] { "OverviewNav", "ApplicationsNav", "DiagnosticsNav", "LogsNav", "SettingsNav" })
            {
                StackPanel panel = Find<RadioButton>(name).Content as StackPanel;
                if (panel != null && panel.Children.Count > 1) panel.Children[1].Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
            }
            Find<UIElement>("HeaderSubtitle").Visibility = View.Width < 1000 ? Visibility.Collapsed : Visibility.Visible;
            Find<UIElement>("MonitorFooter").Visibility = View.Width < 900 ? Visibility.Collapsed : Visibility.Visible;
        }
        private void OnAppearanceChanged(object sender, EventArgs e) { Ui.ApplyTheme(model.Theme); UpdateLayoutMode(); }
        private void OnModelChanged(object sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName != "SelectedPage" || !Ui.AnimationsEnabled || !SystemParameters.ClientAreaAnimation) return;
            string name = model.SelectedPage == "overview" ? "OverviewPage" : model.SelectedPage == "applications" ? "ApplicationsPage" : model.SelectedPage == "settings" ? "SettingsPage" : model.SelectedPage == "logs" ? "LogsPage" : "DiagnosticsPage";
            Find<UIElement>(name).BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0.3, 1, TimeSpan.FromMilliseconds(130)));
        }
        private void OnToastChanged(object sender, EventArgs e) { if (toastTimer == null) return; toastTimer.Stop(); if (model.ToastKind != "error") toastTimer.Start(); }
        private void OnSystemThemeChanged(object sender, UserPreferenceChangedEventArgs e) { if (!View.Dispatcher.HasShutdownStarted) View.Dispatcher.BeginInvoke(new Action(() => Ui.ApplyTheme(model.Theme))); }
        private void OnKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Escape) { model.DismissToast(); e.Handled = true; }
            else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.OemComma) { model.Navigate("settings"); e.Handled = true; }
            else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.F && model.SelectedPage == "logs") { Find<TextBox>("LogSearch").Focus(); e.Handled = true; }
            else if (e.Key == Key.System && e.SystemKey == Key.D5) { model.Navigate("applications"); e.Handled = true; }
            else if (e.Key == Key.System && e.SystemKey >= Key.D1 && e.SystemKey <= Key.D4) { model.Navigate(new[] { "overview", "diagnostics", "logs", "settings" }[(int)e.SystemKey - (int)Key.D1]); e.Handled = true; }
        }
        private void OnEditApplication(ApplicationProfile profile)
        {
            try { new ApplicationEditor(View, model, profile).View.ShowDialog(); }
            catch (Exception ex) { model.ShowToast("无法打开应用配置：" + ex.Message, "error"); }
        }
        private void CopyDiagnostic()
        {
            try { Clipboard.SetText(model.DiagnosticSummary); model.ShowToast("诊断摘要已复制", "success"); }
            catch (Exception ex) { model.ShowToast("复制失败：" + ex.Message, "error"); }
        }
        private void ExportLogs()
        {
            SaveFileDialog dialog = new SaveFileDialog { Title = "导出当前筛选的日志", FileName = "CodexProxy-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log", Filter = "日志文件 (*.log)|*.log|文本文件 (*.txt)|*.txt", AddExtension = true, OverwritePrompt = true };
            if (dialog.ShowDialog(View) != true) return;
            try { File.WriteAllText(dialog.FileName, model.ExportLogs(), new System.Text.UTF8Encoding(true)); model.ShowToast("日志已导出", "success"); }
            catch (Exception ex) { model.ShowToast("导出失败：" + ex.Message, "error"); }
        }
        public void Dispose()
        {
            toastTimer.Stop(); model.AppearanceChanged -= OnAppearanceChanged; model.PropertyChanged -= OnModelChanged; model.ToastChanged -= OnToastChanged;
            model.EditApplicationRequested -= OnEditApplication;
            SystemEvents.UserPreferenceChanged -= OnSystemThemeChanged; View.PreviewKeyDown -= OnKeyDown;
        }
    }
}
