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

    if ($config.UpdateStoreProductId -ne '9PLM9XGG6VKS') { throw 'The official Microsoft Store product ID is incorrect.' }
    if ($config.UpdateAttemptTimeoutSeconds -ne 120) { throw 'The bounded automatic update timeout is incorrect.' }
    if ($config.UpdateRetryCooldownMinutes -ne 360) { throw 'The automatic update retry cooldown is incorrect.' }
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
        '[windows-store-updater] Checking Windows Store for package updates buildVersion=26.818.2441.0 manifestBuildVersion=26.818.3000.0 packageIdentity=OpenAI.Codex',
        '[windows-store-updater] Checking Windows Store for package updates buildVersion=26.818.2441.0 manifestBuildVersion=26.818.3698.0 packageIdentity=OpenAI.Codex'
    )
    $reportedVersion = Get-CodexReportedUpdateVersion -Package ([pscustomobject]@{PackageFamilyName='fixture'}) -LogRoot $logRoot
    if ($reportedVersion -ne [version]'26.818.3698.0') { throw 'The newest Store manifest version was not discovered from desktop logs.' }

    $now = [datetime]'2026-08-21T06:00:00Z'
    $available = Get-CodexAutoUpdateDecision -InstalledVersion ([version]'26.818.2441.0') -ReportedVersion $reportedVersion -RetryCooldownMinutes 360 -NowUtc $now
    if (-not $available.ShouldAttempt -or $available.Reason -ne 'UpdateAvailable') { throw 'A newer Store version should trigger an automatic update.' }

    $noUpdate = Get-CodexAutoUpdateDecision -InstalledVersion $reportedVersion -ReportedVersion $reportedVersion -RetryCooldownMinutes 360 -NowUtc $now
    if ($noUpdate.ShouldAttempt -or $noUpdate.Reason -ne 'NoUpdate') { throw 'The installed Store version should not trigger an update.' }

    $failedState = [pscustomobject]@{
        TargetVersion = $reportedVersion.ToString()
        Outcome        = 'Failed'
        LastAttemptUtc = $now.AddMinutes(-30).ToString('o')
    }
    $cooldown = Get-CodexAutoUpdateDecision -InstalledVersion ([version]'26.818.2441.0') -ReportedVersion $reportedVersion -State $failedState -RetryCooldownMinutes 360 -NowUtc $now
    if ($cooldown.ShouldAttempt -or $cooldown.Reason -ne 'Cooldown' -or $cooldown.RetryAfterUtc.ToUniversalTime() -ne $now.AddMinutes(330).ToUniversalTime()) {
        throw 'A recent failure should defer another automatic update attempt.'
    }

    $expiredState = [pscustomobject]@{
        TargetVersion = $reportedVersion.ToString()
        Outcome        = 'Failed'
        LastAttemptUtc = $now.AddMinutes(-361).ToString('o')
    }
    $retry = Get-CodexAutoUpdateDecision -InstalledVersion ([version]'26.818.2441.0') -ReportedVersion $reportedVersion -State $expiredState -RetryCooldownMinutes 360 -NowUtc $now
    if (-not $retry.ShouldAttempt) { throw 'An expired cooldown should allow another automatic update attempt.' }

    $statePath = Join-Path $testRoot 'state\update-state.json'
    $state = [pscustomobject]@{
        SchemaVersion=1; TargetVersion=$reportedVersion.ToString(); InstalledVersion='26.818.2441.0'
        Outcome='Failed'; LastAttemptUtc=$now.ToString('o'); ErrorCode='UPDATE_STORE_FAILED'; ErrorMessage='fixture'
    }
    Write-CodexUpdateState -Path $statePath -State $state
    $roundTrip = Read-CodexUpdateState -Path $statePath
    if ($roundTrip.TargetVersion -ne $reportedVersion.ToString() -or $roundTrip.ErrorCode -ne 'UPDATE_STORE_FAILED') {
        throw 'The automatic update state did not survive an atomic write/read round trip.'
    }
    if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $statePath) -Filter '*.tmp' -File).Count -ne 0) {
        throw 'The atomic state writer left a temporary file behind.'
    }
    Set-Content -LiteralPath $statePath -Value '{invalid-json' -Encoding UTF8
    if ($null -ne (Read-CodexUpdateState -Path $statePath)) { throw 'A corrupt update state should be ignored instead of blocking launch.' }

    if (Test-Path -LiteralPath (Join-Path $projectRoot 'Update-CodexProxy.ps1')) { throw 'The standalone update program should not exist.' }
    if ((Get-Content -LiteralPath (Join-Path $projectRoot 'Start-CodexProxy.ps1') -Raw) -match '\[switch\]\$Update') { throw 'The launcher should not expose a separate update mode.' }

    Write-Host 'PASS: automatic update discovery, cooldown decisions, atomic state, and single-entry integration.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
