[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Installation.psm1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-proxy-install-discovery-$([guid]::NewGuid().ToString('N'))"

try {
    Import-Module -Name $modulePath -Force
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $registeredRoot = Join-Path $testRoot 'registered-install'
    $shortcutRoot = Join-Path $testRoot 'shortcut-install'
    $staleDefaultRoot = Join-Path $testRoot 'stale-default'
    foreach ($path in @($registeredRoot, $shortcutRoot, $staleDefaultRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $registeredRoot 'CodexProxy.exe') -Value 'fixture'
    Set-Content -LiteralPath (Join-Path $shortcutRoot 'CodexProxy.exe') -Value 'fixture'
    Set-Content -LiteralPath (Join-Path $staleDefaultRoot 'install-state.json') -Value '{}'
    Set-Content -LiteralPath (Join-Path $staleDefaultRoot 'CodexProxy.user.psd1') -Value '@{}'

    $result = Resolve-CodexProxyInstallation -CandidateOverride @(
        [pscustomobject]@{ Source='DefaultDirectory'; Path=$staleDefaultRoot; Priority=300 },
        [pscustomobject]@{ Source='Shortcut'; Path=$shortcutRoot; Priority=200 },
        [pscustomobject]@{ Source='RegistryCurrentUser64'; Path=$registeredRoot; Priority=100 }
    )
    if (-not $result.Found) { throw 'A valid registered installation was not detected.' }
    if (-not $result.InstallDirectory.Equals($registeredRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "Registered installation did not win: $($result.InstallDirectory)" }
    if ($result.Source -ne 'RegistryCurrentUser64') { throw "Unexpected detection source: $($result.Source)" }
    $upgradeTarget = Resolve-CodexProxyInstallTarget -DetectedInstallation $result -RequestedDirectory $registeredRoot -DefaultDirectory $staleDefaultRoot
    if (-not $upgradeTarget.IsUpgrade -or -not $upgradeTarget.InstallDirectory.Equals($registeredRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The install target resolver did not lock an upgrade to the existing installation.'
    }
    try {
        Resolve-CodexProxyInstallTarget -DetectedInstallation $result -RequestedDirectory $shortcutRoot -DefaultDirectory $staleDefaultRoot | Out-Null
        throw 'A side-by-side target should be rejected while the product is installed.'
    }
    catch {
        if ($_.Exception.Message -eq 'A side-by-side target should be rejected while the product is installed.') { throw }
        if ($_.Exception.Message -notlike '*must use the existing directory*') { throw "Unexpected target validation error: $($_.Exception.Message)" }
    }

    Remove-Item -LiteralPath (Join-Path $registeredRoot 'CodexProxy.exe') -Force
    $fallback = Resolve-CodexProxyInstallation -CandidateOverride @(
        [pscustomobject]@{ Source='RegistryCurrentUser64'; Path=$registeredRoot; Priority=100 },
        [pscustomobject]@{ Source='Shortcut'; Path=$shortcutRoot; Priority=200 },
        [pscustomobject]@{ Source='DefaultDirectory'; Path=$staleDefaultRoot; Priority=300 }
    )
    if (-not $fallback.Found -or -not $fallback.InstallDirectory.Equals($shortcutRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'An invalid registry record should fall back to a valid product shortcut.'
    }

    Remove-Item -LiteralPath (Join-Path $shortcutRoot 'CodexProxy.exe') -Force
    $freshInstall = Resolve-CodexProxyInstallation -CandidateOverride @(
        [pscustomobject]@{ Source='DefaultDirectory'; Path=$staleDefaultRoot; Priority=300 }
    )
    if ($freshInstall.Found) { throw 'A stale data directory without CodexProxy.exe must not be treated as an installed product.' }
    if ($freshInstall.RejectedCandidates.Count -ne 1) { throw 'Rejected stale installations should remain diagnosable.' }

    Write-Host 'PASS: install discovery prioritises a valid registered product and ignores stale data directories.' -ForegroundColor Green
}
finally {
    Remove-Module CodexProxy.Installation -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot -PathType Container) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
