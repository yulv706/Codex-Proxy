[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-proxy-test-$([guid]::NewGuid().ToString('N'))"
$packageRoot = Join-Path $testRoot 'package'
$applicationDirectory = Join-Path $packageRoot 'app'
$sourceDirectory = Join-Path $applicationDirectory 'resources'
$fakeLocalAppData = Join-Path $testRoot 'localappdata'
$originalLocalAppData = $env:LOCALAPPDATA

try {
    New-Item -ItemType Directory -Path $sourceDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $fakeLocalAppData -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $applicationDirectory 'ChatGPT.exe') -Value 'fixture:app' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $packageRoot 'AppxManifest.xml') -Encoding UTF8 -Value @'
<Package>
  <Applications>
    <Application Id="App" Executable="app\ChatGPT.exe" />
  </Applications>
</Package>
'@

    $expectedHelperFiles = [ordered]@{}
    foreach ($name in @(
        'codex.exe',
        'codex-windows-sandbox-setup.exe',
        'codex-command-runner.exe',
        'codex-code-mode-host.exe'
    )) {
        $path = Join-Path $sourceDirectory $name
        Set-Content -LiteralPath $path -Value "fixture:$name" -Encoding ASCII
        $expectedHelperFiles[$name] = $path
    }

    $config = [pscustomobject]@{
        AppId           = 'App'
        HelperCachePath = 'OpenAI\Codex\bin\codex-proxy-current'
    }
    $package = [pscustomobject]@{
        InstallLocation = $packageRoot
    }

    $env:LOCALAPPDATA = $fakeLocalAppData
    Import-Module -Name $modulePath -Force

    $applicationInfo = Get-CodexApplicationInfo -Package $package -Config $config
    if (-not $applicationInfo.HelperFiles.Contains('codex-code-mode-host.exe')) {
        throw 'The AppX helper discovery omitted codex-code-mode-host.exe.'
    }

    $firstSync = Sync-CodexHelpers -ApplicationInfo $applicationInfo -Config $config
    if (-not $firstSync.Refreshed) {
        throw 'The first helper synchronization should refresh the cache.'
    }

    foreach ($entry in $expectedHelperFiles.GetEnumerator()) {
        $candidate = Join-Path $firstSync.CacheDirectory $entry.Key
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Expected helper was not synchronized: $($entry.Key)"
        }

        $sourceHash = (Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash
        $cacheHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
        if ($sourceHash -ne $cacheHash) {
            throw "Synchronized helper hash does not match: $($entry.Key)"
        }
    }

    $secondSync = Sync-CodexHelpers -ApplicationInfo $applicationInfo -Config $config
    if ($secondSync.Refreshed) {
        throw 'An unchanged helper cache should not be refreshed.'
    }

    Write-Host 'PASS: all discovered Codex helpers are synchronized and hash-verified.'
}
finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
