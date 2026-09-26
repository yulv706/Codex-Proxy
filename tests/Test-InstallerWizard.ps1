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
    if ($version -ne '3.5.8.0') { throw "Unexpected setup wizard version: $version" }
    Write-Host 'PASS: visual setup wizard compilation and version.' -ForegroundColor Green
}
finally { if (Test-Path -LiteralPath $out -PathType Leaf) { [IO.File]::Delete($out) } }
