[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [string]$ProjectPath = 'F:\xiaolab\project\StreamSentry',
    [string]$ImportantThreadId = 'a82ef0f2-6284-5ace-b47a-137f65ef9c1e',
    [string]$VaultRoot,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$codexHomeFull = [IO.Path]::GetFullPath($CodexHome).TrimEnd('\')
$projectPathFull = [IO.Path]::GetFullPath($ProjectPath).TrimEnd('\')
$historySyncPath = Join-Path $PSScriptRoot 'HistorySync.ps1'
$dummyConfig = Join-Path ([IO.Path]::GetTempPath()) ('codex-proxy-repair-' + [guid]::NewGuid().ToString('N') + '.json')
if (-not (Test-Path -LiteralPath $historySyncPath -PathType Leaf)) { throw "History sync component not found: $historySyncPath" }

# Load the project's tested SQLite backup/interop helpers without touching the
# user's real sync configuration.
. $historySyncPath -Action Status -CodexHomeOverride $codexHomeFull -ConfigPathOverride $dummyConfig -SkipProcessCheck | Out-Null

if ([string]::IsNullOrWhiteSpace($VaultRoot)) {
    $realConfigPath = Join-Path $env:LOCALAPPDATA 'CodexProxy\history-sync.json'
    if (Test-Path -LiteralPath $realConfigPath -PathType Leaf) {
        try {
            $realConfig = Get-Content -LiteralPath $realConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $candidateVault = [string](Get-PropertyValue $realConfig 'LastKnownVaultPath' '')
            $candidateId = [string](Get-PropertyValue $realConfig 'VaultId' '')
            if (-not [string]::IsNullOrWhiteSpace($candidateVault) -and (Test-VaultIdentity -VaultRoot $candidateVault -VaultId $candidateId)) {
                $VaultRoot = [IO.Path]::GetFullPath($candidateVault)
            }
        }
        catch {}
    }
}
if (-not [string]::IsNullOrWhiteSpace($VaultRoot)) { $VaultRoot = [IO.Path]::GetFullPath($VaultRoot).TrimEnd('\') }

function Quote-SqlText {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return 'NULL' }
    # sqlite3_exec is declared with an ANSI marshaling boundary in the shared
    # helper. Sending Chinese text as a quoted SQL literal therefore lets the
    # Windows code page turn UTF-8 into GBK bytes. Use an ASCII-only SQLite
    # blob literal and explicitly cast it back to TEXT instead.
    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $hex = ([BitConverter]::ToString($bytes)).Replace('-', '')
    "CAST(X'$hex' AS TEXT)"
}

function Normalize-ComparablePath {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $text = $Value.Trim()
    if ($text.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) { $text = $text.Substring(4) }
    try { [IO.Path]::GetFullPath($text).TrimEnd('\') } catch { $text.TrimEnd('\') }
}

function Get-ThreadIdFromFileName {
    param([Parameter(Mandatory)][string]$Name)
    $match = [regex]::Match($Name, '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$')
    if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }
    $null
}

function Get-JsonlFirstObject {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $line = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        $line | ConvertFrom-Json
    }
    catch { $null }
}

function Get-SessionTitleFromIndex {
    param([AllowNull()]$Entry, [string]$Fallback)
    $title = if ($null -ne $Entry) { [string](Get-PropertyValue $Entry 'thread_name' '') } else { '' }
    if ([string]::IsNullOrWhiteSpace($title)) { $title = $Fallback }
    if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Recovered session' }
    # A conflict suffix is metadata added by the old importer, not part of the
    # user's title. Keep the original title for the important thread.
    $title -replace '\s*[\(\uFF08]\u51b2\u7a81\u526f\u672c\s*[\u00B7\u2022]\s*[^\)\uFF09]*[\)\uFF09]\s*$', ''
}

$indexPath = Join-Path $codexHomeFull 'session_index.jsonl'
$indexEntries = New-Object Collections.Generic.List[object]
$indexMap = @{}
if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $indexPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entry = $line | ConvertFrom-Json
            $id = [string](Get-PropertyValue $entry 'id' '')
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            if ($indexMap.ContainsKey($id)) { $indexEntries.Remove($indexMap[$id]) }
            $indexMap[$id] = $entry
            $indexEntries.Add($entry)
        }
        catch {}
    }
}

$conflictCandidates = @($indexEntries | Where-Object {
    ([string](Get-PropertyValue $_ 'thread_name' '') -match '\u51b2\u7a81\u526f\u672c') -and
    -not ([string](Get-PropertyValue $_ 'id' '')).Equals($ImportantThreadId, [StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object { [string](Get-PropertyValue $_ 'id' '') } | Select-Object -Unique)

$allSessionFiles = @(foreach ($dir in @('sessions','archived_sessions')) {
    $root = Join-Path $codexHomeFull $dir
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(?i)\\migration_backups\\' }
})
$syncedFiles = @($allSessionFiles | Where-Object { $_.FullName -match '(?i)\\synced-[^\\]+\\' })
# The first run sees the imported view; a later run may be repairing an
# already-restored standard sessions path. Inspect both so a second pass can
# still repair invalid metadata without needing the original imported path.
$importantFiles = @($allSessionFiles | Where-Object { (Get-ThreadIdFromFileName -Name $_.Name) -eq $ImportantThreadId })
# Index entries that have neither an active rollout file nor a matching
# session directory are stale projections. Keep them in the preview so the
# user can see exactly which left-sidebar ghosts will be removed.
$activeFileThreadIds = @($allSessionFiles | ForEach-Object { Get-ThreadIdFromFileName -Name $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$indexOrphanIds = @($indexEntries | ForEach-Object {
    $id = [string](Get-PropertyValue $_ 'id' '')
    if (-not [string]::IsNullOrWhiteSpace($id) -and $activeFileThreadIds -notcontains $id.ToLowerInvariant()) { $id.ToLowerInvariant() }
} | Select-Object -Unique)
$projectConflictFiles = @($syncedFiles | Where-Object {
    $id = Get-ThreadIdFromFileName -Name $_.Name
    $conflictCandidates -contains $id -and (Normalize-ComparablePath ([string](Get-PropertyValue (Get-PropertyValue (Get-JsonlFirstObject -Path $_.FullName) 'payload') 'cwd' ''))) -eq $projectPathFull
})
$conflictIds = @($projectConflictFiles | ForEach-Object { Get-ThreadIdFromFileName -Name $_.Name } | Select-Object -Unique)

$database = Get-ChildItem -LiteralPath $codexHomeFull -File -Filter 'state_*.sqlite' -ErrorAction SilentlyContinue |
    Sort-Object { if ($_.BaseName -match 'state_(\d+)') { [int]$Matches[1] } else { 0 } } -Descending | Select-Object -First 1
if ($null -eq $database) { throw "Codex state database not found: $codexHomeFull" }

$importantSource = $importantFiles | Sort-Object Length -Descending | Select-Object -First 1
$importantTarget = $null
if ($null -ne $importantSource) {
    $first = Get-JsonlFirstObject -Path $importantSource.FullName
    $timestamp = [string](Get-PropertyValue (Get-PropertyValue $first 'payload') 'timestamp' '')
    $stamp = [DateTimeOffset]::UtcNow
    if (-not [DateTimeOffset]::TryParse($timestamp, [ref]$stamp)) { $stamp = [DateTimeOffset]::UtcNow }
    $targetDir = Join-Path $codexHomeFull ('sessions\' + $stamp.UtcDateTime.ToString('yyyy\\MM\\dd'))
    $importantTarget = Join-Path $targetDir ('rollout-' + $stamp.UtcDateTime.ToString('yyyy-MM-ddTHH-mm-ss') + '-' + $ImportantThreadId + '.jsonl')
}

[pscustomobject]@{
    Success=$true; ApplyRequested=[bool]$Apply; CodexHome=$codexHomeFull; ProjectPath=$projectPathFull
    Database=$database.FullName; VaultRoot=$VaultRoot; ConflictIds=@($conflictIds); ConflictFileCount=$projectConflictFiles.Count
    IndexOrphanIds=@($indexOrphanIds); IndexOrphanCount=$indexOrphanIds.Count
    ImportantThreadId=$ImportantThreadId; ImportantSource=$(if($null -ne $importantSource){$importantSource.FullName}else{$null})
    ImportantTarget=$importantTarget; ImportantFileCount=$importantFiles.Count
    Message=$(if($Apply){'Apply mode: backup and repair; Codex must be fully closed.'}else{'Preview only: no Codex data was modified. Use -Apply to perform a rollback-safe repair.'})
} | ConvertTo-Json -Depth 8

if (-not $Apply) { return }

$running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '(?i)^(?:codex(?:-code-mode-host)?|CodexProxy)\.exe$'
})
if ($running.Count -gt 0) { throw 'Codex or Codex Proxy is running. Close both completely and run this repair at another time; no data was written.' }

$backupRoot = Join-Path $codexHomeFull ('migration_backups\codex-proxy-repair-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
$quarantineRoot = Join-Path $backupRoot 'quarantine'
$vaultQuarantineRoot = if (-not [string]::IsNullOrWhiteSpace($VaultRoot)) { Join-Path $backupRoot 'vault-refs' } else { $null }
New-Item -ItemType Directory -Path $quarantineRoot -Force | Out-Null
if ($null -ne $vaultQuarantineRoot) { New-Item -ItemType Directory -Path $vaultQuarantineRoot -Force | Out-Null }
Backup-WinSqlite -SourcePath $database.FullName -DestinationPath (Join-Path $backupRoot $database.Name)
if (Test-Path -LiteralPath $indexPath -PathType Leaf) { Copy-Item -LiteralPath $indexPath -Destination (Join-Path $backupRoot 'session_index.jsonl') -Force }

function Move-ToRepairQuarantine {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $relative = Get-RelativePathFromRoot -Root $codexHomeFull -Path $Path
    if ($null -eq $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.(\\|$)') { throw "Refusing to move a file outside Codex home: $Path" }
    $destination = Join-Path $quarantineRoot $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Move-Item -LiteralPath $Path -Destination $destination -Force
    $marker = Get-ImportedSessionMarkerPath -SessionPath $Path
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        Move-Item -LiteralPath $marker -Destination ($destination + '.codex-proxy-import.json') -Force
    }
}

$allRowsToRemove = @($conflictIds)
$escapedIds = @($allRowsToRemove | ForEach-Object { Quote-SqlText $_ }) -join ','
$importantTitle = Get-SessionTitleFromIndex -Entry $indexMap[$ImportantThreadId] -Fallback ''
$importantUpdated = [string](Get-PropertyValue $indexMap[$ImportantThreadId] 'updated_at' ([DateTime]::UtcNow.ToString('o')))
$importantPathSql = Quote-SqlText ([IO.Path]::GetFullPath($importantTarget))
$importantCwdSql = Quote-SqlText $projectPathFull
$importantTitleSql = Quote-SqlText $importantTitle
$sql = "BEGIN IMMEDIATE;"
if ($allRowsToRemove.Count -gt 0) {
    $sql += " DELETE FROM thread_dynamic_tools WHERE thread_id IN ($escapedIds);"
    $sql += " DELETE FROM thread_spawn_edges WHERE parent_thread_id IN ($escapedIds) OR child_thread_id IN ($escapedIds);"
    $sql += " DELETE FROM thread_artifacts WHERE thread_id IN ($escapedIds);"
    $sql += " DELETE FROM threads WHERE id IN ($escapedIds);"
}
if ($null -ne $importantSource) {
    # Preserve the existing recency. Repairing the projection must not make an
    # old conversation appear as if it was just edited.
    $sql += " UPDATE threads SET rollout_path=$importantPathSql, cwd=$importantCwdSql, title=$importantTitleSql, first_user_message=first_user_message, preview=preview, has_user_event=1, name=$importantTitleSql, updated_at=updated_at WHERE id=$(Quote-SqlText $ImportantThreadId);"
}
$sql += ' COMMIT;'
Invoke-WinSqliteExec -Path $database.FullName -Sql $sql

if ($null -ne $vaultQuarantineRoot -and (Test-Path -LiteralPath (Join-Path $VaultRoot 'refs') -PathType Container)) {
    $vaultRefsRoot = [IO.Path]::GetFullPath((Join-Path $VaultRoot 'refs')).TrimEnd('\') + '\'
    foreach ($refFile in Get-ChildItem -LiteralPath $vaultRefsRoot -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue) {
        try { $ref = Read-JsonFile -Path $refFile.FullName } catch { continue }
        $refId = [string](Get-PropertyValue $ref 'ThreadId' '')
        $relativeRef = $refFile.FullName.Substring($vaultRefsRoot.Length)
        if ($allRowsToRemove -contains $refId) {
            $destination = Join-Path $vaultQuarantineRoot $relativeRef
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Move-Item -LiteralPath $refFile.FullName -Destination $destination -Force
        }
        elseif ($refId.Equals($ImportantThreadId, [StringComparison]::OrdinalIgnoreCase)) {
            $backupRef = Join-Path $vaultQuarantineRoot $relativeRef
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupRef) -Force | Out-Null
            Copy-Item -LiteralPath $refFile.FullName -Destination $backupRef -Force
            $ref.Title = $importantTitle
            Write-AtomicJson -Path $refFile.FullName -Value $ref
        }
    }
}

foreach ($file in @($projectConflictFiles + $importantFiles)) { Move-ToRepairQuarantine -Path $file.FullName }
if ($null -ne $importantSource) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $importantTarget) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $quarantineRoot (Get-RelativePathFromRoot -Root $codexHomeFull -Path $importantSource.FullName)) -Destination $importantTarget -Force
}

$kept = New-Object Collections.Generic.List[object]
$keptIds = @{}
foreach ($entry in $indexEntries) {
    $id = [string](Get-PropertyValue $entry 'id' '')
    if ($allRowsToRemove -contains $id -or $indexOrphanIds -contains $id.ToLowerInvariant()) { continue }
    if ($id.Equals($ImportantThreadId, [StringComparison]::OrdinalIgnoreCase)) {
        $entry.thread_name = $importantTitle
        $entry.updated_at = $importantUpdated
    }
    if ($keptIds.ContainsKey($id)) { continue }
    $keptIds[$id] = $true; $kept.Add($entry)
}
$indexText = (($kept | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join [Environment]::NewLine) + [Environment]::NewLine
Write-AtomicText -Path $indexPath -Text $indexText
Write-Host "History repair completed. Backup and quarantine: $backupRoot" -ForegroundColor Green
