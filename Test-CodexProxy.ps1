[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $projectRoot 'CodexProxy.config.psd1'
$launcherPath = Join-Path $projectRoot 'Start-CodexProxy.ps1'
$iconPath = Join-Path $projectRoot 'assets\codex-official-transparent.ico'

Import-Module -Name $modulePath -Force
$config = Get-CodexProxyConfig -Path $configPath

$listener = Get-CodexProxyListener -Config $config
$listenerProcess = if ($listener) { Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue } else { $null }
$package = Get-CodexPackage -Config $config
$appInfo = $null
$appError = $null
$innerScriptReady = $false
$innerScriptError = $null
if ($package) {
    try {
        $appInfo = Get-CodexApplicationInfo -Package $package -Config $config
        $cacheCli = Join-Path (Join-Path $env:LOCALAPPDATA $config.HelperCachePath) 'codex.exe'
        $innerScript = New-CodexProxyInnerScript `
            -ExecutablePath $appInfo.ExecutablePath `
            -CodexCliPath $cacheCli `
            -ProxyUrl $config.ProxyUrl
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseInput(
            $innerScript,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null
        $innerScriptReady = $parseErrors.Count -eq 0
        if (-not $innerScriptReady) {
            $innerScriptError = $parseErrors.Message -join '; '
        }
    }
    catch { $appError = $_.Exception.Message }
}

$runningProcesses = if ($package) { @(Get-CodexPackageProcess -Package $package) } else { @() }
$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath $config.ShortcutName
$shortcutReady = $false
$shortcutTarget = $null
$shortcutArguments = $null
if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcutTarget = $shortcut.TargetPath
    $shortcutArguments = $shortcut.Arguments
    $shortcutReady = $shortcut.Arguments.IndexOf($launcherPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

$globalProxyVariables = @()
foreach ($scope in @('User', 'Machine')) {
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'WS_PROXY', 'WSS_PROXY')) {
        $value = [Environment]::GetEnvironmentVariable($name, $scope)
        if ($value) {
            $globalProxyVariables += "$scope/$name=$value"
        }
    }
}

[pscustomobject]@{
    ProjectRoot                 = $projectRoot
    ProxyUrl                   = $config.ProxyUrl
    ProxyListening             = [bool]$listener
    ProxyProcess               = if ($listenerProcess) { $listenerProcess.ProcessName } else { $null }
    CodexInstalled             = [bool]$package
    CodexVersion               = if ($package) { $package.Version.ToString() } else { $null }
    CodexApplicationReady      = [bool]$appInfo
    CodexApplicationError      = $appError
    InnerLaunchScriptReady     = $innerScriptReady
    InnerLaunchScriptError     = $innerScriptError
    CodexCurrentlyRunning      = $runningProcesses.Count -gt 0
    CodexRunningProcessCount   = $runningProcesses.Count
    LauncherPresent            = Test-Path -LiteralPath $launcherPath -PathType Leaf
    IconPresent                = Test-Path -LiteralPath $iconPath -PathType Leaf
    DesktopShortcut            = $shortcutPath
    DesktopShortcutReady       = $shortcutReady
    DesktopShortcutTarget      = $shortcutTarget
    DesktopShortcutArguments   = $shortcutArguments
    GlobalProxyVariables       = if ($globalProxyVariables.Count) { $globalProxyVariables -join '; ' } else { '(none)' }
    ReadyToLaunchAfterCodexExit = [bool]($listener -and $package -and $appInfo -and $innerScriptReady -and $shortcutReady)
} | Format-List
