[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path ([IO.Path]::GetTempPath()) ('codex-proxy-setup-test-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Build-CodexProxyInstaller.ps1') -OutputPath $out
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $out -PathType Leaf)) { throw 'Setup wizard build failed.' }
    $version = (Get-Item -LiteralPath $out).VersionInfo.FileVersionRaw
    if ($version -ne '4.1.0.0') { throw "Unexpected setup wizard version: $version" }
    $previewRoot = Join-Path $root 'artifacts\setup-4.1.0-preview'
    New-Item -ItemType Directory -Path $previewRoot -Force | Out-Null
    $fixture = Join-Path $previewRoot 'SetupTests.exe'
    & (Join-Path $root 'Build-CodexProxyInstaller.ps1') -OutputPath $fixture -IncludeTests
    $process = Start-Process -WindowStyle Hidden -FilePath $fixture -ArgumentList ('"' + $previewRoot + '"') -PassThru
    try {
        if (-not $process.WaitForExit(30000)) { Stop-Process -Id $process.Id -Force; throw 'Setup fixtures timed out.' }
        if ($process.ExitCode -ne 0) { throw (Get-Content -LiteralPath (Join-Path $previewRoot 'error.txt') -Raw) }
        Get-Content -LiteralPath (Join-Path $previewRoot 'result.txt')
    }
    finally { $process.Dispose() }
}
finally { if (Test-Path -LiteralPath $out -PathType Leaf) { [IO.File]::Delete($out) } }
