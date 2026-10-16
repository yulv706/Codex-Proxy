using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CodexProxyDesktop.Tests
{
    internal sealed class FixtureProxy : IDisposable
    {
        private readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        private readonly Thread worker;
        internal int Port;
        internal volatile bool Reject;
        internal string LastRequest;
        internal FixtureProxy()
        {
            listener.Start(); Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            worker = new Thread(Run) { IsBackground = true }; worker.Start();
        }
        private void Run()
        {
            try
            {
                while (true)
                using (TcpClient client = listener.AcceptTcpClient())
                using (NetworkStream stream = client.GetStream())
                {
                    stream.ReadTimeout = 3000;
                    StringBuilder request = new StringBuilder(); int value;
                    while (request.Length < 4096 && (value = stream.ReadByte()) >= 0) { request.Append((char)value); if (request.ToString().EndsWith("\r\n\r\n")) break; }
                    LastRequest = request.ToString();
                    byte[] response = Encoding.ASCII.GetBytes(Reject ? "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n" : "HTTP/1.1 200 Connection established\r\n\r\n"); stream.Write(response, 0, response.Length);
                }
            }
            catch (SocketException) { }
            catch (ObjectDisposedException) { }
            catch (IOException) { }
        }
        public void Dispose() { listener.Stop(); worker.Join(3000); }
    }
    internal static class MultiApplicationTests
    {
        private static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        private static async Task Idle(WorkspaceViewModel model) { Stopwatch timer = Stopwatch.StartNew(); while (model.IsWorking) { if (timer.ElapsedMilliseconds > 15000) throw new TimeoutException("Multi-app refresh timed out."); await Task.Delay(10); } }
        internal static void Fixture(string[] args, int index)
        {
            Dictionary<string, object> result = new Dictionary<string, object> { { "args", args } };
            foreach (string name in new[] { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "WS_PROXY", "WSS_PROXY", "http_proxy", "https_proxy", "all_proxy", "NO_PROXY", "no_proxy", "NODE_USE_ENV_PROXY" }) result[name] = Environment.GetEnvironmentVariable(name);
            File.WriteAllText(args[index + 1], new JavaScriptSerializer().Serialize(result));
            Thread.Sleep(20000);
        }
        internal static async Task VerifyWorkspace(WorkspaceViewModel model, MainWindow window, FakeRuntime fake, Action<string> render, string output)
        {
            Assert(model.Applications.Select(app => app.Id).SequenceEqual(new[] { "codex", "cursor", "grokbot" }), "Built-in applications missing.");
            fake.Status = FakeRuntime.Ready();
            window.Find<ComboBox>("ApplicationSelector").SelectedItem = model.Applications.First(app => app.Id == "cursor");
            await Idle(model);
            Assert(model.ApplicationName == "Cursor" && fake.LastCheckedId == "cursor" && model.LaunchLabel == "启动 Cursor" && fake.Catalog.SelectedId == "cursor", "App selector did not update status and persistence.");
            await model.LaunchAsync(); Assert(fake.LastLaunchedId == "cursor", "Wrong application was launched.");
            using (ManualResetEvent gate = new ManualResetEvent(false))
            {
                fake.LaunchGate = gate; Task launch = model.LaunchAsync(); await Task.Delay(25);
                model.SelectedApplication = model.Applications.First(app => app.Id == "grokbot");
                Assert(model.ApplicationName == "Cursor" && !model.CanChangeApplication, "Application changed during a launch.");
                gate.Set(); await launch; fake.LaunchGate = null;
            }
            foreach (string id in new[] { "cursor", "grokbot" })
            {
                model.SelectedApplication = model.Applications.First(app => app.Id == id); await Idle(model);
                fake.Status.ExecutablePath = id == "cursor" ? @"D:\install\cursor\cursor\Cursor.exe" : @"D:\install\GrokBot\Grok Bot.exe";
                fake.Status.ApplicationVersion = id == "cursor" ? "3.25.6" : "0.70.2";
                model.ApplyStatus(fake.Status, 0.1); model.Navigate("overview"); model.DismissToast();
                await Task.Delay(25); render("light-1100-" + id);
                model.Navigate("diagnostics"); render("light-1100-" + id + "-diagnostics");
            }
            ApplicationProfile custom = new ApplicationProfile { Id = "custom-" + Guid.NewGuid().ToString("N"), Name = "测试应用", ExecutablePath = System.Reflection.Assembly.GetExecutingAssembly().Location, Mode = "environment", Arguments = new[] { "folder with spaces", "--example" }, ProxyPort = 8999 };
            model.SaveApplication(custom); await Idle(model);
            Assert(model.Applications.Count == 4 && model.SelectedApplication.Id == custom.Id && model.ProxyScopeNote.Contains("测试应用"), "Custom app save failed.");
            ApplicationProfile edited = model.SelectedApplication.Copy(); edited.ProxyPort = 9002; edited.Name = "测试应用 2";
            model.SaveApplication(edited); await Idle(model); Assert(fake.Catalog.Applications.First(app => app.Id == custom.Id).ProxyPort == 9002, "Per-app port not saved.");
            model.Navigate("applications"); model.DismissToast(); await Task.Delay(25); render("light-1100-applications-custom");
            foreach (ApplicationProfile profile in new[] { model.Applications[0], model.Applications[1], edited, null })
            {
                ApplicationEditor editor = new ApplicationEditor(null, model, profile);
                editor.View.WindowStartupLocation = WindowStartupLocation.Manual; editor.View.Left = -15000; editor.View.Top = 0; editor.View.ShowInTaskbar = false; editor.View.ShowActivated = false; editor.View.Show();
                await Task.Delay(25);
                FrameworkElement root = (FrameworkElement)editor.View.Content;
                editor.View.Measure(new Size(640, 740)); editor.View.Arrange(new Rect(0, 0, 640, 740)); editor.View.UpdateLayout();
                root.Measure(new Size(640, 740)); root.Arrange(new Rect(0, 0, 640, 740)); root.UpdateLayout();
                foreach (TextBox input in EditorVisuals(root).OfType<TextBox>().Where(input => input.IsVisible)) Program.VerifyTextViewport(input);
                RenderTargetBitmap bitmap = new RenderTargetBitmap(640, 740, 96, 96, PixelFormats.Pbgra32); bitmap.Render(root);
                PngBitmapEncoder encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using (FileStream file = File.Create(Path.Combine(output, "editor-" + (profile == null ? "new" : profile.IsBuiltIn ? profile.Id : "custom") + ".png"))) encoder.Save(file);
                if (profile == null) { Assert(!editor.Model.CanSave, "Empty custom app is valid."); editor.Model.Name = "Test"; editor.Model.Executable = edited.ExecutablePath; Assert(editor.Model.CanSave, "Custom exe selection failed."); editor.Model.UseDefaultPort = false; editor.Model.Port = "70000"; Assert(!editor.Model.CanSave, "Invalid app port is valid."); }
                editor.View.Close();
            }
            model.RemoveApplication(edited); await Idle(model);
            Assert(model.Applications.Count == 3 && model.SelectedApplication.Id == "codex", "Custom removal did not restore selection.");
            bool rejected = false; try { model.RemoveApplication(model.Applications[0]); } catch (InvalidOperationException) { rejected = true; }
            Assert(rejected, "Built-in profile can be removed.");
            model.Navigate("overview"); fake.Status = FakeRuntime.Ready(); await model.RefreshAsync(false);
        }
        private static IEnumerable<DependencyObject> EditorVisuals(DependencyObject root)
        {
            yield return root;
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (DependencyObject child in EditorVisuals(VisualTreeHelper.GetChild(root, i))) yield return child;
        }
        internal static async Task VerifyRuntime(string root)
        {
            Directory.CreateDirectory(root);
            string catalogPath = Path.Combine(root, "applications.json"); ApplicationStore store = new ApplicationStore(catalogPath);
            ApplicationCatalog catalog = store.Load(); catalog.SelectedId = "cursor"; catalog.Applications[1].ProxyPort = 8080; store.Save(catalog);
            Assert(store.Load().SelectedId == "cursor" && store.Load().Applications[1].ProxyPort == 8080, "Catalog did not round-trip.");
            catalog.Applications.RemoveAt(2); store.Save(catalog); Assert(store.Load().Applications.Count == 3, "Missing built-in wasn't restored.");
            File.WriteAllText(catalogPath, "corrupt"); Assert(store.Load().Applications.Count == 3 && store.ReadWarning.Length > 0 && File.ReadAllText(catalogPath) == "corrupt", "Corrupt catalog was overwritten on read.");
            store.Save(new ApplicationCatalog()); Assert(Directory.GetFiles(root, "*.bak").Any(path => File.ReadAllText(path) == "corrupt"), "Repair did not preserve corrupt catalog.");
            string fixturePath = Path.Combine(root, "Fixture 应用 with spaces.exe"); File.Copy(System.Reflection.Assembly.GetExecutingAssembly().Location, fixturePath, true);
            string marker = Path.Combine(root, "fixture-result.json");
            string[] payload = new[] { "--proxy-fixture", marker, "", "a b", "literal\"quote", @"C:\folder with spaces\", "汉字", "$(echo bad); & test" };
            var profile = new ApplicationProfile { Id = "custom-" + Guid.NewGuid().ToString("N"), Name = "Fixture", Mode = "environment", ExecutablePath = fixturePath, Arguments = payload };
            var inherited = new Dictionary<string, string>(); foreach (string key in new[] { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "NODE_USE_ENV_PROXY" }) inherited[key] = Environment.GetEnvironmentVariable(key);
            using (FixtureProxy proxy = new FixtureProxy())
            {
                DiagnosticStatus ready = await Task.Run(() => ApplicationLauncher.Check(profile, proxy.Port));
                Assert(ready.RuntimeReadyNow && proxy.LastRequest.StartsWith("CONNECT www.example.com:443"), "Proxy probe did not test CONNECT.");
                ApplicationProfile cursor = profile.Copy(); cursor.Id = "cursor"; cursor.Name = "Cursor"; cursor.Mode = "electron";
                Assert((await Task.Run(() => ApplicationLauncher.Check(cursor, proxy.Port))).ProxyReady && proxy.LastRequest.StartsWith("CONNECT api2.cursor.sh:443"), "Cursor probe used the wrong upstream.");
                ProcessStartInfo electron = ApplicationLauncher.StartInfo(cursor, fixturePath, proxy.Port);
                Assert(electron.Arguments.StartsWith("\"--proxy-server=http://127.0.0.1:" + proxy.Port) && electron.UseShellExecute == false, "Electron proxy flag missing.");
                ApplicationProfile grok = cursor.Copy(); grok.Id = "grokbot"; grok.Name = "Grok Bot";
                ProcessStartInfo grokInfo = ApplicationLauncher.StartInfo(grok, fixturePath, proxy.Port);
                Assert(grokInfo.EnvironmentVariables["SAND_SYSTEM_PROXY"] == "1" && grokInfo.EnvironmentVariables["SAND_HTTPS_PROXY"] == "http://127.0.0.1:" + proxy.Port, "Grok Bot proxy adapter is missing.");
                LaunchResult launched = await Task.Run(() => ApplicationLauncher.Launch(profile, proxy.Port)); Assert(launched.Success, launched.Message);
                Process[] children = Process.GetProcessesByName(Path.GetFileNameWithoutExtension(fixturePath));
                try
                {
                    Assert(children.Length == 1 && File.Exists(marker), "Fixture process did not launch.");
                    var result = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(marker));
                    string[] actual = ((System.Collections.IEnumerable)result["args"]).Cast<object>().Select(Convert.ToString).ToArray();
                    Assert(actual.SequenceEqual(payload), "Windows command-line quoting changed argument boundaries.");
                    foreach (string key in new[] { "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "WS_PROXY", "WSS_PROXY", "http_proxy", "https_proxy", "all_proxy" }) Assert(Convert.ToString(result[key]) == "http://127.0.0.1:" + proxy.Port, "Child proxy environment missing: " + key);
                    Assert(Convert.ToString(result["NO_PROXY"]).Contains("127.0.0.1") && Convert.ToString(result["NODE_USE_ENV_PROXY"]) == "1", "Local bypass or Node proxy environment missing.");
                    Assert(!(await Task.Run(() => ApplicationLauncher.Check(profile, proxy.Port))).RuntimeReadyNow, "Running app can be launched again.");
                    Assert(!(await Task.Run(() => ApplicationLauncher.Launch(profile, proxy.Port))).Success, "Running process was not guarded.");
                }
                finally { foreach (Process child in children) { if (!child.HasExited) child.Kill(); child.WaitForExit(5000); child.Dispose(); } }
                proxy.Reject = true; Assert(!(await Task.Run(() => ApplicationLauncher.Check(profile, proxy.Port))).ProxyReady, "Rejected proxy CONNECT was accepted.");
            }
            foreach (var pair in inherited) Assert(Environment.GetEnvironmentVariable(pair.Key) == pair.Value, "Parent proxy environment was modified.");
            profile.Arguments = new[] { "--no-proxy-server" }; bool invalid = false; try { ApplicationProfile.Validate(profile); } catch (InvalidDataException) { invalid = true; } Assert(invalid, "Conflicting proxy flag was accepted.");
            string[] discovery = ApplicationProfile.Defaults().Where(app => !app.IsCodex).Select(app => app.Name + ": " + ApplicationDiscovery.Resolve(app)).ToArray(); File.WriteAllLines(Path.Combine(root, "local-discovery.txt"), discovery);
        }
    }
}
