# Desktop 4.1

## Design reference

The rewrite studies [CC Switch](https://github.com/farion1231/cc-switch) at commit `8c2c89e0b4b685c728cd6764b1645bf27e84c123` (2026-10-16). Its implementation uses React, Tauri, reusable interface components and semantic theme tokens. The specific references are:

- `src/index.css`: semantic surface, foreground, state and action colors; independent light and dark palettes.
- `src/components/shell/Sidebar.tsx` and `AppPageHeader.tsx`: persistent navigation, collapsible sidebar and consistent page headers.
- `src/components/settings/SettingsLayout.tsx`: grouped rows, constrained content width, switches saved immediately and explicit save actions for input fields.
- `src/components/theme-provider.tsx`: persisted light/dark/system choice and live system appearance updates.
- `src/lib/toast.ts`: one coherent feedback channel, avoiding repeated stacked messages.

These principles are implemented independently in WPF for this Windows-only application. No CC Switch source, logos, or assets are copied. The existing Store-package launch and proxy verification code remains the execution boundary.

## Responsibilities

| Component | Responsibility |
| --- | --- |
| `CodexProxy.App.cs` | WPF application lifetime, single-instance events, tray and graceful shutdown |
| `CodexProxy.ViewModel.cs` | Observable UI state, asynchronous commands, diagnostics, launch and settings workflows |
| `CodexProxy.Runtime.cs` | Windows PowerShell bridge, process ownership, proxy configuration and typed diagnostic results |
| `CodexProxy.Applications.cs` | Application catalog, atomic storage, executable discovery, HTTP CONNECT checks, isolated process environments and per-executable launch locks |
| `CodexProxy.ApplicationEditor.cs` / `Desktop/ApplicationEditor.xaml` | Application editor, native executable picker, argument and per-app port validation |
| `CodexProxy.State.cs` | Commands, atomic preference storage, bounded shared-file log reading and log rotation |
| `CodexProxy.MainWindow.cs` | Native window behavior, clipboard, export and keyboard navigation |
| `CodexProxy.Ui.cs` | Theme application, accessibility-related system preferences and window chrome |
| `Desktop/Theme.xaml` | Semantic palette and shared control templates |
| `Desktop/Colors.Light.xaml` / `Colors.Dark.xaml` | Separate canonical light and dark color tokens, including text contrast |
| `Desktop/MainWindow.xaml` | Launch, application management, diagnostics, logs and settings views |
| `CodexProxy.Setup.cs` / `Desktop/SetupWindow.xaml` | Asynchronous installation detection and upgrade wizard using the same design system |
| `CodexProxy.files.psd1` | One product file manifest shared by installation and packaging |

## State and behavior

The UI binds to the view model. Long-running diagnostic, launch, installation and log operations run off the UI thread. Commands prevent duplicate execution and switching applications while a launch or check is in progress. A single runtime bridge owns its PowerShell workers and terminates them during shutdown. User applications have independent lifetimes and are not terminated when the launcher exits. Errors remain visible until dismissed; success messages expire. Status is never inferred from decorative UI or fabricated statistics.

Port changes are explicit, validated and atomic. Appearance and behavior preferences are saved immediately to `%LOCALAPPDATA%\CodexProxy\desktop-settings.json`, independently of the installation directory. `%LOCALAPPDATA%\CodexProxy\applications.json` stores the selected application, built-in overrides and custom applications; `ProxyPort = 0` follows the shared port. Built-in profiles are merged during reads so older catalogs gain built-ins. Malformed catalogs fall back without overwriting the original; an explicit save keeps an invalid-file backup. Startup registration is separate from UI preferences. Changing a port affects the next launch.

## Application adapters

Codex delegates to the existing Windows PowerShell launch kernel with an optional port override. Its Store identity, signature validation, update coordination and helper cache are unchanged. A missing Codex installation does not affect the other application profiles.

Cursor and Grok Bot discover executables through per-user and machine App Paths, uninstall records (both registry views), and standard installation locations. Automatic discovery chooses the highest installed file version, so a stale uninstall record does not select an older copy. Explicit paths take precedence. Custom-app process checks compare full executable paths. Built-in apps additionally compare product metadata for matching process names across installation locations, because another installed copy may own the same application session. Access-denied process inspection blocks launch rather than assuming the application is stopped.

Direct launches use `ProcessStartInfo` with `UseShellExecute = false`, a working directory beside the executable, and a private environment containing HTTP/HTTPS/ALL/WS/WSS proxy values plus local NO_PROXY entries. Electron profiles also receive `--proxy-server`. Windows argument quoting preserves spaces, quotes and trailing backslashes; no shell executes user arguments. An executable-path hash identifies each launch mutex. Readiness is checked again under the mutex just before creating the process. The runtime's process-start gate prevents creating a new application after shutdown.

The installed Grok Bot 0.70.2 source in `resources/app.asar` was inspected read-only: `dist/electron-main/main-core.cjs` supports `NODE_USE_ENV_PROXY`, `SAND_SYSTEM_PROXY`, `SAND_HTTPS_PROXY` and `SAND_NO_PROXY`. Its adapter supplies these process-local values alongside the common proxy environment. No installed application files or account settings are patched. [Cursor's staff explanation](https://forum.cursor.com/t/cursor-services-network-issues-since-3-9/165407/7) confirms HTTP_PROXY/HTTPS_PROXY support for newer Cursor AI transport. [Grok Bot proxy requirements](https://cursor.com/docs/grok-bot/proxies) describe the hosted-computer and streaming endpoints.

The proxy probe targets `api2.cursor.sh:443` for Cursor/Grok Bot and `www.example.com:443` for custom applications. It validates CONNECT acceptance, not authenticated application requests. Environment-only applications must implement proxy-variable support themselves. Existing running applications may predate the proxy environment, so the UI never identifies their traffic as verified.

The application supports light, dark and system themes, system high contrast, keyboard focus, resize-aware navigation and system animation preferences. Window chrome preserves native drag, resize, minimize and maximize behavior. Folder selection and log export use Windows file dialogs.

The logs page reads up to 512 KiB from each current log file and shows at most 500 entries. It supports level and text filters; export includes the current filtered results. No session, history, credential, or request-body data is accessed.

## Verification

The Windows PowerShell test runner covers the existing launch kernel, desktop compilation, single-instance and tray lifecycle, native UI resources, view-model commands, concurrent-action rejection, persistence, corruption handling, log filters, setup detection/upgrade states and package consistency. Desktop fixtures render each page in both themes at normal and compact sizes, plus application editors, per-application diagnostics, error and installation states. An isolated executable fixture and local CONNECT server exercise the actual direct-launch pipeline, command-line boundaries, child environment, running-process guard and rejected proxy responses. Tests never launch the installed Codex, Cursor or Grok Bot, change their account settings, or change startup registration.
