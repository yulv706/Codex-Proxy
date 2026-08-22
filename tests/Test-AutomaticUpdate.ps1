[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $projectRoot 'CodexProxy.config.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-proxy-auto-update-test-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Import-Module -Name $modulePath -Force
    $config = Get-CodexProxyConfig -Path $configPath

    if ($config.UpdateActivationWaitSeconds -ne 20) { throw 'The bounded package activation wait is incorrect.' }
    if ($config.PSObject.Properties.Name -contains 'UpdateRetryCooldownMinutes') { throw 'The obsolete winget retry cooldown should not remain in the runtime configuration.' }
    if ([IO.Path]::GetFileName($config.UpdateStateFilePath) -ne 'update-state.json') { throw 'The update state path is incorrect.' }

    $badConfigPath = Join-Path $testRoot 'BadUpdateState.config.psd1'
    (Get-Content -LiteralPath $configPath -Raw).Replace("UpdateStatePath            = 'CodexProxy\update-state.json'", "UpdateStatePath            = '..\update-state.json'") | Set-Content -LiteralPath $badConfigPath -Encoding UTF8
    try {
        Get-CodexProxyConfig -Path $badConfigPath | Out-Null
        throw 'An update state path escape should fail validation.'
    }
    catch {
        if ($_.Exception.Message -eq 'An update state path escape should fail validation.') { throw }
        if ($_.Exception.Data['CodexProxyCode'] -ne 'CONFIG_PATH_ESCAPE') { throw "Unexpected state-path error: $($_.Exception.Message)" }
    }

    $logRoot = Join-Path $testRoot 'logs'
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $logRoot 'desktop.log') -Encoding UTF8 -Value @(
        '[windows-store-updater] Checking Windows Store for package updates buildVersion=26.818.3698.0 manifestBuildVersion=26.818.5000.0 packageIdentity=OpenAI.Codex',
        '[windows-store-updater] Checking Windows Store for package updates buildVersion=26.818.3698.0 manifestBuildVersion=26.818.5229.0 packageIdentity=OpenAI.Codex',
        '[windows-store-updater] Windows Store package update check completed canSilentlyDownload=true completed=true hasUpdate=true overallState=Completed',
        '[sparkle] Production Sparkle update event action=download_completed result=succeeded'
    )
    $reportedVersion = Get-CodexReportedUpdateVersion -Package ([pscustomobject]@{PackageFamilyName='fixture'}) -LogRoot $logRoot
    if ($reportedVersion -ne [version]'26.818.5229.0') { throw 'The newest Store manifest version was not discovered from desktop logs.' }

    $oldPackage = [pscustomobject]@{ Version=[version]'26.818.3698.0' }
    $newPackage = [pscustomobject]@{ Version=[version]'26.818.5229.0' }
    $packages = New-Object Collections.Queue
    $packages.Enqueue($oldPackage)
    $packages.Enqueue($newPackage)
    $activation = Wait-CodexPackageActivation -InstalledPackage $oldPackage -TargetVersion $reportedVersion -TimeoutSeconds 1 -PollIntervalMilliseconds 250 -PackageResolver {
        if ($packages.Count -gt 0) { return $packages.Dequeue() }
        $newPackage
    } -SleepAction { param($Milliseconds) }
    if (-not $activation.Activated -or $activation.Package.Version -ne $reportedVersion) {
        throw 'A Store package activated during the bounded wait should be detected.'
    }

    $deferredStatePath = Join-Path $testRoot 'deferred\update-state.json'
    $deferredConfig = [pscustomobject]@{ UpdateActivationWaitSeconds=1; UpdateStateFilePath=$deferredStatePath }
    $deferred = Invoke-CodexAutomaticUpdate -InstalledPackage $oldPackage -Config $deferredConfig -ReportedVersionOverride $reportedVersion -PackageResolver { $oldPackage } -SleepAction { param($Milliseconds) }
    if ($deferred.Updated -or $deferred.Reason -ne 'AwaitingAppUpdater' -or $deferred.Code) {
        throw 'An update that has not activated yet should be deferred without being classified as a failure.'
    }
    $deferredState = Read-CodexUpdateState -Path $deferredStatePath
    if ($deferredState.Outcome -ne 'AwaitingAppUpdater' -or $deferredState.TargetVersion -ne $reportedVersion.ToString()) {
        throw 'The deferred built-in updater state was not persisted.'
    }

    $reconciledStatePath = Join-Path $testRoot 'reconciled\update-state.json'
    Write-CodexUpdateState -Path $reconciledStatePath -State ([pscustomobject]@{
        SchemaVersion=1; TargetVersion='26.818.3698.0'; InstalledVersion='26.818.2441.0'; Outcome='Failed'
        LastAttemptUtc='2026-08-21T08:40:11Z'; ErrorCode='UPDATE_STORE_FAILED'; ErrorMessage='legacy winget failure'
    })
    $reconciledConfig = [pscustomobject]@{ UpdateActivationWaitSeconds=1; UpdateStateFilePath=$reconciledStatePath }
    $reconciled = Invoke-CodexAutomaticUpdate -InstalledPackage $oldPackage -Config $reconciledConfig -ReportedVersionOverride ([version]'26.818.3698.0') -PackageResolver { $oldPackage } -SleepAction { param($Milliseconds) }
    $reconciledState = Read-CodexUpdateState -Path $reconciledStatePath
    if ($reconciled.Reason -ne 'Current' -or $reconciledState.Outcome -ne 'Succeeded' -or $reconciledState.ErrorCode) {
        throw 'A stale failure should be reconciled after the target version is installed.'
    }

    $moduleText = Get-Content -LiteralPath $modulePath -Raw
    if ($moduleText -match '(?i)winget(?:\.exe)?') { throw 'The launcher should not use winget as a Store update executor.' }

    $statePath = Join-Path $testRoot 'state\update-state.json'
    $state = [pscustomobject]@{
        SchemaVersion=2; TargetVersion=$reportedVersion.ToString(); InstalledVersion='26.818.3698.0'
        Outcome='AwaitingAppUpdater'; LastCheckedUtc='2026-08-22T03:16:34Z'; ErrorCode=$null; ErrorMessage=$null
    }
    Write-CodexUpdateState -Path $statePath -State $state
    $roundTrip = Read-CodexUpdateState -Path $statePath
    if ($roundTrip.TargetVersion -ne $reportedVersion.ToString() -or $roundTrip.Outcome -ne 'AwaitingAppUpdater') {
        throw 'The automatic update state did not survive an atomic write/read round trip.'
    }
    if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $statePath) -Filter '*.tmp' -File).Count -ne 0) {
        throw 'The atomic state writer left a temporary file behind.'
    }
    Set-Content -LiteralPath $statePath -Value '{invalid-json' -Encoding UTF8
    if ($null -ne (Read-CodexUpdateState -Path $statePath)) { throw 'A corrupt update state should be ignored instead of blocking launch.' }

    if (Test-Path -LiteralPath (Join-Path $projectRoot 'Update-CodexProxy.ps1')) { throw 'The standalone update program should not exist.' }
    if ((Get-Content -LiteralPath (Join-Path $projectRoot 'Start-CodexProxy.ps1') -Raw) -match '\[switch\]\$Update') { throw 'The launcher should not expose a separate update mode.' }

    Write-Host 'PASS: built-in updater discovery, activation waiting, deferred state, reconciliation, and single-entry integration.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
