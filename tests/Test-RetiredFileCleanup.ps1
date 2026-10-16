[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-proxy-retired-test-' + [guid]::NewGuid().ToString('N'))

try {
    Import-Module (Join-Path $projectRoot 'src\CodexProxy.Installation.psm1') -Force
    $obsolete = @('HistorySync.ps1', 'Repair-CodexHistory.ps1', 'docs\history-sync-design.md')
    $preserved = @('CodexProxy.user.psd1', 'Start-CodexProxy.ps1', 'history-sync.json',
        'history-backups\session.jsonl', '.codex-history-vault\objects\session.jsonl', 'docs\notes.md')
    foreach ($relativePath in @($obsolete) + @($preserved)) {
        $path = Join-Path $testRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Value 'preserved fixture' -Encoding UTF8
    }
    $hashes = @{}
    foreach ($relativePath in $preserved) { $hashes[$relativePath] = (Get-FileHash -LiteralPath (Join-Path $testRoot $relativePath)).Hash }

    Remove-CodexProxyRetiredFiles -InstallDirectory $testRoot
    Remove-CodexProxyRetiredFiles -InstallDirectory $testRoot
    foreach ($relativePath in $obsolete) {
        if (Test-Path -LiteralPath (Join-Path $testRoot $relativePath)) { throw "Obsolete component remains: $relativePath" }
    }
    foreach ($relativePath in $preserved) {
        if ((Get-FileHash -LiteralPath (Join-Path $testRoot $relativePath)).Hash -ne $hashes[$relativePath]) { throw "User or proxy file changed: $relativePath" }
    }
    Write-Host 'PASS: upgrade removes retired components, preserves proxy files and user data, and can run twice.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedTestRoot.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test directory.' }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
