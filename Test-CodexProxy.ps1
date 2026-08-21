[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$ProxyPort,
    [switch]$Detailed,
    [switch]$Json,
    [switch]$Repair
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $projectRoot 'CodexProxy.config.psd1'
$userConfigPath = Join-Path $projectRoot 'CodexProxy.user.psd1'
$launcherPath = Join-Path $projectRoot 'Start-CodexProxy.ps1'
$installerPath = Join-Path $projectRoot 'Install-CodexProxy.ps1'
$iconPath = Join-Path $projectRoot 'assets\codex-official-transparent.ico'

try {
    Import-Module -Name $modulePath -Force
    $configArguments = @{ Path=$configPath; UserPath=$userConfigPath }
    if ($PSBoundParameters.ContainsKey('ProxyPort')) { $configArguments.ProxyPortOverride = $ProxyPort }
    $config = Get-CodexProxyConfig @configArguments

    if ($Repair) {
        if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) { throw "找不到安装修复脚本：$installerPath" }
        $repairArguments = @{ ProxyPort=$config.ProxyPort }
        $localStatePath = Join-Path $projectRoot 'install-state.json'
        if (Test-Path -LiteralPath $localStatePath -PathType Leaf) {
            $localState = Get-Content -LiteralPath $localStatePath -Raw | ConvertFrom-Json
            if ($localState.InstallMode -eq 'Portable') { $repairArguments.Portable = $true }
        }
        if ($Json) {
            & $installerPath @repairArguments 6>$null | Out-Null
        }
        else {
            & $installerPath @repairArguments
        }

        $repairedRoot = if ($repairArguments.ContainsKey('Portable')) { $projectRoot } else { $config.InstallDirectory }
        $repairedDiagnostic = Join-Path $repairedRoot 'Test-CodexProxy.ps1'
        if ([IO.Path]::GetFullPath($repairedDiagnostic) -ne [IO.Path]::GetFullPath($PSCommandPath)) {
            $forwardArguments = @('-NoLogo','-NoProfile','-File',$repairedDiagnostic)
            if ($Detailed) { $forwardArguments += '-Detailed' }
            if ($Json) { $forwardArguments += '-Json' }
            & powershell.exe $forwardArguments
            exit $LASTEXITCODE
        }
    }

    $status = Get-CodexProxyStatus -Config $config
    $reportedUpdateVersion = if ($status.Package) { Get-CodexReportedUpdateVersion -Package $status.Package } else { $null }
    $automaticUpdateState = Read-CodexUpdateState -Path $config.UpdateStateFilePath
    $automaticUpdateDecision = if ($status.Package) {
        Get-CodexAutoUpdateDecision -InstalledVersion ([version]$status.Package.Version) -ReportedVersion $reportedUpdateVersion -State $automaticUpdateState -RetryCooldownMinutes $config.UpdateRetryCooldownMinutes
    } else { $null }
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktopPath $config.ShortcutName
    $shortcut = Test-CodexProxyShortcut -Path $shortcutPath -LauncherPath $launcherPath

    $result = [pscustomobject]@{
        SchemaVersion               = 3
        ProjectRoot                 = $projectRoot
        ProxyUrl                    = $config.ProxyUrl
        ProxyReady                  = $status.Proxy.Ready
        ProxyProcess                = $status.Proxy.ProcessName
        ProxyStatus                 = $status.Proxy.StatusLine
        CodexInstalled              = [bool]$status.Package
        CodexVersion                = if ($status.Package) { $status.Package.Version.ToString() } else { $null }
        ReportedUpdateVersion       = if ($reportedUpdateVersion) { $reportedUpdateVersion.ToString() } else { $null }
        AutomaticUpdatePending      = [bool]($reportedUpdateVersion -and $status.Package -and $reportedUpdateVersion -gt [version]$status.Package.Version)
        AutomaticUpdateDue          = [bool]($automaticUpdateDecision -and $automaticUpdateDecision.ShouldAttempt)
        AutomaticUpdateRetryAfter   = if ($automaticUpdateDecision) { $automaticUpdateDecision.RetryAfterUtc } else { $null }
        AutomaticUpdateLastOutcome  = if ($automaticUpdateState) { $automaticUpdateState.Outcome } else { $null }
        CodexApplicationReady       = [bool]$status.ApplicationInfo
        CodexCurrentlyRunning       = $status.RunningProcesses.Count -gt 0
        CodexRunningProcessCount    = $status.RunningProcesses.Count
        AppxLaunchCommandAvailable  = $status.InvokeCommandAvailable
        LauncherPresent             = Test-Path -LiteralPath $launcherPath -PathType Leaf
        IconPresent                 = Test-Path -LiteralPath $iconPath -PathType Leaf
        DesktopShortcut             = $shortcutPath
        DesktopShortcutReady        = $shortcut.Ready
        DesktopShortcutTarget       = $shortcut.TargetPath
        DesktopShortcutArguments    = $shortcut.Arguments
        ReadyToLaunchNow            = [bool]($status.ReadyNow -and $shortcut.Ready)
        ReadyToLaunchAfterCodexExit = [bool]($status.ReadyAfterCodexExit -and $shortcut.Ready)
        BlockingCode                = if ($status.BlockingCode -and $status.BlockingCode -ne 'CODEX_ALREADY_RUNNING') { $status.BlockingCode } elseif (-not $shortcut.Ready) { $shortcut.Code } else { $status.BlockingCode }
        BlockingMessage             = if ($status.BlockingCode -and $status.BlockingCode -ne 'CODEX_ALREADY_RUNNING') { $status.BlockingMessage } elseif (-not $shortcut.Ready) { '桌面快捷方式缺失或与当前安装不匹配。' } else { $status.BlockingMessage }
        Remediation                 = if ($status.BlockingCode -and $status.BlockingCode -ne 'CODEX_ALREADY_RUNNING') { $status.Remediation } elseif (-not $shortcut.Ready) { '运行 Test-CodexProxy.ps1 -Repair 修复安装和快捷方式。' } else { $status.Remediation }
        LogPath                     = $config.LogFilePath
    }

    if ($Json) {
        $result | ConvertTo-Json -Depth 5
    }
    elseif ($Detailed) {
        $result | Format-List
    }
    else {
        if ($result.ReadyToLaunchNow) {
            Write-Host "[OK] Codex Proxy 已就绪：$($result.ProxyUrl)" -ForegroundColor Green
            Write-Host "代理进程：$($result.ProxyProcess)；Codex：$($result.CodexVersion)"
        }
        elseif ($result.ReadyToLaunchAfterCodexExit -and $result.CodexCurrentlyRunning) {
            Write-Host '[WAIT] 配置正常，但 Codex 当前正在运行。' -ForegroundColor Yellow
            Write-Host '请保存任务并从系统托盘完全退出 Codex，然后使用桌面快捷方式启动。'
        }
        else {
            Write-Host "[FAIL] [$($result.BlockingCode)] $($result.BlockingMessage)" -ForegroundColor Red
            Write-Host "处理建议：$($result.Remediation)"
        }
        Write-Host "日志：$($result.LogPath)"
    }

    if ($result.ReadyToLaunchNow) { exit 0 }
    if ($result.ReadyToLaunchAfterCodexExit -and $result.CodexCurrentlyRunning) { exit 2 }
    exit 1
}
catch {
    $info = if (Get-Command Get-CodexProxyExceptionInfo -ErrorAction SilentlyContinue) { Get-CodexProxyExceptionInfo -Exception $_.Exception } else { [pscustomobject]@{Code='DIAGNOSTIC_ERROR';Message=$_.Exception.Message;Remediation='请重新安装 Codex Proxy。'} }
    if ($Json) {
        [pscustomobject]@{ ReadyToLaunchNow=$false; BlockingCode=$info.Code; BlockingMessage=$info.Message; Remediation=$info.Remediation } | ConvertTo-Json
    }
    else {
        Write-Host "[FAIL] [$($info.Code)] $($info.Message)" -ForegroundColor Red
        Write-Host "处理建议：$($info.Remediation)"
    }
    exit 1
}
