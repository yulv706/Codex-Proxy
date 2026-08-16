[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $projectRoot 'CodexProxy.config.psd1'
$logPath = Join-Path $projectRoot 'logs\launcher.log'

try {
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Use Windows PowerShell 5.1 to launch Codex Proxy.'
    }

    Import-Module -Name $modulePath -Force
    $config = Get-CodexProxyConfig -Path $configPath
    Write-CodexProxyLog -Path $logPath -Message "Launch requested through $($config.ProxyUrl)."

    $listener = Get-CodexProxyListener -Config $config
    if (-not $listener) {
        throw "The local proxy $($config.ProxyHost):$($config.ProxyPort) is not listening. Start the proxy client first."
    }

    $listenerProcess = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    $listenerName = if ($listenerProcess) { $listenerProcess.ProcessName } else { 'unknown' }
    Write-CodexProxyLog -Path $logPath -Message "Proxy listener is ready (PID $($listener.OwningProcess), $listenerName)."

    $package = Get-CodexPackage -Config $config
    if (-not $package) {
        throw 'The OpenAI Codex Windows app is not installed.'
    }
    Write-CodexProxyLog -Path $logPath -Message "Using Codex package $($package.Version)."

    $runningProcesses = @(Get-CodexPackageProcess -Package $package)
    if ($runningProcesses.Count -gt 0) {
        throw 'Codex is already running. Fully quit Codex, then use Codex-Proxy on the desktop.'
    }

    $appInfo = Get-CodexApplicationInfo -Package $package -Config $config
    $helperInfo = Sync-CodexHelpers -ApplicationInfo $appInfo -Config $config
    Write-CodexProxyLog -Path $logPath -Message "Helper cache ready at $($helperInfo.CacheDirectory); refreshed=$($helperInfo.Refreshed)."

    $innerScript = New-CodexProxyInnerScript `
        -ExecutablePath $appInfo.ExecutablePath `
        -CodexCliPath $helperInfo.CliPath `
        -ProxyUrl $config.ProxyUrl

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($innerScript))
    Invoke-CommandInDesktopPackage `
        -PackageFamilyName $package.PackageFamilyName `
        -AppId $config.AppId `
        -Command 'powershell.exe' `
        -Args "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedCommand" `
        -PreventBreakaway

    Write-CodexProxyLog -Path $logPath -Message 'Codex launch command completed.'
}
catch {
    $message = $_.Exception.Message
    try {
        if (Get-Command Write-CodexProxyLog -ErrorAction SilentlyContinue) {
            Write-CodexProxyLog -Path $logPath -Message $message -Level ERROR
        }
        else {
            Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [ERROR] $message" -Encoding UTF8
        }
    }
    catch {}

    try {
        if (Get-Command Show-CodexProxyError -ErrorAction SilentlyContinue) {
            Show-CodexProxyError -Message $message
        }
        else {
            Add-Type -AssemblyName PresentationFramework
            [System.Windows.MessageBox]::Show($message, 'Codex Proxy Launcher') | Out-Null
        }
    }
    catch {}
    exit 1
}
