Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$syncScript = Join-Path $projectRoot 'HistorySync.ps1'
$testRoot = Join-Path $projectRoot '.tmp-history-tests'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Invoke-HistoryTool {
    param([string]$Action, [string]$LocalCodexHome, [string]$Config, [string]$Machine, [string]$VaultBase, [string]$ProjectId, [string]$ProjectName, [string]$LocalPath, [switch]$Automatic)
    $arguments = @(
        '-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$syncScript,
        '-Action',$Action,'-Json','-CodexHomeOverride',$LocalCodexHome,'-ConfigPathOverride',$Config,
        '-MachineIdOverride',$Machine,'-SkipProcessCheck'
    )
    if ($VaultBase) { $arguments += @('-VaultPath',$VaultBase) }
    if ($ProjectId) { $arguments += @('-ProjectId',$ProjectId) }
    if ($ProjectName) { $arguments += @('-ProjectName',$ProjectName) }
    if ($LocalPath) { $arguments += @('-LocalPath',$LocalPath) }
    if ($Automatic) { $arguments += '-Automatic' }
    $output = & powershell.exe $arguments
    if ($LASTEXITCODE -ne 0) { throw "HistorySync $Action failed: $output" }
    $output | ConvertFrom-Json
}

function Invoke-HistoryToolViaHiddenUtf8Bridge {
    param([string]$Action, [string]$LocalCodexHome, [string]$Config, [string]$Machine)
    $quote = { param([string]$Value) '"' + $Value.Replace('"','\"') + '"' }
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (& $quote $syncScript) +
        ' -Action ' + $Action + ' -Json -CodexHomeOverride ' + (& $quote $LocalCodexHome) +
        ' -ConfigPathOverride ' + (& $quote $Config) + ' -MachineIdOverride ' + $Machine + ' -SkipProcessCheck'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = $arguments
    $info.WorkingDirectory = $projectRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($info)
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Hidden HistorySync $Action failed: $standardError" }
    $standardOutput | ConvertFrom-Json
}

function New-TestSession {
    param([string]$LocalCodexHome, [string]$Id, [string]$Timestamp, [string]$Cwd, [string]$Title, [string]$Message)
    $date = [DateTimeOffset]::Parse($Timestamp)
    $directory = Join-Path $LocalCodexHome ('sessions\' + $date.UtcDateTime.ToString('yyyy\\MM\\dd'))
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $path = Join-Path $directory ('rollout-' + $date.UtcDateTime.ToString('yyyy-MM-ddTHH-mm-ss') + '-' + $Id + '.jsonl')
    $meta = [ordered]@{
        timestamp=$Timestamp; type='session_meta'; payload=[ordered]@{
            id=$Id; timestamp=$Timestamp; cwd=$Cwd; originator='history-sync-test'; cli_version='test'
            source='vscode'; model_provider='openai'
        }
    }
    $event = [ordered]@{ timestamp=$Timestamp; type='event_msg'; payload=[ordered]@{ type='user_message'; message=$Message } }
    $contents = ($meta | ConvertTo-Json -Depth 8 -Compress) + "`n" + ($event | ConvertTo-Json -Depth 8 -Compress) + "`n"
    [IO.File]::WriteAllText($path, $contents, (New-Object Text.UTF8Encoding($false)))
    $index = [ordered]@{ id=$Id; thread_name=$Title; updated_at=$Timestamp } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText((Join-Path $LocalCodexHome 'session_index.jsonl'), $index + "`n", (New-Object Text.UTF8Encoding($false)))
    $path
}

function Add-TestEvent {
    param([string]$Path, [string]$Message)
    $event = [ordered]@{ timestamp=[DateTime]::UtcNow.ToString('o'); type='event_msg'; payload=[ordered]@{ type='user_message'; message=$Message } } | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::AppendAllText($Path, $event + "`n", (New-Object Text.UTF8Encoding($false)))
}

function Get-SessionFiles {
    param([string]$LocalCodexHome)
    @(Get-ChildItem -LiteralPath (Join-Path $LocalCodexHome 'sessions') -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue)
}

$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$resolvedProjectRoot = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\') + '\'
if (-not ($resolvedTestRoot + '\').StartsWith($resolvedProjectRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test root.' }
if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
New-Item -ItemType Directory -Path $resolvedTestRoot -Force | Out-Null
$substLetters = New-Object Collections.Generic.List[string]

try {
    $availableLetters = @('Z','Y','X','W','V','U') | Where-Object { -not (Test-Path -LiteralPath ($_ + ':\')) }
    Assert-True ($availableLetters.Count -ge 2) 'Two free drive letters are required for the drive-letter migration test.'
    $driveA = $availableLetters[0] + ':'
    $driveB = $availableLetters[1] + ':'
    $portablePhysicalRoot = Join-Path $resolvedTestRoot 'portable-volume'
    New-Item -ItemType Directory -Path $portablePhysicalRoot -Force | Out-Null
    & subst.exe $driveA $portablePhysicalRoot
    if ($LASTEXITCODE -ne 0) { throw "Failed to create test drive $driveA" }
    $substLetters.Add($driveA)
    $vaultBaseA = Join-Path ($driveA + '\') 'shared-work'
    $homeA = Join-Path $resolvedTestRoot 'machine-a\.codex'
    $homeB = Join-Path $resolvedTestRoot 'machine-b\.codex'
    $configA = Join-Path $resolvedTestRoot 'machine-a\history-sync.json'
    $configB = Join-Path $resolvedTestRoot 'machine-b\history-sync.json'
    New-Item -ItemType Directory -Path $homeA,$homeB,$vaultBaseA -Force | Out-Null

    $configuredA = Invoke-HistoryTool -Action Configure -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -VaultBase $vaultBaseA
    Assert-True (-not [bool]$configuredA.Enabled) 'History sync must be disabled by default.'
    Assert-True (-not [bool]$configuredA.SyncArchived) 'Archived history sync must be disabled by default.'
    Assert-True (-not [bool]$configuredA.AutomaticWriteEnabled -and -not [bool]$configuredA.AutomaticReady) '后台自动写入必须默认关闭。'
    Assert-True (-not $configuredA.Ready -and $configuredA.SelectedProjectCount -eq 0) 'A new or upgraded vault must not sync every local directory by default.'

    $id = '019f0000-1111-7111-8111-111111111111'
    Invoke-HistoryTool -Action Enable -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' | Out-Null
    $cwdA = Join-Path ($driveA + '\') 'projects\project-one'
    $pathA = New-TestSession -LocalCodexHome $homeA -Id $id -Timestamp '2026-08-30T01:02:03Z' -Cwd $cwdA -Title '跨电脑测试会话' -Message 'base'
    $unselectedId = '019f0000-4444-7444-8444-444444444444'
    $unselectedCwd = Join-Path ($driveA + '\') 'projects\not-selected'
    New-TestSession -LocalCodexHome $homeA -Id $unselectedId -Timestamp '2025-01-01T00:00:00Z' -Cwd $unselectedCwd -Title '不应同步的会话' -Message 'private' | Out-Null
    $createdProject = Invoke-HistoryTool -Action CreateProject -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -LocalPath $cwdA -ProjectName 'Project One'
    $logicalProjectId = [string]($createdProject.Projects | Select-Object -First 1 -ExpandProperty ProjectId)
    Assert-True ($createdProject.BoundProjectCount -eq 1 -and $createdProject.LocalDirectories.Count -eq 2) 'Project discovery should list local working directories and select only the requested one.'
    $automaticBlocked = Invoke-HistoryTool -Action Sync -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -Automatic
    Assert-True ($automaticBlocked.AutomaticBlocked -and $automaticBlocked.ManualRequired -and $automaticBlocked.Exported -eq 0) 'Automatic sync must be blocked until the user enables background history writes.'
    $automaticEnabled = Invoke-HistoryTool -Action EnableAutomatic -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    Assert-True ($automaticEnabled.AutomaticWriteEnabled -and $automaticEnabled.AutomaticReady) 'The automatic-write protection switch should be persisted when enabled.'
    $automaticDisabled = Invoke-HistoryTool -Action DisableAutomatic -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    Assert-True (-not $automaticDisabled.AutomaticWriteEnabled -and -not $automaticDisabled.AutomaticReady) 'The automatic-write protection switch should be reversible.'
    $syncA = Invoke-HistoryTool -Action Sync -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    Assert-True ($syncA.Exported -eq 1) 'Machine A should export its first session.'
    $emptyProjectPath = Join-Path ($driveA + '\') 'projects\empty-project'
    $twoProjectCatalog = Invoke-HistoryTool -Action CreateProject -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -LocalPath $emptyProjectPath -ProjectName 'Empty Project'
    $mainProjectCatalogEntry = @($twoProjectCatalog.Projects | Where-Object ProjectId -eq $logicalProjectId | Select-Object -First 1)
    Assert-True ($twoProjectCatalog.BoundProjectCount -eq 2 -and $mainProjectCatalogEntry.Count -eq 1 -and $mainProjectCatalogEntry[0].LocalPath -eq [IO.Path]::GetFullPath($cwdA).TrimEnd('\')) 'Each logical project must resolve to its own local binding when multiple projects are configured.'

    . $syncScript -Action Status -CodexHomeOverride $homeA -ConfigPathOverride $configA -MachineIdOverride 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -SkipProcessCheck | Out-Null
    $liveConfig = Read-JsonFile -Path $configA
    $liveVault = Resolve-HistoryVault -Config $liveConfig
    Assert-True (-not (Get-AllHistoryRefs -VaultRoot $liveVault | Where-Object ThreadId -eq $unselectedId)) 'Sessions outside selected projects must not enter the vault.'
    $streamedFullExport = Export-LocalSessions -Config $liveConfig -VaultRoot $liveVault -CodexHome $homeA
    $streamedFullEntry = @($streamedFullExport.LocalMap.Values | Where-Object Id -eq $id | Select-Object -First 1)
    Assert-True ($streamedFullEntry.Count -eq 1 -and $null -eq $streamedFullEntry[0].CanonicalBytes -and (Test-Path -LiteralPath $streamedFullEntry[0].CanonicalPath -PathType Leaf)) 'Full sync must keep canonical sessions on disk instead of retaining complete JSONL byte arrays in memory.'
    $unchangedLive = Export-LocalSessions -Config $liveConfig -VaultRoot $liveVault -CodexHome $homeA -ChangedOnly
    Assert-True ($unchangedLive.LocalMap.Count -eq 0 -and $unchangedLive.Unchanged -eq 1) 'Realtime export should avoid rehashing unchanged sessions.'
    $liveTimestamp = [DateTime]::UtcNow.ToString('o')
    $liveEvent = ([ordered]@{ timestamp=$liveTimestamp; type='event_msg'; payload=[ordered]@{ type='user_message'; message='written while open' } } | ConvertTo-Json -Depth 8 -Compress) + "`n"
    $liveBytes = [Text.Encoding]::UTF8.GetBytes($liveEvent)
    $writer = New-Object IO.FileStream($pathA, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try {
        $writer.Write($liveBytes, 0, $liveBytes.Length); $writer.Flush($true)
        $changedLive = Export-LocalSessions -Config $liveConfig -VaultRoot $liveVault -CodexHome $homeA -ChangedOnly
        Assert-True ($changedLive.LocalMap.Count -eq 1) 'Realtime export should snapshot a changed session while its writer remains open.'
    }
    finally { $writer.Dispose() }

    $duplicatePath = Join-Path (Split-Path -Parent $pathA) 'rollout-2026-08-30T01-02-03-019f0000-1111-7111-8111-111111111111_019f0000-2222-7222-8222-222222222222.jsonl'
    Copy-Item -LiteralPath $pathA -Destination $duplicatePath
    $duplicateLive = Export-LocalSessions -Config $liveConfig -VaultRoot $liveVault -CodexHome $homeA -ChangedOnly
    Assert-True ($duplicateLive.LocalMap.Count -eq 1) 'A second rollout file with the same metadata id should receive its own source reference.'
    $duplicateUnchanged = Export-LocalSessions -Config $liveConfig -VaultRoot $liveVault -CodexHome $homeA -ChangedOnly
    Assert-True ($duplicateUnchanged.LocalMap.Count -eq 0 -and $duplicateUnchanged.Unchanged -eq 2) 'Source references should prevent repeated hashing when a rollout filename contains an extra UUID.'
    $mirrorDirectory = Join-Path $homeA 'sessions\synced-shadow\2026\08\30'
    New-Item -ItemType Directory -Path $mirrorDirectory -Force | Out-Null
    $mirrorPath = Join-Path $mirrorDirectory 'rollout-shadow.jsonl'
    Copy-Item -LiteralPath $pathA -Destination $mirrorPath -Force
    $mirrorRef = @(Get-AllHistoryRefs -VaultRoot $liveVault | Where-Object ThreadId -eq $id | Select-Object -First 1)
    Write-ImportedSessionMarker -SessionPath $mirrorPath -Ref $mirrorRef[0] -ObjectRelativePath ([string]$mirrorRef[0].ObjectPath)
    $visibleLocalFiles = @(Get-LocalSessions -CodexHome $homeA)
    Assert-True (@($visibleLocalFiles | Where-Object { [bool]$_.Imported }).Count -eq 1) 'Imported synced-* files should be identified as materialized views.'
    $mirrorSourceRefPath = Join-Path $liveVault ('refs\' + $liveConfig.MachineId + '\sources\' + (Get-HistorySourceKey -Path $mirrorPath) + '.json')
    Export-LocalSessions -Config $liveConfig -VaultRoot $liveVault -CodexHome $homeA | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $mirrorSourceRefPath -PathType Leaf)) 'Unchanged imported views must not be re-exported as local sources.'
    $liveList = Get-HistoryVaultList
    $listedVersion = @($liveList.Entries | Where-Object ThreadId -eq $id | Select-Object -First 1)
    Assert-True ($listedVersion.Count -eq 1 -and [DateTimeOffset]::Parse($listedVersion[0].UpdatedUtc) -eq [DateTimeOffset]::Parse($liveTimestamp)) 'The vault list should use the latest JSONL event timestamp instead of the rollout creation time.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$listedVersion[0].WorkingDirectory)) 'The vault list should expose the original working directory for grouping.'

    $archivedId = '019f0000-3333-7333-8333-333333333333'
    $archivedSource = New-TestSession -LocalCodexHome $homeA -Id $archivedId -Timestamp '2025-08-30T01:02:03Z' -Cwd $cwdA -Title '已归档测试会话' -Message 'archived'
    $archivedDirectory = Join-Path $homeA 'archived_sessions\2025\08\30'
    New-Item -ItemType Directory -Path $archivedDirectory -Force | Out-Null
    $archivedPath = Join-Path $archivedDirectory (Split-Path -Leaf $archivedSource)
    Move-Item -LiteralPath $archivedSource -Destination $archivedPath
    $liveConfig.SyncArchived = $false
    $archivedSkipped = Export-LocalSessions -Config $liveConfig -VaultRoot $liveVault -CodexHome $homeA -ChangedOnly
    Assert-True (-not $archivedSkipped.LocalMap.ContainsKey($archivedId)) 'Archived sessions should not be exported by default.'
    $liveConfig.SyncArchived = $true
    $archivedIncluded = Export-LocalSessions -Config $liveConfig -VaultRoot $liveVault -CodexHome $homeA -ChangedOnly
    Assert-True ($archivedIncluded.LocalMap.ContainsKey($archivedId)) 'Archived sessions should be exported after the option is enabled.'
    $liveConfig.SyncArchived = $false

    $vaultObject = Get-ChildItem -LiteralPath (Join-Path $vaultBaseA '.codex-history-vault\objects') -Recurse -File -Filter '*.jsonl' | Select-Object -First 1
    $vaultMeta = (Get-Content -LiteralPath $vaultObject.FullName -TotalCount 1 -Encoding UTF8) | ConvertFrom-Json
    Assert-True ([string]$vaultMeta.payload.cwd -eq ('codex-project://' + $logicalProjectId)) "Vault objects should use the logical project id instead of a machine-specific path. actual=$($vaultMeta.payload.cwd) expected=codex-project://$logicalProjectId"

    & subst.exe $driveA /D
    if ($LASTEXITCODE -ne 0) { throw "Failed to remove test drive $driveA" }
    $substLetters.Remove($driveA) | Out-Null
    & subst.exe $driveB $portablePhysicalRoot
    if ($LASTEXITCODE -ne 0) { throw "Failed to create test drive $driveB" }
    $substLetters.Add($driveB)
    $vaultBaseB = Join-Path ($driveB + '\') 'shared-work'
    $rediscoveredA = Invoke-HistoryTool -Action Status -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    Assert-True ($rediscoveredA.VaultConnected -and $rediscoveredA.VaultPath.StartsWith($driveB, [StringComparison]::OrdinalIgnoreCase)) 'The same vault should be rediscovered after its drive letter changes.'

    $configuredB = Invoke-HistoryTool -Action Configure -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' -VaultBase $vaultBaseB
    Assert-True ($configuredA.VaultId -eq $configuredB.VaultId) 'Both machines must join the same vault.'
    Invoke-HistoryTool -Action Enable -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' | Out-Null
    $cwdB = Join-Path ($driveB + '\') 'projects\project-one-on-b'
    $boundB = Invoke-HistoryTool -Action BindProject -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' -ProjectId $logicalProjectId -LocalPath $cwdB
    $boundBPath = [string]($boundB.Projects | Where-Object ProjectId -eq $logicalProjectId | Select-Object -First 1 -ExpandProperty LocalPath)
    Assert-True ($boundB.BoundProjectCount -eq 1 -and $boundBPath -eq [IO.Path]::GetFullPath($cwdB).TrimEnd('\')) 'Machine B should bind the shared logical project to a different local path.'

    $listResult = Invoke-HistoryTool -Action List -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    Assert-True ($listResult.EntryCount -ge 1 -and $listResult.Entries[0].Title -eq '跨电脑测试会话') 'Vault list should expose saved titles and update metadata.'
    $hiddenListResult = Invoke-HistoryToolViaHiddenUtf8Bridge -Action List -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    Assert-True ($hiddenListResult.Entries[0].Title -eq '跨电脑测试会话') 'Hidden UTF-8 process bridge should preserve Chinese history titles.'

    $syncB = Invoke-HistoryTool -Action Sync -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    Assert-True ($syncB.Imported -eq 1) 'Machine B should import the session.'
    $importedB = Get-SessionFiles -LocalCodexHome $homeB | Select-Object -First 1
    $metaB = (Get-Content -LiteralPath $importedB.FullName -TotalCount 1 -Encoding UTF8) | ConvertFrom-Json
    Assert-True ([string]$metaB.payload.id -eq $id) 'Imported session should preserve its thread id.'
    Assert-True ([string]$metaB.payload.cwd -eq [IO.Path]::GetFullPath($cwdB)) 'Imported cwd should be materialized for the current drive.'

    Add-TestEvent -Path $importedB.FullName -Message 'continued on B'
    $syncB2 = Invoke-HistoryTool -Action Sync -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    $syncA2 = Invoke-HistoryTool -Action Sync -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    Assert-True ($syncA2.Updated -eq 1) 'Machine A should receive the longer prefix-compatible history.'
    Assert-True ((Get-Content -LiteralPath $pathA -Raw -Encoding UTF8) -match 'continued on B') 'Continuation should reach machine A.'

    $externalPaginationId = '019f0000-6666-7666-8666-666666666666'
    $externalPaginationFirst = New-TestSession -LocalCodexHome $homeA -Id $externalPaginationId -Timestamp '2026-08-30T04:02:03Z' -Cwd $cwdA -Title '跨电脑分页会话' -Message 'first snapshot'
    $externalPaginationSecond = New-TestSession -LocalCodexHome $homeA -Id $externalPaginationId -Timestamp '2026-08-30T04:03:03Z' -Cwd $cwdA -Title '跨电脑分页会话' -Message 'second snapshot with more content'
    $externalPaginationRenamed = Join-Path (Split-Path -Parent $externalPaginationSecond) 'rollout-2026-08-30T04-03-03-019f0000-6666-7666-8666-666666666666_019f0000-7777-7777-8777-777777777777.jsonl'
    Move-Item -LiteralPath $externalPaginationSecond -Destination $externalPaginationRenamed
    Invoke-HistoryTool -Action Sync -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' | Out-Null
    $externalPaginationSync = Invoke-HistoryTool -Action Sync -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    Assert-True ($externalPaginationSync.Conflicts -eq 0) 'Pagination snapshots from another machine must be merged as one logical session, not conflict threads.'
    $paginationList = Invoke-HistoryTool -Action List -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    Assert-True (@($paginationList.Entries | Where-Object ThreadId -eq $externalPaginationId).Count -eq 1) 'The history list should collapse pagination snapshots into one logical row.'

    $ownPaginationId = '019f0000-5555-7555-8555-555555555555'
    New-TestSession -LocalCodexHome $homeA -Id $ownPaginationId -Timestamp '2026-08-30T03:02:03Z' -Cwd $cwdA -Title '分页会话' -Message 'first page' | Out-Null
    New-TestSession -LocalCodexHome $homeA -Id $ownPaginationId -Timestamp '2026-08-30T03:03:03Z' -Cwd $cwdA -Title '分页会话' -Message 'second page from the same machine' | Out-Null
    $currentConfigA = Read-JsonFile -Path $configA
    $currentVaultA = Resolve-HistoryVault -Config $currentConfigA
    $paginationExport = Export-LocalSessions -Config $currentConfigA -VaultRoot $currentVaultA -CodexHome $homeA
    $paginationImport = Invoke-HistoryImport -Config $currentConfigA -VaultRoot $currentVaultA -CodexHome $homeA -ExportResult $paginationExport
    Assert-True ($paginationImport.Conflicts -eq 0) 'A machine must not import its own divergent pagination snapshots as conflict threads.'

    $conflictId = '019f0000-2222-7222-8222-222222222222'
    $conflictA = New-TestSession -LocalCodexHome $homeA -Id $conflictId -Timestamp '2026-08-30T02:02:03Z' -Cwd $cwdA -Title '冲突测试' -Message 'common'
    Invoke-HistoryTool -Action Sync -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' | Out-Null
    Invoke-HistoryTool -Action Sync -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' | Out-Null
    $conflictB = Get-SessionFiles -LocalCodexHome $homeB | Where-Object { $_.Name -like "*$conflictId*" } | Select-Object -First 1
    Add-TestEvent -Path $conflictA -Message 'branch A'
    Add-TestEvent -Path $conflictB.FullName -Message 'branch B'
    Invoke-HistoryTool -Action Sync -LocalCodexHome $homeA -Config $configA -Machine 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' | Out-Null
    $conflictResultB = Invoke-HistoryTool -Action Sync -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    Assert-True ($conflictResultB.Conflicts -ge 1) 'Divergent histories should create a conflict copy instead of overwriting.'
    Assert-True ((Get-SessionFiles -LocalCodexHome $homeB).Count -ge 3) 'Conflict copy should be retained as a separate thread.'

    $localCountBeforeUnbind = (Get-SessionFiles -LocalCodexHome $homeB).Count
    $refCountBeforeUnbind = @(Get-AllHistoryRefs -VaultRoot (Resolve-HistoryVault -Config (Read-JsonFile -Path $configB))).Count
    $unboundB = Invoke-HistoryTool -Action UnbindProject -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' -ProjectId $logicalProjectId
    $statusAfterUnbind = Invoke-HistoryTool -Action Status -LocalCodexHome $homeB -Config $configB -Machine 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    $refCountAfterUnbind = @(Get-AllHistoryRefs -VaultRoot (Resolve-HistoryVault -Config (Read-JsonFile -Path $configB))).Count
    Assert-True ($unboundB.BoundProjectCount -eq 0 -and -not $statusAfterUnbind.Ready) 'Unbinding should stop automatic sync on that computer.'
    Assert-True ((Get-SessionFiles -LocalCodexHome $homeB).Count -eq $localCountBeforeUnbind -and $refCountAfterUnbind -eq $refCountBeforeUnbind) 'Unbinding must not delete local sessions or vault references.'

    $dbHome = Join-Path $resolvedTestRoot 'sqlite-home'
    New-Item -ItemType Directory -Path $dbHome -Force | Out-Null
    $dbPath = Join-Path $dbHome 'state_5.sqlite'
    . $syncScript -Action Status -CodexHomeOverride $dbHome -ConfigPathOverride (Join-Path $dbHome 'dummy.json') -SkipProcessCheck | Out-Null
    Invoke-WinSqliteExec -Path $dbPath -Sql "CREATE TABLE backfill_state (id INTEGER PRIMARY KEY, status TEXT NOT NULL, last_watermark TEXT, last_success_at INTEGER, updated_at INTEGER NOT NULL); INSERT INTO backfill_state VALUES (1,'complete','sessions/x',1,1);"
    $backupRoot = Join-Path $resolvedTestRoot 'sqlite-backup'
    $backup = Rearm-CodexBackfill -CodexHome $dbHome -BackupRoot $backupRoot
    Assert-True (Test-Path -LiteralPath $backup -PathType Leaf) 'SQLite backup should be created before rearming backfill.'

    Write-Host 'History sync tests passed.' -ForegroundColor Green
}
finally {
    foreach ($letter in @($substLetters)) { & subst.exe $letter /D | Out-Null }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
