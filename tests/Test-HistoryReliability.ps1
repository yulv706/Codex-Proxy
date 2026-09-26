[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
$sync = Join-Path $root 'HistorySync.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('codex-proxy-reliability-' + [guid]::NewGuid().ToString('N'))
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw "ASSERT FAILED: $Message"}}
try {
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $configPath = Join-Path $temp 'config.json'
    . $sync -Action Status -CodexHomeOverride (Join-Path $temp 'initial-home') -ConfigPathOverride $configPath -MachineIdOverride '11111111-1111-4111-8111-111111111111' -SkipProcessCheck | Out-Null
    $vault = Join-Path $temp 'vault'
    New-Item -ItemType Directory -Path (Join-Path $vault 'objects') -Force | Out-Null
    $valid = Join-Path $vault 'objects\abc.jsonl'; Set-Content -LiteralPath $valid -Value '{}' -Encoding UTF8
    Assert-True ((Resolve-HistoryVaultRelativePath -VaultRoot $vault -RelativePath 'objects/abc.jsonl') -eq [IO.Path]::GetFullPath($valid)) 'Valid vault object path should resolve inside vault.'
    $escaped = $false
    try { Resolve-HistoryVaultRelativePath -VaultRoot $vault -RelativePath '..\outside.txt' | Out-Null } catch { $escaped = $true }
    Assert-True $escaped 'Vault path resolver must reject traversal.'

    $testHome = Join-Path $temp 'home'; New-Item -ItemType Directory -Path $testHome -Force | Out-Null
    $index = @{}
    $backup = Join-Path $temp 'backup'; New-Item -ItemType Directory -Path $backup -Force | Out-Null
    Append-SessionIndexEntry -CodexHome $testHome -ThreadId '22222222-2222-4222-8222-222222222222' -Title 'first' -UpdatedUtc '2026-01-01T00:00:00Z' -IndexMap $index -BackupRoot $backup | Out-Null
    Append-SessionIndexEntry -CodexHome $testHome -ThreadId '22222222-2222-4222-8222-222222222222' -Title 'second' -UpdatedUtc '2026-01-01T00:01:00Z' -IndexMap $index -BackupRoot $backup | Out-Null
    $rows = @(Get-Content -LiteralPath (Join-Path $testHome 'session_index.jsonl') -Encoding UTF8 | Where-Object { $_ })
    Assert-True ($rows.Count -eq 1 -and (($rows[0] | ConvertFrom-Json).thread_name -eq 'second')) 'Session index rewrite should deduplicate thread rows atomically.'
    Write-Host 'History reliability tests passed.' -ForegroundColor Green
}
finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue} }
