using System;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Data;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Shell;
using Microsoft.Win32;

namespace CodexProxyDesktop
{
    public sealed class PageVisibilityConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture) { return string.Equals(value as string, parameter as string, StringComparison.Ordinal) ? Visibility.Visible : Visibility.Collapsed; }
        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) { return Binding.DoNothing; }
    }
    public sealed class EqualsConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture) { return object.Equals(value, parameter); }
        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) { return Binding.DoNothing; }
    }
    internal static class Ui
    {
        internal static bool AnimationsEnabled = true;
        internal static bool IsDark { get; private set; }
        internal static event EventHandler ThemeChanged;
        private static string currentPalette;
        internal static void Initialize()
        {
            if (Application.Current == null) throw new InvalidOperationException("A desktop Application is required.");
            if (!Application.Current.Resources.Contains("Canvas"))
            {
                Application.Current.Resources.MergedDictionaries.Add((ResourceDictionary)ReadXaml("Colors.Light.xaml"));
                Application.Current.Resources.MergedDictionaries.Add((ResourceDictionary)ReadXaml("Theme.xaml"));
            }
        }
        internal static object ReadXaml(string name)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream stream = assembly.GetManifestResourceStream(name))
            {
                if (stream == null) throw new FileNotFoundException("Missing desktop resource: " + name);
                using (StreamReader reader = new StreamReader(stream))
                    return XamlReader.Parse(reader.ReadToEnd().Replace("clr-namespace:CodexProxyDesktop\"", "clr-namespace:CodexProxyDesktop;assembly=" + assembly.GetName().Name + "\""));
            }
        }
        internal static void ApplyTheme(string theme)
        {
            bool dark = theme == "dark" || theme == "system" && SystemUsesDarkTheme();
            string palette = SystemParameters.HighContrast ? "contrast" : dark ? "dark" : "light";
            if (palette == currentPalette) return;
            currentPalette = palette; IsDark = dark;
            ResourceDictionary colors = (ResourceDictionary)ReadXaml(dark ? "Colors.Dark.xaml" : "Colors.Light.xaml");
            if (SystemParameters.HighContrast)
            {
                foreach (string key in new[] { "Canvas", "Sidebar", "Surface", "Subtle", "Hover", "SuccessSoft", "DangerSoft", "WarningSoft" }) colors[key] = SystemColors.WindowBrush;
                foreach (string key in new[] { "Text", "Secondary", "Muted", "Success", "Danger", "Warning", "Line", "StrongLine" }) colors[key] = SystemColors.WindowTextBrush;
                foreach (string key in new[] { "Accent", "AccentHover", "AccentSoft" }) colors[key] = SystemColors.HighlightBrush;
                foreach (string key in new[] { "OnAccent", "AccentText" }) colors[key] = SystemColors.HighlightTextBrush;
            }
            Application.Current.Resources.MergedDictionaries[0] = colors;
            if (ThemeChanged != null) ThemeChanged(null, EventArgs.Empty);
        }
        private static bool SystemUsesDarkTheme()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize")) return key != null && Convert.ToInt32(key.GetValue("AppsUseLightTheme", 1)) == 0;
            }
            catch { return false; }
        }
        internal static void ConfigureWindow(Window window)
        {
            WindowChrome.SetWindowChrome(window, new WindowChrome { CaptionHeight = 40, ResizeBorderThickness = new Thickness(6), CornerRadius = new CornerRadius(0), GlassFrameThickness = new Thickness(0), UseAeroCaptionButtons = false });
            window.SourceInitialized += delegate
            {
                try { int enabled = IsDark ? 1 : 0; DwmSetWindowAttribute(new WindowInteropHelper(window).Handle, 20, ref enabled, sizeof(int)); }
                catch { }
            };
        }
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr handle, int attribute, ref int value, int size);
    }
}
