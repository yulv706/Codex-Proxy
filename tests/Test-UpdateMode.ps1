[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $projectRoot 'CodexProxy.config.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-proxy-update-test-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Import-Module -Name $modulePath -Force
    $config = Get-CodexProxyConfig -Path $configPath

    if ($config.UpdateStoreProductId -ne '9PLM9XGG6VKS') { throw 'The official Microsoft Store product ID is incorrect.' }

    if ($config.UpdateX64Uri.Scheme -ne 'https' -or $config.UpdateX64Uri.Host -ne 'persistent.oaistatic.com') {
        throw 'The x64 update URI must use the official HTTPS distribution host.'
    }
    if ($config.UpdateArm64Uri.Scheme -ne 'https' -or $config.UpdateArm64Uri.Host -ne 'persistent.oaistatic.com') {
        throw 'The Arm64 update URI must use the official HTTPS distribution host.'
    }
    if ((Get-CodexUpdateUri -Config $config -Architecture X64).AbsoluteUri -ne $config.UpdateX64Uri.AbsoluteUri) {
        throw 'The x64 package mapping is incorrect.'
    }
    if ((Get-CodexUpdateUri -Config $config -Architecture Arm64).AbsoluteUri -ne $config.UpdateArm64Uri.AbsoluteUri) {
        throw 'The Arm64 package mapping is incorrect.'
    }
    try {
        Get-CodexUpdateUri -Config $config -Architecture Neutral | Out-Null
        throw 'An unsupported update architecture should fail.'
    }

    catch {
        if ($_.Exception.Message -eq 'An unsupported update architecture should fail.') { throw }
        if ($_.Exception.Data['CodexProxyCode'] -ne 'UPDATE_ARCHITECTURE_UNSUPPORTED') {
            throw "Unexpected architecture error: $($_.Exception.Message)"
        }
    }

    $logRoot = Join-Path $testRoot 'logs'
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $logRoot 'desktop.log') -Encoding UTF8 -Value @(
        '[windows-store-updater] Checking Windows Store for package updates buildVersion=26.818.2441.0 manifestBuildVersion=26.818.3000.0 packageIdentity=OpenAI.Codex',
        '[windows-store-updater] Checking Windows Store for package updates buildVersion=26.818.2441.0 manifestBuildVersion=26.818.3698.0 packageIdentity=OpenAI.Codex'
    )
    $reportedVersion = Get-CodexReportedUpdateVersion -Package ([pscustomobject]@{PackageFamilyName='fixture'}) -LogRoot $logRoot
    if ($reportedVersion -ne [version]'26.818.3698.0') { throw 'The newest Store manifest version was not discovered from desktop logs.' }

    $manifestPath = Join-Path $testRoot 'AppxManifest.xml'
    Set-Content -LiteralPath $manifestPath -Encoding UTF8 -Value @'
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="OpenAI.Codex" Publisher="CN=OpenAI, O=OpenAI, L=San Francisco, S=California, C=US" Version="26.900.1.0" ProcessorArchitecture="x64" />
</Package>
'@
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixturePackage = Join-Path $testRoot 'fixture.msix'
    $archive = [IO.Compression.ZipFile]::Open($fixturePackage, [IO.Compression.ZipArchiveMode]::Create)
    try {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $manifestPath, 'AppxManifest.xml') | Out-Null
    }
    finally {
        $archive.Dispose()
    }

    $identity = Read-CodexMsixIdentity -Path $fixturePackage
    if ($identity.Name -ne 'OpenAI.Codex' -or $identity.Version.ToString() -ne '26.900.1.0' -or $identity.Architecture -ne 'X64') {
        throw 'The MSIX identity reader returned incorrect values.'
    }

    $installedPackage = [pscustomobject]@{
        Name         = 'OpenAI.Codex'
        Publisher    = 'CN=OpenAI, O=OpenAI, L=San Francisco, S=California, C=US'
        PublisherId  = '2p2nqsd0c76g0'
        Architecture = 'X64'
        Version      = [version]'26.818.2441.0'
    }
    $plan = Test-CodexUpdateIdentity -Identity $identity -InstalledPackage $installedPackage -Config $config
    if (-not $plan.UpdateAvailable -or $plan.InstalledVersion -ne [version]'26.818.2441.0' -or $plan.CandidateVersion -ne [version]'26.900.1.0') {
        throw 'A newer trusted package was not classified as an available update.'
    }

    $sameIdentity = [pscustomobject]@{
        Name='OpenAI.Codex'; Publisher=$installedPackage.Publisher; Version=[version]'26.818.2441.0'; Architecture='X64'
    }
    $samePlan = Test-CodexUpdateIdentity -Identity $sameIdentity -InstalledPackage $installedPackage -Config $config
    if ($samePlan.UpdateAvailable) { throw 'The installed version should not be classified as an update.' }

    foreach ($badIdentity in @(
        [pscustomobject]@{Name='Contoso.Fake';Publisher=$installedPackage.Publisher;Version=[version]'26.900.1.0';Architecture='X64'},
        [pscustomobject]@{Name='OpenAI.Codex';Publisher='CN=Contoso';Version=[version]'26.900.1.0';Architecture='X64'},
        [pscustomobject]@{Name='OpenAI.Codex';Publisher=$installedPackage.Publisher;Version=[version]'26.900.1.0';Architecture='Arm64'}
    )) {
        try {
            Test-CodexUpdateIdentity -Identity $badIdentity -InstalledPackage $installedPackage -Config $config | Out-Null
            throw 'A mismatched package identity should fail.'
        }
        catch {
            if ($_.Exception.Message -eq 'A mismatched package identity should fail.') { throw }
            if ($_.Exception.Data['CodexProxyCode'] -notmatch '^UPDATE_(NAME|PUBLISHER|ARCHITECTURE)_MISMATCH$') {
                throw "Unexpected identity error: $($_.Exception.Message)"
            }
        }
    }

    try {
        Test-CodexUpdatePackage -Path $fixturePackage -InstalledPackage $installedPackage -Config $config | Out-Null
        throw 'An unsigned MSIX fixture should fail signature validation.'
    }
    catch {
        if ($_.Exception.Message -eq 'An unsigned MSIX fixture should fail signature validation.') { throw }
        if ($_.Exception.Data['CodexProxyCode'] -ne 'UPDATE_SIGNATURE_INVALID') {
            throw "Unexpected signature error: $($_.Exception.Message)"
        }
    }

    Write-Host 'PASS: official update URIs, architecture selection, MSIX identity parsing, version planning, and signature rejection.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
