[CmdletBinding()]
param(
    [ValidateSet('Status','Configure','Sync','List','Projects','CreateProject','BindProject','UnbindProject','Enable','Disable','EnableArchived','DisableArchived','EnableAutomatic','DisableAutomatic','OpenVault')]
    [string]$Action = 'Status',
    [string]$VaultPath,
    [string]$ProjectId,
    [string]$CodexProjectId,
    [string]$ProjectName,
    [string]$LocalPath,
    [switch]$Json,
    [switch]$Automatic,
    [string]$CodexHomeOverride,
    [string]$ConfigPathOverride,
    [string]$MachineIdOverride,
    [switch]$SkipProcessCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $script:Utf8NoBom
try { [Console]::OutputEncoding = $script:Utf8NoBom } catch {}
$script:ProductName = 'Codex Proxy History Sync'
$script:VaultDirectoryName = '.codex-history-vault'
$script:SyncRunId = [guid]::NewGuid().ToString('N').Substring(0, 12)

function Get-HistorySyncLocalRoot {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexProxy'
}

function Get-HistorySyncConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($ConfigPathOverride)) { return [IO.Path]::GetFullPath($ConfigPathOverride) }
    Join-Path (Get-HistorySyncLocalRoot) 'history-sync.json'
}

function Get-HistorySyncCodexHome {
    if (-not [string]::IsNullOrWhiteSpace($CodexHomeOverride)) { return [IO.Path]::GetFullPath($CodexHomeOverride) }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { return [IO.Path]::GetFullPath($env:CODEX_HOME) }
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
}

function Get-HistorySyncLogPath {
    Join-Path (Get-HistorySyncLocalRoot) 'logs\history-sync.log'
}

function Write-HistorySyncLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO')
    try {
        $path = Get-HistorySyncLogPath
        $directory = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-Item -LiteralPath $path).Length -gt 2097152) {
            Move-Item -LiteralPath $path -Destination "$path.1" -Force
        }
        [IO.File]::AppendAllText($path, ('{0} [{1}] [{2}] {3}{4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$Level,$script:SyncRunId,$Message,[Environment]::NewLine), $script:Utf8NoBom)
    }
    catch {}
}

function Write-AtomicText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = Join-Path $directory ('.writing-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $Text, $script:Utf8NoBom)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-AtomicBytes {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = Join-Path $directory ('.writing-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-AtomicJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-AtomicText -Path $Path -Text (($Value | ConvertTo-Json -Depth 32) + [Environment]::NewLine)
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        Convert-HistoryJsonDatesToText -Value $value
        $value
    }
    catch { throw "JSON 文件损坏：$Path；$($_.Exception.Message)" }
}

function Convert-HistoryJsonDatesToText {
    param($Value)
    if ($null -eq $Value -or $Value -is [string]) { return }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $child = $Value[$key]
            if ($child -is [DateTime]) { $Value[$key] = ([DateTime]$child).ToUniversalTime().ToString('o') }
            elseif ($child -is [DateTimeOffset]) { $Value[$key] = ([DateTimeOffset]$child).UtcDateTime.ToString('o') }
            else { Convert-HistoryJsonDatesToText -Value $child }
        }
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        foreach ($child in $Value) { Convert-HistoryJsonDatesToText -Value $child }
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        $child = $property.Value
        if ($child -is [DateTime]) { $property.Value = ([DateTime]$child).ToUniversalTime().ToString('o') }
        elseif ($child -is [DateTimeOffset]) { $property.Value = ([DateTimeOffset]$child).UtcDateTime.ToString('o') }
        else { Convert-HistoryJsonDatesToText -Value $child }
    }
}

function Get-PropertyValue {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    $property.Value
}

function ConvertTo-HistoryUtcText {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime().ToString('o') }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime.ToString('o') }
    $text = [string]$Value
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($text, [ref]$parsed)) { return $parsed.UtcDateTime.ToString('o') }
    $text
}

function Normalize-HistoryDirectoryPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '工作目录不能为空。' }
    if (-not [IO.Path]::IsPathRooted($Path)) { throw "工作目录必须是绝对路径：$Path" }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if (-not $full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { $full = $full.TrimEnd([char[]]@('\','/')) }
    $full
}

function Get-HistoryProjectBindings {
    param($Config)
    if ($null -eq $Config) { return @() }
    @((Get-PropertyValue $Config 'ProjectBindings' @()) | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $_ 'ProjectId' '')) -and
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $_ 'LocalPath' ''))
    })
}

function Get-HistoryAllProjectBindings {
    param($Config)
    if ($null -eq $Config) { return @() }
    $byId = @{}
    foreach ($binding in @(@(Get-HistoryProjectBindings -Config $Config) + @(Get-HistoryCodexProjectBindings -Config $Config))) {
        $id = [string](Get-PropertyValue $binding 'ProjectId' '')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $isModern = -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $binding 'CodexProjectId' ''))
        if (-not $byId.ContainsKey($id) -or $isModern) { $byId[$id] = $binding }
    }
    @($byId.Values)
}

function Get-HistoryLegacyBindingForCodexProject {
    param($Config, $CodexProject, [object[]]$AllCodexProjects)
    if ($null -eq $Config -or $null -eq $CodexProject) { return $null }
    $matches = New-Object Collections.Generic.List[object]
    $projectRoots = @((Get-PropertyValue $CodexProject 'RootPaths' @()))
    $projectId = [string](Get-PropertyValue $CodexProject 'CodexProjectId' '')
    $sharedRoot = $false
    foreach ($otherProject in @($AllCodexProjects)) {
        $otherId = [string](Get-PropertyValue $otherProject 'CodexProjectId' '')
        if ([string]::IsNullOrWhiteSpace($otherId) -or $otherId.Equals($projectId, [StringComparison]::OrdinalIgnoreCase)) { continue }
        foreach ($projectRoot in $projectRoots) {
            foreach ($otherRoot in @((Get-PropertyValue $otherProject 'RootPaths' @()))) {
                try {
                    if ((Normalize-HistoryDirectoryPath -Path ([string]$projectRoot)).Equals((Normalize-HistoryDirectoryPath -Path ([string]$otherRoot)), [StringComparison]::OrdinalIgnoreCase)) { $sharedRoot = $true; break }
                }
                catch {}
            }
            if ($sharedRoot) { break }
        }
        if ($sharedRoot) { break }
    }
    if ($sharedRoot) { return $null }
    foreach ($binding in @(Get-HistoryProjectBindings -Config $Config)) {
        $bindingRoots = @(Get-HistoryBindingRootPaths -Binding $binding)
        $matched = $false
        foreach ($bindingRoot in $bindingRoots) {
            foreach ($projectRoot in $projectRoots) {
                try {
                    if ((Normalize-HistoryDirectoryPath -Path ([string]$bindingRoot)).Equals((Normalize-HistoryDirectoryPath -Path ([string]$projectRoot)), [StringComparison]::OrdinalIgnoreCase)) { $matched = $true; break }
                }
                catch {}
            }
            if ($matched) { break }
        }
        if ($matched) { $matches.Add($binding) }
    }
    $ids = @($matches | ForEach-Object { [string](Get-PropertyValue $_ 'ProjectId' '') } | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count -eq 1) { return $matches[0] }
    $null
}

function Get-HistoryProjectBindingById {
    param($Config, [string]$ProjectId)
    $modern = @(Get-HistoryCodexProjectBindings -Config $Config | Where-Object {
        ([string](Get-PropertyValue $_ 'ProjectId' '')).Equals($ProjectId, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
    if ($modern.Count -gt 0) { return $modern[0] }
    @(Get-HistoryProjectBindings -Config $Config | Where-Object {
        ([string](Get-PropertyValue $_ 'ProjectId' '')).Equals($ProjectId, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
}

function Get-HistoryProjectBindingForRef {
    param($Config, $Ref)
    $projectId = [string](Get-PropertyValue $Ref 'ProjectId' '')
    $codexId = [string](Get-PropertyValue $Ref 'CodexProjectId' '')
    $machineId = [string](Get-PropertyValue $Ref 'MachineId' '')
    $candidates = @(Get-HistoryCodexProjectBindings -Config $Config | Where-Object {
        ([string](Get-PropertyValue $_ 'ProjectId' '')).Equals($projectId, [StringComparison]::OrdinalIgnoreCase)
    })
    if (-not [string]::IsNullOrWhiteSpace($codexId)) {
        $exact = @($candidates | Where-Object {
            ([string](Get-PropertyValue $_ 'CodexProjectId' '')).Equals($codexId, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($exact.Count -eq 1) { return $exact[0] }
        if (-not [string]::IsNullOrWhiteSpace($machineId)) {
            $machineExact = @($exact | Where-Object { ([string](Get-PropertyValue $_ 'MachineId' '')).Equals($machineId, [StringComparison]::OrdinalIgnoreCase) })
            if ($machineExact.Count -gt 0) { return $machineExact[0] }
        }
        if ($exact.Count -gt 0) { return $exact[0] }
    }
    if ($candidates.Count -eq 1) { return $candidates[0] }
    if ($candidates.Count -gt 1) {
        throw "同步项目 $projectId 在本机存在多个 Codex 项目绑定，且无法根据引用确定导入目标；请保留一个导入目标后重试。"
    }
    Get-HistoryProjectBindingById -Config $Config -ProjectId $projectId
}

function Get-HistoryProjectBindingForPath {
    param($Config, [string]$WorkingDirectory)
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory) -or -not [IO.Path]::IsPathRooted($WorkingDirectory)) { return $null }
    try { $normalized = Normalize-HistoryDirectoryPath -Path $WorkingDirectory } catch { return $null }
    foreach ($binding in @(Get-HistoryAllProjectBindings -Config $Config)) {
        $candidates = @([string](Get-PropertyValue $binding 'LocalPath' '')) + @((Get-PropertyValue $binding 'KnownLocalPaths' @()) | ForEach-Object { [string]$_ })
        $candidates += @((Get-HistoryBindingRootPaths -Binding $binding))
        foreach ($candidate in $candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
            try {
                if ((Normalize-HistoryDirectoryPath -Path $candidate).Equals($normalized, [StringComparison]::OrdinalIgnoreCase) -or (Test-HistoryPathWithinRoot -Path $normalized -Root $candidate)) { return $binding }
            }
            catch {}
        }
    }
    $null
}

function Update-HistoryProjectBindingVolumePaths {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$VolumeRoot)
    $changed = $false
    $bindings = @(Get-HistoryProjectBindings -Config $Config)
    foreach ($binding in $bindings) {
        $relative = [string](Get-PropertyValue $binding 'PathRelativeToVolume' '')
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        $mapped = Normalize-HistoryDirectoryPath -Path (Join-Path $VolumeRoot $relative)
        $current = [string](Get-PropertyValue $binding 'LocalPath' '')
        $known = @((Get-PropertyValue $binding 'KnownLocalPaths' @()) | ForEach-Object { [string]$_ })
        if (-not [string]::IsNullOrWhiteSpace($current) -and $known -notcontains $current) { $known += $current }
        if ($known -notcontains $mapped) { $known += $mapped; $changed = $true }
        if ($binding.PSObject.Properties['KnownLocalPaths']) { $binding.KnownLocalPaths = @($known | Select-Object -Unique) }
        else { $binding | Add-Member -NotePropertyName KnownLocalPaths -NotePropertyValue @($known | Select-Object -Unique) }
        if (-not $current.Equals($mapped, [StringComparison]::OrdinalIgnoreCase)) { $binding.LocalPath = $mapped; $changed = $true }
    }
    if ($changed -and $Config.PSObject.Properties['ProjectBindings']) { $Config.ProjectBindings = @($bindings) }
    $changed
}

function Update-HistoryCodexProjectBindingVolumePaths {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$VolumeRoot)
    $changed = $false
    $bindings = @(Get-HistoryCodexProjectBindings -Config $Config)
    foreach ($binding in $bindings) {
        $roots = New-Object Collections.Generic.List[object]
        foreach ($root in @((Get-PropertyValue $binding 'RootPaths' @()))) {
            $localPath = if ($root -is [string]) { [string]$root } else { [string](Get-PropertyValue $root 'LocalPath' '') }
            $relative = if ($root -is [string]) { '' } else { [string](Get-PropertyValue $root 'PathRelativeToVolume' '') }
            $known = New-Object Collections.Generic.List[string]
            if (-not [string]::IsNullOrWhiteSpace($localPath)) { try { $known.Add((Normalize-HistoryDirectoryPath -Path $localPath)) } catch {} }
            if ($root -isnot [string]) { foreach ($knownPath in @((Get-PropertyValue $root 'KnownLocalPaths' @()))) { try { if (-not [string]::IsNullOrWhiteSpace([string]$knownPath)) { $known.Add((Normalize-HistoryDirectoryPath -Path ([string]$knownPath))) } } catch {} } }
            if (-not [string]::IsNullOrWhiteSpace($relative)) {
                try {
                    $mapped = Normalize-HistoryDirectoryPath -Path (Join-Path $VolumeRoot $relative)
                    if (-not $known.Contains($mapped)) { $known.Add($mapped); $changed=$true }
                    if (-not $mapped.Equals($localPath, [StringComparison]::OrdinalIgnoreCase)) { $localPath=$mapped; $changed=$true }
                } catch {}
            }
            $roots.Add([pscustomobject]@{ LocalPath=$localPath; KnownLocalPaths=@($known | Select-Object -Unique); PathRelativeToVolume=$relative })
        }
        $rootArray = @($roots.ToArray())
        if ($binding.PSObject.Properties['RootPaths']) { $binding.RootPaths=$rootArray } else { $binding | Add-Member -NotePropertyName RootPaths -NotePropertyValue $rootArray }
        $first = if($roots.Count -gt 0){[string]$roots[0].LocalPath}else{''}
        if ($binding.PSObject.Properties['LocalPath'] -and -not [string]::IsNullOrWhiteSpace($first) -and -not ([string]$binding.LocalPath).Equals($first,[StringComparison]::OrdinalIgnoreCase)) { $binding.LocalPath=$first; $changed=$true }
    }
    if ($changed -and $Config.PSObject.Properties['CodexProjectBindings']) { $Config.CodexProjectBindings=@($bindings); Write-AtomicJson -Path (Get-HistorySyncConfigPath) -Value $Config }
    $changed
}

function Get-HistoryProjectPath {
    param([Parameter(Mandatory)][string]$VaultRoot, [Parameter(Mandatory)][string]$ProjectId)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($ProjectId, [ref]$parsed)) { throw '同步项目 ID 无效。' }
    Join-Path $VaultRoot ('projects\' + $ProjectId.ToLowerInvariant() + '.json')
}

function Get-AllHistoryProjects {
    param([Parameter(Mandatory)][string]$VaultRoot)
    $result = New-Object Collections.Generic.List[object]
    $directory = Join-Path $VaultRoot 'projects'
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $result }
    foreach ($file in Get-ChildItem -LiteralPath $directory -File -Filter '*.json' -ErrorAction SilentlyContinue) {
        try {
            $project = Read-JsonFile -Path $file.FullName
            $id = [string](Get-PropertyValue $project 'ProjectId' '')
            $parsed = [guid]::Empty
            if ([guid]::TryParse($id, [ref]$parsed)) { $result.Add($project) }
        }
        catch { Write-HistorySyncLog -Level WARN -Message "忽略损坏的同步项目：$($file.FullName)" }
    }
    $result
}

function Get-HistoryProjectNameMap {
    param([Parameter(Mandatory)][string]$VaultRoot)
    $map = @{}
    foreach ($project in Get-AllHistoryProjects -VaultRoot $VaultRoot) {
        $id = [string](Get-PropertyValue $project 'ProjectId' '')
        $map[$id] = [string](Get-PropertyValue $project 'Name' ('同步项目 ' + $id.Substring(0,8)))
    }
    $map
}

function Save-HistoryProjectBindings {
    param([Parameter(Mandatory)]$Config, [AllowEmptyCollection()][object[]]$Bindings)
    if ($Config.PSObject.Properties['ProjectBindings']) { $Config.ProjectBindings = @($Bindings) }
    else { $Config | Add-Member -NotePropertyName ProjectBindings -NotePropertyValue @($Bindings) }
    if ($Config.PSObject.Properties['SchemaVersion']) { $Config.SchemaVersion = 4 }
    Write-AtomicJson -Path (Get-HistorySyncConfigPath) -Value $Config
}

function Save-HistoryCodexProjectBindings {
    param([Parameter(Mandatory)]$Config, [AllowEmptyCollection()][object[]]$Bindings)
    if ($Config.PSObject.Properties['CodexProjectBindings']) { $Config.CodexProjectBindings = @($Bindings) }
    else { $Config | Add-Member -NotePropertyName CodexProjectBindings -NotePropertyValue @($Bindings) }
    if ($Config.PSObject.Properties['SchemaVersion']) { $Config.SchemaVersion = 4 }
    Write-AtomicJson -Path (Get-HistorySyncConfigPath) -Value $Config
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Get-RelativePathFromRoot {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $pathFull.Substring($rootFull.Length)
}

function Encode-PortableRelativePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    (@($RelativePath -split '[\\/]' | Where-Object { $_ -ne '' } | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')
}

function Decode-PortableRelativePath {
    param([Parameter(Mandatory)][string]$EncodedPath)
    $segments = @($EncodedPath -split '/' | Where-Object { $_ -ne '' } | ForEach-Object { [Uri]::UnescapeDataString($_) })
    if ($segments | Where-Object { $_ -eq '.' -or $_ -eq '..' -or $_.Contains('\') -or $_.Contains('/') }) { throw '历史仓库包含不安全的工作目录映射。' }
    $segments -join '\'
}

function Get-VaultMarkerPath {
    param([Parameter(Mandatory)][string]$VaultRoot)
    Join-Path $VaultRoot 'vault.json'
}

function Resolve-HistoryVaultRelativePath {
    param([Parameter(Mandatory)][string]$VaultRoot, [Parameter(Mandatory)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw '历史对象路径不能为空。' }
    $candidateText = $RelativePath.Replace('/', '\')
    if ([IO.Path]::IsPathRooted($candidateText) -or $candidateText -match '(^|\\)\.\.(\\|$)') { throw '历史对象路径不安全。' }
    $vaultFull = [IO.Path]::GetFullPath($VaultRoot).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath((Join-Path $VaultRoot $candidateText))
    if (-not $candidate.StartsWith($vaultFull, [StringComparison]::OrdinalIgnoreCase)) { throw '历史对象路径超出仓库根目录。' }
    $candidate
}

function Test-VaultIdentity {
    param([Parameter(Mandatory)][string]$VaultRoot, [Parameter(Mandatory)][string]$VaultId)
    try {
        $marker = Read-JsonFile -Path (Get-VaultMarkerPath -VaultRoot $VaultRoot)
        return $null -ne $marker -and [string](Get-PropertyValue $marker 'VaultId' '') -eq $VaultId -and [int](Get-PropertyValue $marker 'SchemaVersion' 0) -eq 1
    }
    catch { return $false }
}

function Resolve-HistoryVault {
    param([Parameter(Mandatory)]$Config)
    $vaultId = [string](Get-PropertyValue $Config 'VaultId' '')
    if ([string]::IsNullOrWhiteSpace($vaultId)) { return $null }
    $lastPath = [string](Get-PropertyValue $Config 'LastKnownVaultPath' '')
    if (-not [string]::IsNullOrWhiteSpace($lastPath) -and (Test-VaultIdentity -VaultRoot $lastPath -VaultId $vaultId)) {
        $resolvedLastPath = [IO.Path]::GetFullPath($lastPath)
        if (Update-HistoryProjectBindingVolumePaths -Config $Config -VolumeRoot ([IO.Path]::GetPathRoot($resolvedLastPath))) {
            Write-AtomicJson -Path (Get-HistorySyncConfigPath) -Value $Config
        }
        Update-HistoryCodexProjectBindingVolumePaths -Config $Config -VolumeRoot ([IO.Path]::GetPathRoot($resolvedLastPath)) | Out-Null
        return $resolvedLastPath
    }

    $relative = [string](Get-PropertyValue $Config 'VaultRelativeToVolume' '')
    if ([string]::IsNullOrWhiteSpace($relative)) { return $null }
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            $candidate = Join-Path $drive.RootDirectory.FullName $relative
            if (Test-VaultIdentity -VaultRoot $candidate -VaultId $vaultId) {
                $Config.LastKnownVaultPath = [IO.Path]::GetFullPath($candidate)
                $currentVolumeRoot = [IO.Path]::GetPathRoot($Config.LastKnownVaultPath)
                Update-HistoryProjectBindingVolumePaths -Config $Config -VolumeRoot $currentVolumeRoot | Out-Null
                Update-HistoryCodexProjectBindingVolumePaths -Config $Config -VolumeRoot $currentVolumeRoot | Out-Null
                $knownRoots = @((Get-PropertyValue $Config 'KnownVolumeRoots' @()) | ForEach-Object { [string]$_ })
                if ($knownRoots -notcontains $currentVolumeRoot) { $knownRoots += $currentVolumeRoot }
                if ($Config.PSObject.Properties['KnownVolumeRoots']) { $Config.KnownVolumeRoots = @($knownRoots | Select-Object -Unique) }
                else { $Config | Add-Member -NotePropertyName KnownVolumeRoots -NotePropertyValue @($knownRoots | Select-Object -Unique) }
                Write-AtomicJson -Path (Get-HistorySyncConfigPath) -Value $Config
                return $Config.LastKnownVaultPath
            }
        }
        catch { continue }
    }
    $null
}

function Initialize-HistoryVault {
    param([Parameter(Mandatory)][string]$SelectedPath, $ExistingConfig)
    $selectedFull = [IO.Path]::GetFullPath($SelectedPath)
    if (-not (Test-Path -LiteralPath $selectedFull -PathType Container)) { New-Item -ItemType Directory -Path $selectedFull -Force | Out-Null }
    $vaultRoot = if ([IO.Path]::GetFileName($selectedFull.TrimEnd('\')) -eq $script:VaultDirectoryName) { $selectedFull } else { Join-Path $selectedFull $script:VaultDirectoryName }
    if (-not (Test-Path -LiteralPath $vaultRoot -PathType Container)) { New-Item -ItemType Directory -Path $vaultRoot -Force | Out-Null }
    $markerPath = Get-VaultMarkerPath -VaultRoot $vaultRoot
    $marker = Read-JsonFile -Path $markerPath
    if ($null -eq $marker) {
        $marker = [pscustomobject]@{
            SchemaVersion = 1
            VaultId = [guid]::NewGuid().ToString()
            Product = $script:ProductName
            CreatedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-AtomicJson -Path $markerPath -Value $marker
    }
    if ([int](Get-PropertyValue $marker 'SchemaVersion' 0) -ne 1 -or [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $marker 'VaultId' ''))) {
        throw "不是受支持的 Codex 历史仓库：$vaultRoot"
    }
    foreach ($child in @('objects','refs','machines','projects')) {
        $childPath = Join-Path $vaultRoot $child
        if (-not (Test-Path -LiteralPath $childPath -PathType Container)) { New-Item -ItemType Directory -Path $childPath -Force | Out-Null }
    }

    $machineId = [string](Get-PropertyValue $ExistingConfig 'MachineId' '')
    if (-not [string]::IsNullOrWhiteSpace($MachineIdOverride)) { $machineId = $MachineIdOverride }
    if ([string]::IsNullOrWhiteSpace($machineId)) { $machineId = [guid]::NewGuid().ToString() }
    $volumeRoot = [IO.Path]::GetPathRoot($vaultRoot)
    $relative = Get-RelativePathFromRoot -Root $volumeRoot -Path $vaultRoot
    $knownRoots = @((Get-PropertyValue $ExistingConfig 'KnownVolumeRoots' @()) | ForEach-Object { [string]$_ })
    if ($knownRoots -notcontains $volumeRoot) { $knownRoots += $volumeRoot }
    $existingVaultId = [string](Get-PropertyValue $ExistingConfig 'VaultId' '')
    $projectBindings = if ($existingVaultId -eq [string]$marker.VaultId) { @(Get-HistoryProjectBindings -Config $ExistingConfig) } else { @() }
    $config = [pscustomobject]@{
        SchemaVersion = 4
        Enabled = if ($ExistingConfig -and $ExistingConfig.PSObject.Properties['Enabled']) { [bool](Get-PropertyValue $ExistingConfig 'Enabled' $false) } else { $false }
        AutomaticWriteEnabled = [bool](Get-PropertyValue $ExistingConfig 'AutomaticWriteEnabled' $false)
        SyncArchived = $false
        VaultId = [string]$marker.VaultId
        LastKnownVaultPath = [IO.Path]::GetFullPath($vaultRoot)
        VaultRelativeToVolume = $relative
        KnownVolumeRoots = @($knownRoots | Select-Object -Unique)
        MachineId = $machineId
        MachineName = [Environment]::MachineName
        # ProjectBindings is retained for backwards compatibility. New
        # installations use CodexProjectBindings, which mirrors Codex's
        # local-projects and thread-project-assignments model.
        ProjectBindings = @($projectBindings)
        CodexProjectBindings = @((Get-PropertyValue $ExistingConfig 'CodexProjectBindings' @()))
        LastSyncUtc = [string](Get-PropertyValue $ExistingConfig 'LastSyncUtc' '')
        LastSyncOutcome = [string](Get-PropertyValue $ExistingConfig 'LastSyncOutcome' 'Never')
        LastSyncMessage = [string](Get-PropertyValue $ExistingConfig 'LastSyncMessage' '')
    }
    Write-AtomicJson -Path (Get-HistorySyncConfigPath) -Value $config
    $machinePath = Join-Path $vaultRoot ('machines\' + $machineId + '.json')
    Write-AtomicJson -Path $machinePath -Value ([pscustomobject]@{
        SchemaVersion = 1; MachineId = $machineId; MachineName = [Environment]::MachineName
        FirstSeenUtc = [DateTime]::UtcNow.ToString('o'); LastSeenUtc = [DateTime]::UtcNow.ToString('o')
    })
    [pscustomobject]@{ Config=$config; VaultRoot=$vaultRoot }
}

function Test-CodexDesktopRunning {
    if ($SkipProcessCheck) { return $false }
    try {
        $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)
        foreach ($package in $packages) {
            $root = ([IO.Path]::GetFullPath([string]$package.InstallLocation)).TrimEnd('\') + '\'
            $found = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                $_.ExecutablePath -and ([IO.Path]::GetFullPath([string]$_.ExecutablePath)).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)
            if ($found.Count -gt 0) { return $true }
        }
    }
    catch {}
    try {
        $standalone = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'codex%.exe'" -ErrorAction SilentlyContinue | Where-Object {
            -not [string]::Equals([string]$_.Name, 'CodexProxy.exe', [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($standalone.Count -gt 0) { return $true }
    }
    catch {}
    $false
}

function Get-SessionIndexMap {
    param([Parameter(Mandatory)][string]$CodexHome)
    $map = @{}
    $path = Join-Path $CodexHome 'session_index.jsonl'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    $stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                $id = [string](Get-PropertyValue $entry 'id' '')
                if (-not [string]::IsNullOrWhiteSpace($id)) { $map[$id] = $entry }
            }
            catch {}
        }
    }
    finally { $reader.Dispose(); $stream.Dispose() }
    $map
}

# Codex keeps the actual project model in .codex-global-state.json.  A project
# has an id, a name and one or more rootPaths; threads are assigned to that
# project independently of their cwd.  History sync treats this state as the
# authoritative source and only falls back to cwd for legacy installations.
function Get-CodexGlobalStatePath {
    param([Parameter(Mandatory)][string]$CodexHome)
    Join-Path $CodexHome '.codex-global-state.json'
}

function Get-CodexGlobalState {
    param([Parameter(Mandatory)][string]$CodexHome)
    $path = Get-CodexGlobalStatePath -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { Read-JsonFile -Path $path }
    catch {
        Write-HistorySyncLog -Level WARN -Message "无法读取 Codex 项目状态，旧目录回退模式将继续：$($_.Exception.Message)"
        $null
    }
}

function Get-CodexPersistedAtomState {
    param($GlobalState)
    if ($null -eq $GlobalState) { return $null }
    $persisted = Get-PropertyValue $GlobalState 'electron-persisted-atom-state' $null
    if ($null -eq $persisted) { $persisted = Get-PropertyValue $GlobalState 'electron_persisted_atom_state' $null }
    $persisted
}

function Get-CodexLocalProjectCatalog {
    param([Parameter(Mandatory)][string]$CodexHome)
    $result = New-Object Collections.Generic.List[object]
    $state = Get-CodexGlobalState -CodexHome $CodexHome
    $persisted = Get-CodexPersistedAtomState -GlobalState $state
    $raw = Get-PropertyValue $state 'local-projects' $null
    if ($null -eq $raw) { $raw = Get-PropertyValue $persisted 'local-projects' $null }
    if ($null -eq $raw) { return $result }
    foreach ($property in @($raw.PSObject.Properties)) {
        $project = $property.Value
        $id = [string]$property.Name
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $roots = New-Object Collections.Generic.List[string]
        foreach ($candidate in @((Get-PropertyValue $project 'rootPaths' @()))) {
            try {
                if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
                $normalized = Normalize-HistoryDirectoryPath -Path ([string]$candidate)
                if (-not $roots.Contains($normalized)) { $roots.Add($normalized) }
            }
            catch {}
        }
        $name = [string](Get-PropertyValue $project 'name' '')
        if ([string]::IsNullOrWhiteSpace($name)) { $name = if ($roots.Count -gt 0) { [IO.Path]::GetFileName($roots[0].TrimEnd('\')) } else { $id.Substring(0,[Math]::Min(8,$id.Length)) } }
        $result.Add([pscustomobject]@{
            CodexProjectId=$id; Name=$name; RootPaths=@($roots.ToArray()); CreatedAt=Get-PropertyValue $project 'createdAt' 0; UpdatedAt=Get-PropertyValue $project 'updatedAt' 0
        })
    }
    $result
}

function Get-CodexThreadProjectMap {
    param([Parameter(Mandatory)][string]$CodexHome)
    $map = @{}
    $state = Get-CodexGlobalState -CodexHome $CodexHome
    $persisted = Get-CodexPersistedAtomState -GlobalState $state
    $raw = Get-PropertyValue $state 'thread-project-assignments' $null
    if ($null -eq $raw) { $raw = Get-PropertyValue $persisted 'thread-project-assignments' $null }
    if ($null -eq $raw) { return $map }
    foreach ($property in @($raw.PSObject.Properties)) {
        $assignment = $property.Value
        $kind = [string](Get-PropertyValue $assignment 'projectKind' '')
        $id = [string](Get-PropertyValue $assignment 'projectId' '')
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            $map[[string]$property.Name] = [pscustomobject]@{ ProjectKind=$kind; CodexProjectId=$id }
        }
    }
    $map
}

function Test-HistoryPathWithinRoot {
    param([string]$Path, [string]$Root)
    try {
        $pathFull = Normalize-HistoryDirectoryPath -Path $Path
        $rootFull = Normalize-HistoryDirectoryPath -Path $Root
        return $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or $pathFull.StartsWith($rootFull.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Find-CodexProjectRootMatch {
    param($Project, [string]$WorkingDirectory)
    $bestIndex = -1
    $bestRoot = $null
    $bestLength = -1
    $roots = @((Get-PropertyValue $Project 'RootPaths' @()))
    for ($index=0; $index -lt $roots.Count; $index++) {
        $root = [string]$roots[$index]
        if (-not (Test-HistoryPathWithinRoot -Path $WorkingDirectory -Root $root)) { continue }
        if ($root.Length -gt $bestLength) { $bestIndex=$index; $bestRoot=$root; $bestLength=$root.Length }
    }
    if ($bestIndex -lt 0) { return $null }
    [pscustomobject]@{ RootIndex=$bestIndex; RootPath=$bestRoot }
}

function Get-CodexSessionProjectInfo {
    param(
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$ThreadId,
        [string]$WorkingDirectory,
        $Projects,
        [hashtable]$ThreadProjectMap
    )
    if ($null -eq $Projects) { $Projects = @(Get-CodexLocalProjectCatalog -CodexHome $CodexHome) }
    if ($null -eq $ThreadProjectMap) { $ThreadProjectMap = Get-CodexThreadProjectMap -CodexHome $CodexHome }
    if ($ThreadProjectMap.ContainsKey($ThreadId)) {
        $assignment = $ThreadProjectMap[$ThreadId]
        $project = @($Projects | Where-Object { ([string](Get-PropertyValue $_ 'CodexProjectId' '')).Equals([string]$assignment.CodexProjectId, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
        if ($null -ne $project) {
            $match = if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { Find-CodexProjectRootMatch -Project $project -WorkingDirectory $WorkingDirectory } else { $null }
            return [pscustomobject]@{ ProjectKind=[string]$assignment.ProjectKind; CodexProjectId=[string]$project.CodexProjectId; CodexProjectName=[string]$project.Name; RootPaths=@($project.RootPaths); RootIndex=$(if($null -ne $match){$match.RootIndex}else{0}); RootPath=$(if($null -ne $match){$match.RootPath}else{if(@($project.RootPaths).Count -gt 0){@($project.RootPaths)[0]}else{''}}); MatchedBy='thread-assignment'; Ambiguous=$false }
        }
    }
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { return $null }
    $matches = New-Object Collections.Generic.List[object]
    foreach ($project in @($Projects)) {
        $match = Find-CodexProjectRootMatch -Project $project -WorkingDirectory $WorkingDirectory
        if ($null -ne $match) { $matches.Add([pscustomobject]@{ Project=$project; Match=$match }) }
    }
    if ($matches.Count -eq 1) {
        $project = $matches[0].Project; $match=$matches[0].Match
        return [pscustomobject]@{ ProjectKind='local'; CodexProjectId=[string]$project.CodexProjectId; CodexProjectName=[string]$project.Name; RootPaths=@($project.RootPaths); RootIndex=$match.RootIndex; RootPath=$match.RootPath; MatchedBy='cwd-fallback'; Ambiguous=$false }
    }
    if ($matches.Count -gt 1) { return [pscustomobject]@{ ProjectKind='ambiguous'; CodexProjectId=''; CodexProjectName=''; RootPaths=@(); RootIndex=-1; RootPath=''; MatchedBy='cwd-fallback'; Ambiguous=$true } }
    $null
}

function Get-HistoryCodexProjectBindings {
    param($Config)
    if ($null -eq $Config) { return @() }
    @((Get-PropertyValue $Config 'CodexProjectBindings' @()) | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $_ 'ProjectId' '')) -and
        -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $_ 'CodexProjectId' ''))
    })
}

function Get-HistoryCodexProjectBindingByCodexId {
    param($Config, [string]$CodexProjectId)
    @(Get-HistoryCodexProjectBindings -Config $Config | Where-Object { ([string](Get-PropertyValue $_ 'CodexProjectId' '')).Equals($CodexProjectId, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
}

function Get-HistoryBindingRootPaths {
    param($Binding)
    $roots = New-Object Collections.Generic.List[string]
    foreach ($candidate in @((Get-PropertyValue $Binding 'RootPaths' @()))) {
        if ($candidate -is [string]) { $value=[string]$candidate }
        else { $value=[string](Get-PropertyValue $candidate 'LocalPath' '') }
        try { if (-not [string]::IsNullOrWhiteSpace($value)) { $normalized=Normalize-HistoryDirectoryPath -Path $value; if (-not $roots.Contains($normalized)){$roots.Add($normalized)} } } catch {}
    }
    if ($roots.Count -eq 0) {
        $legacy = [string](Get-PropertyValue $Binding 'LocalPath' '')
        if (-not [string]::IsNullOrWhiteSpace($legacy)) { try { $roots.Add((Normalize-HistoryDirectoryPath -Path $legacy)) } catch {} }
    }
    @($roots.ToArray())
}

function Get-HistoryBindingRootAtIndex {
    param($Binding, [int]$Index = 0)
    $roots = @(Get-HistoryBindingRootPaths -Binding $Binding)
    if ($roots.Count -eq 0) { return '' }
    if ($Index -lt 0 -or $Index -ge $roots.Count) { $Index=0 }
    [string]$roots[$Index]
}

function Get-FirstLineParts {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $newline = [Array]::IndexOf($Bytes, [byte]10)
    if ($newline -lt 0) { $newline = $Bytes.Length }
    $firstCount = $newline
    if ($firstCount -gt 0 -and $Bytes[$firstCount - 1] -eq 13) { $firstCount-- }
    $first = [Text.Encoding]::UTF8.GetString($Bytes, 0, $firstCount).TrimStart([char]0xFEFF)
    $restOffset = if ($newline -lt $Bytes.Length) { $newline + 1 } else { $Bytes.Length }
    [pscustomobject]@{ First=$first; RestOffset=$restOffset }
}

function Read-StableSessionBytes {
    param([Parameter(Mandatory)][string]$Path, [int]$Attempts = 4)
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $before = Get-Item -LiteralPath $Path -ErrorAction Stop
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $memory = New-Object IO.MemoryStream
            try { $stream.CopyTo($memory); $bytes = $memory.ToArray() }
            finally { $memory.Dispose() }
        }
        finally { $stream.Dispose() }
        $after = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($before.Length -eq $after.Length -and $before.LastWriteTimeUtc.Ticks -eq $after.LastWriteTimeUtc.Ticks -and $bytes.Length -eq $after.Length) {
            if ($bytes.Length -eq 0) { throw "会话文件为空：$Path" }
            if ($bytes[$bytes.Length - 1] -ne 10) {
                $lastNewline = [Array]::LastIndexOf($bytes, [byte]10)
                if ($lastNewline -lt 0) { throw "会话尚未写完首行：$Path" }
                $complete = New-Object byte[] ($lastNewline + 1)
                [Array]::Copy($bytes, 0, $complete, 0, $complete.Length)
                return $complete
            }
            return $bytes
        }
        Start-Sleep -Milliseconds (75 * $attempt)
    }
    throw "会话仍在快速写入，已留待下一轮实时同步：$Path"
}

function Join-JsonFirstLineAndRest {
    param([Parameter(Mandatory)][string]$FirstLine, [Parameter(Mandatory)][byte[]]$OriginalBytes, [Parameter(Mandatory)][int]$RestOffset)
    $firstBytes = [Text.Encoding]::UTF8.GetBytes($FirstLine + "`n")
    $restLength = $OriginalBytes.Length - $RestOffset
    $combined = New-Object byte[] ($firstBytes.Length + [Math]::Max(0, $restLength))
    [Array]::Copy($firstBytes, 0, $combined, 0, $firstBytes.Length)
    if ($restLength -gt 0) { [Array]::Copy($OriginalBytes, $RestOffset, $combined, $firstBytes.Length, $restLength) }
    $combined
}

function Set-HistoryCanonicalProjectCwd {
    param(
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][string]$ProjectId,
        [string]$WorkingDirectory,
        [string]$ProjectRootPath,
        [int]$ProjectRootIndex = 0
    )
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { return }
    $index = if ($ProjectRootIndex -lt 0) { 0 } else { $ProjectRootIndex }
    $suffix = ''
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory) -and -not [string]::IsNullOrWhiteSpace($ProjectRootPath)) {
        try {
            $cwd = Normalize-HistoryDirectoryPath -Path $WorkingDirectory
            $root = Normalize-HistoryDirectoryPath -Path $ProjectRootPath
            $relative = if ($cwd.Equals($root,[StringComparison]::OrdinalIgnoreCase)) { '' } else { Get-RelativePathFromRoot -Root $root -Path $cwd }
            if ($index -gt 0 -or ($null -ne $relative -and -not [string]::IsNullOrWhiteSpace($relative))) {
                $suffix = 'r' + $index
                if ($null -ne $relative -and -not [string]::IsNullOrWhiteSpace($relative)) { $suffix += '/' + (Encode-PortableRelativePath -RelativePath $relative) }
            }
        }
        catch {}
    }
    $Payload.cwd = 'codex-project://' + $ProjectId.ToLowerInvariant() + $(if([string]::IsNullOrWhiteSpace($suffix)){''}else{'/' + $suffix})
}

function ConvertTo-CanonicalSession {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$VaultId,
        [Parameter(Mandatory)][string]$VaultRoot,
        [string[]]$KnownVolumeRoots,
        [string]$ProjectId,
        [string]$ProjectRootPath,
        [int]$ProjectRootIndex = 0
    )
    $bytes = Read-StableSessionBytes -Path $Path
    $parts = Get-FirstLineParts -Bytes $bytes
    try { $first = $parts.First | ConvertFrom-Json }
    catch { throw "会话首行不是有效 JSON：$Path" }
    if ([string](Get-PropertyValue $first 'type' '') -ne 'session_meta') { throw "会话缺少 session_meta 首行：$Path" }
    $payload = Get-PropertyValue $first 'payload'
    $id = [string](Get-PropertyValue $payload 'id' '')
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($id, [ref]$parsedId)) { throw "会话 ID 无效：$Path" }
    $cwd = [string](Get-PropertyValue $payload 'cwd' '')
    if (-not [string]::IsNullOrWhiteSpace($ProjectId)) { Set-HistoryCanonicalProjectCwd -Payload $payload -ProjectId $ProjectId -WorkingDirectory $cwd -ProjectRootPath $ProjectRootPath -ProjectRootIndex $ProjectRootIndex }
    elseif (-not [string]::IsNullOrWhiteSpace($cwd) -and [IO.Path]::IsPathRooted($cwd)) {
        $roots = @([IO.Path]::GetPathRoot($VaultRoot)) + @($KnownVolumeRoots)
        foreach ($volumeRoot in @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
            $relativeCwd = Get-RelativePathFromRoot -Root $volumeRoot -Path $cwd
            if ($null -ne $relativeCwd) {
                $payload.cwd = 'codex-vault://' + $VaultId + '/' + (Encode-PortableRelativePath -RelativePath $relativeCwd)
                break
            }
        }
    }
    $canonicalFirst = $first | ConvertTo-Json -Depth 32 -Compress
    $canonicalBytes = Join-JsonFirstLineAndRest -FirstLine $canonicalFirst -OriginalBytes $bytes -RestOffset $parts.RestOffset
    [pscustomobject]@{
        Id = $id
        Bytes = $canonicalBytes
        Hash = Get-Sha256Hex -Bytes $canonicalBytes
        Length = $canonicalBytes.Length
        Timestamp = [string](Get-PropertyValue $payload 'timestamp' '')
        Cwd = $cwd
        Provider = [string](Get-PropertyValue $payload 'model_provider' '')
        Source = (Get-PropertyValue $payload 'source' '')
        UpdatedUtc = Get-LatestSessionTimestamp -Path $Path
    }
}

function Get-CompleteJsonlLength {
    param([Parameter(Mandatory)][IO.FileStream]$Stream, [Parameter(Mandatory)][int64]$Length)
    if ($Length -le 0) { return [int64]0 }
    $bufferSize = 65536
    $cursor = $Length
    $buffer = New-Object byte[] $bufferSize
    while ($cursor -gt 0) {
        $start = [Math]::Max([int64]0, $cursor - $bufferSize)
        $count = [int]($cursor - $start)
        $Stream.Position = $start
        $read = 0
        while ($read -lt $count) {
            $part = $Stream.Read($buffer, $read, $count - $read)
            if ($part -le 0) { break }
            $read += $part
        }
        for ($i = $read - 1; $i -ge 0; $i--) {
            if ($buffer[$i] -eq 10) { return [int64]($start + $i + 1) }
        }
        $cursor = $start
    }
    [int64]0
}

function Get-LastJsonlTimestampFromStream {
    param([Parameter(Mandatory)][IO.FileStream]$Stream, [Parameter(Mandatory)][int64]$CompleteLength)
    if ($CompleteLength -le 0) { return $null }
    $savedPosition = $Stream.Position
    try {
        $lineEnd = $CompleteLength
        while ($lineEnd -gt 0) {
            $Stream.Position = $lineEnd - 1
            $value = $Stream.ReadByte()
            if ($value -eq 10 -or $value -eq 13) { $lineEnd-- } else { break }
        }
        if ($lineEnd -le 0) { return $null }
        $lineStart = [int64]0
        $cursor = $lineEnd
        $found = $false
        $searchBuffer = New-Object byte[] 65536
        while ($cursor -gt 0 -and -not $found) {
            $start = [Math]::Max([int64]0, $cursor - $searchBuffer.Length)
            $count = [int]($cursor - $start)
            $Stream.Position = $start
            $read = $Stream.Read($searchBuffer, 0, $count)
            for ($i = $read - 1; $i -ge 0; $i--) {
                if ($searchBuffer[$i] -eq 10) { $lineStart = $start + $i + 1; $found = $true; break }
            }
            $cursor = $start
        }
        $sampleLength = [int][Math]::Min([int64]4096, $lineEnd - $lineStart)
        if ($sampleLength -le 0) { return $null }
        $sample = New-Object byte[] $sampleLength
        $Stream.Position = $lineStart
        $read = $Stream.Read($sample, 0, $sampleLength)
        $text = [Text.Encoding]::UTF8.GetString($sample, 0, $read)
        $match = [regex]::Match($text, '"timestamp"\s*:\s*"([^"]+)"')
        if (-not $match.Success) { return $null }
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($match.Groups[1].Value, [ref]$parsed)) { return $null }
        $parsed.UtcDateTime.ToString('o')
    }
    finally { $Stream.Position = $savedPosition }
}

function Get-LatestSessionTimestamp {
    param([Parameter(Mandatory)][string]$Path)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $completeLength = Get-CompleteJsonlLength -Stream $stream -Length $stream.Length
        Get-LastJsonlTimestampFromStream -Stream $stream -CompleteLength $completeLength
    }
    catch { $null }
    finally { $stream.Dispose() }
}

function ConvertTo-CanonicalSessionFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$VaultId,
        [Parameter(Mandatory)][string]$VaultRoot,
        [string[]]$KnownVolumeRoots,
        [string]$ProjectId,
        [string]$ProjectRootPath,
        [int]$ProjectRootIndex = 0,
        [int]$Attempts = 4
    )
    $stagingDirectory = Join-Path $VaultRoot 'objects\.staging'
    if (-not (Test-Path -LiteralPath $stagingDirectory -PathType Container)) { New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $temporary = Join-Path $stagingDirectory ('.writing-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $source = $null
        $destination = $null
        try {
            $before = Get-Item -LiteralPath $Path -ErrorAction Stop
            $source = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $completeLength = Get-CompleteJsonlLength -Stream $source -Length $before.Length
            if ($completeLength -le 0) { throw "会话尚未写完首行：$Path" }
            $latestTimestamp = Get-LastJsonlTimestampFromStream -Stream $source -CompleteLength $completeLength

            $source.Position = 0
            $firstBuffer = New-Object IO.MemoryStream
            try {
                while ($source.Position -lt $completeLength) {
                    $value = $source.ReadByte()
                    if ($value -lt 0 -or $value -eq 10) { break }
                    if ($value -ne 13) { $firstBuffer.WriteByte([byte]$value) }
                }
                $firstText = [Text.Encoding]::UTF8.GetString($firstBuffer.ToArray()).TrimStart([char]0xFEFF)
            }
            finally { $firstBuffer.Dispose() }
            $restOffset = $source.Position
            try { $first = $firstText | ConvertFrom-Json }
            catch { throw "会话首行不是有效 JSON：$Path" }
            if ([string](Get-PropertyValue $first 'type' '') -ne 'session_meta') { throw "会话缺少 session_meta 首行：$Path" }
            $payload = Get-PropertyValue $first 'payload'
            $id = [string](Get-PropertyValue $payload 'id' '')
            $parsedId = [guid]::Empty
            if (-not [guid]::TryParse($id, [ref]$parsedId)) { throw "会话 ID 无效：$Path" }
            $cwd = [string](Get-PropertyValue $payload 'cwd' '')
            if (-not [string]::IsNullOrWhiteSpace($ProjectId)) { Set-HistoryCanonicalProjectCwd -Payload $payload -ProjectId $ProjectId -WorkingDirectory $cwd -ProjectRootPath $ProjectRootPath -ProjectRootIndex $ProjectRootIndex }
            elseif (-not [string]::IsNullOrWhiteSpace($cwd) -and [IO.Path]::IsPathRooted($cwd)) {
                $roots = @([IO.Path]::GetPathRoot($VaultRoot)) + @($KnownVolumeRoots)
                foreach ($volumeRoot in @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
                    $relativeCwd = Get-RelativePathFromRoot -Root $volumeRoot -Path $cwd
                    if ($null -ne $relativeCwd) {
                        $payload.cwd = 'codex-vault://' + $VaultId + '/' + (Encode-PortableRelativePath -RelativePath $relativeCwd)
                        break
                    }
                }
            }

            $canonicalFirst = [Text.Encoding]::UTF8.GetBytes(($first | ConvertTo-Json -Depth 32 -Compress) + "`n")
            $destination = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $destination.Write($canonicalFirst, 0, $canonicalFirst.Length)
            $source.Position = $restOffset
            $remaining = $completeLength - $restOffset
            $copyBuffer = New-Object byte[] 1048576
            while ($remaining -gt 0) {
                $wanted = [int][Math]::Min([int64]$copyBuffer.Length, $remaining)
                $read = $source.Read($copyBuffer, 0, $wanted)
                if ($read -le 0) { throw "读取会话时意外结束：$Path" }
                $destination.Write($copyBuffer, 0, $read)
                $remaining -= $read
            }
            $destination.Flush()
            $destination.Dispose(); $destination = $null
            $source.Dispose(); $source = $null

            $after = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($before.Length -ne $after.Length -or $before.LastWriteTimeUtc.Ticks -ne $after.LastWriteTimeUtc.Ticks) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds (75 * $attempt)
                continue
            }
            $hash = Get-FileSha256Hex -Path $temporary
            $canonicalLength = (Get-Item -LiteralPath $temporary).Length
            return [pscustomobject]@{
                Id=$id; Bytes=$null; TemporaryPath=$temporary; Hash=$hash; Length=$canonicalLength
                Timestamp=[string](Get-PropertyValue $payload 'timestamp' ''); Cwd=$cwd
                Provider=[string](Get-PropertyValue $payload 'model_provider' ''); Source=(Get-PropertyValue $payload 'source' '')
                UpdatedUtc=$latestTimestamp
            }
        }
        catch {
            if ($null -ne $destination) { $destination.Dispose() }
            if ($null -ne $source) { $source.Dispose() }
            if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
            throw
        }
    }
    throw "会话仍在快速写入，已留待下一轮实时同步：$Path"
}

function Set-HistoryMaterializedCwd {
    param(
        [Parameter(Mandatory)]$Payload,
        [string]$CanonicalCwd,
        [string]$ProjectLocalPath,
        [string[]]$ProjectRootPaths,
        [int]$ProjectRootIndex = 0,
        [string]$VaultId,
        [string]$VaultRoot
    )
    $cwd = [string]$CanonicalCwd
    $projectPrefix = 'codex-project://'
    $vaultPrefix = 'codex-vault://' + $VaultId + '/'
    if ($cwd.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $encoded = $cwd.Substring($projectPrefix.Length)
        $slash = $encoded.IndexOf('/')
        $tail = if ($slash -ge 0) { $encoded.Substring($slash + 1) } else { '' }
        $rootIndex = $ProjectRootIndex
        if ($tail -match '^r(\d+)(?:/(.*))?$') {
            $rootIndex = [int]$Matches[1]
            $tail = [string]$Matches[2]
        }
        $roots = @($ProjectRootPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($roots.Count -gt 0) {
            if ($rootIndex -lt 0 -or $rootIndex -ge $roots.Count) { throw "当前电脑的 Codex 项目缺少对应根目录（索引 r$rootIndex）。" }
            $projectPath = [string]$roots[$rootIndex]
        }
        else { $projectPath = [string]$ProjectLocalPath }
        if ([string]::IsNullOrWhiteSpace($projectPath)) { throw '当前电脑尚未绑定该同步项目的 Codex 项目。' }
        $projectPath = Normalize-HistoryDirectoryPath -Path $projectPath
        $relative = if ([string]::IsNullOrWhiteSpace($tail)) { '' } else { Decode-PortableRelativePath -EncodedPath $tail }
        if ([string]::IsNullOrWhiteSpace($relative)) { $Payload.cwd = $projectPath }
        else {
            $mapped = [IO.Path]::GetFullPath((Join-Path $projectPath $relative))
            $rootFull = $projectPath.TrimEnd('\') + '\'
            if (-not $mapped.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw '工作目录映射超出本机 Codex 项目根目录。' }
            $Payload.cwd = $mapped
        }
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($ProjectLocalPath)) { $Payload.cwd = Normalize-HistoryDirectoryPath -Path $ProjectLocalPath; return }
    if ($cwd.StartsWith($vaultPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = Decode-PortableRelativePath -EncodedPath $cwd.Substring($vaultPrefix.Length)
        $volumeRoot = [IO.Path]::GetPathRoot($VaultRoot)
        $mapped = [IO.Path]::GetFullPath((Join-Path $volumeRoot $relative))
        $rootFull = [IO.Path]::GetFullPath($volumeRoot).TrimEnd('\') + '\'
        if (-not $mapped.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw '工作目录映射超出移动磁盘根目录。' }
        $Payload.cwd = $mapped
    }
}

function ConvertFrom-CanonicalSession {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$VaultId,
        [Parameter(Mandatory)][string]$VaultRoot,
        [string]$ProjectLocalPath,
        [string[]]$ProjectRootPaths,
        [int]$ProjectRootIndex = 0,
        [string]$ReplacementId
    )
    $parts = Get-FirstLineParts -Bytes $Bytes
    $first = $parts.First | ConvertFrom-Json
    $payload = Get-PropertyValue $first 'payload'
    $cwd = [string](Get-PropertyValue $payload 'cwd' '')
    Set-HistoryMaterializedCwd -Payload $payload -CanonicalCwd $cwd -ProjectLocalPath $ProjectLocalPath -ProjectRootPaths $ProjectRootPaths -ProjectRootIndex $ProjectRootIndex -VaultId $VaultId -VaultRoot $VaultRoot
    if (-not [string]::IsNullOrWhiteSpace($ReplacementId)) {
        $payload.id = $ReplacementId
        if ($payload.PSObject.Properties['session_id']) { $payload.session_id = $ReplacementId }
    }
    $materializedFirst = $first | ConvertTo-Json -Depth 32 -Compress
    Join-JsonFirstLineAndRest -FirstLine $materializedFirst -OriginalBytes $Bytes -RestOffset $parts.RestOffset
}

function Get-LocalSessions {
    param([Parameter(Mandatory)][string]$CodexHome)
    $result = New-Object Collections.Generic.List[object]
    foreach ($descriptor in @(
        [pscustomobject]@{ Directory='sessions'; Archived=$false },
        [pscustomobject]@{ Directory='archived_sessions'; Archived=$true }
    )) {
        $root = Join-Path $CodexHome $descriptor.Directory
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue) {
            $relativePath = $file.FullName.Substring(([IO.Path]::GetFullPath($root)).TrimEnd('\').Length).TrimStart('\')
            $isImported = $relativePath -match '(?i)^synced-[^\\]+(?:\\|$)'
            $result.Add([pscustomobject]@{ Path=$file.FullName; Archived=$descriptor.Archived; Imported=$isImported; LastWriteTimeUtc=$file.LastWriteTimeUtc; Length=$file.Length; Name=$file.Name })
        }
    }
    $result
}

function Get-ImportedSessionMarkerPath {
    param([Parameter(Mandatory)][string]$SessionPath)
    $SessionPath + '.codex-proxy-import.json'
}

function Read-ImportedSessionMarker {
    param([Parameter(Mandatory)][string]$SessionPath)
    $markerPath = Get-ImportedSessionMarkerPath -SessionPath $SessionPath
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $null }
    try { Read-JsonFile -Path $markerPath } catch { $null }
}

function Write-ImportedSessionMarker {
    param(
        [Parameter(Mandatory)][string]$SessionPath,
        [Parameter(Mandatory)]$Ref,
        [Parameter(Mandatory)][string]$ObjectRelativePath
    )
    $file = Get-Item -LiteralPath $SessionPath -ErrorAction Stop
    Write-AtomicJson -Path (Get-ImportedSessionMarkerPath -SessionPath $SessionPath) -Value ([pscustomobject]@{
        SchemaVersion=1; ThreadId=[string](Get-PropertyValue $Ref 'ThreadId' ''); ContentHash=[string](Get-PropertyValue $Ref 'ContentHash' '')
        ContentLength=[int64](Get-PropertyValue $Ref 'ContentLength' 0); ObjectPath=$ObjectRelativePath.Replace('\','/')
        TargetLength=[int64]$file.Length; TargetLastWriteUtc=$file.LastWriteTimeUtc.ToString('o'); ImportedUtc=[DateTime]::UtcNow.ToString('o')
    })
}

function New-HistoryRef {
    param($Session, $LocalFile, $IndexEntry, [string]$MachineId, [string]$MachineName, [string]$ObjectRelativePath, [string]$ProjectId, [string]$ProjectName, [string]$CodexProjectId, [string]$CodexProjectName, [int]$ProjectRootIndex = 0, [string]$ProjectRootPath)
    $title = if ($null -ne $IndexEntry) { [string](Get-PropertyValue $IndexEntry 'thread_name' '') } else { '' }
    $updatedUtc = [string](Get-PropertyValue $Session 'UpdatedUtc' '')
    if ([string]::IsNullOrWhiteSpace($updatedUtc)) { $updatedUtc = $LocalFile.LastWriteTimeUtc.ToString('o') }
    [pscustomobject]@{
        SchemaVersion = 2
        ThreadId = $Session.Id
        ContentHash = $Session.Hash
        ContentLength = $Session.Length
        ObjectPath = $ObjectRelativePath.Replace('\','/')
        Archived = [bool]$LocalFile.Archived
        Title = $title
        SessionTimestamp = $Session.Timestamp
        ModelProvider = $Session.Provider
        Source = $Session.Source
        WorkingDirectory = [string]$Session.Cwd
        ProjectId = $ProjectId
        ProjectName = $ProjectName
        CodexProjectId = $CodexProjectId
        CodexProjectName = $CodexProjectName
        ProjectRootIndex = $ProjectRootIndex
        ProjectRootPath = $ProjectRootPath
        MachineId = $MachineId
        MachineName = $MachineName
        UpdatedUtc = $updatedUtc
        SourceFileName = [string]$LocalFile.Name
        SourceFileLength = [int64]$LocalFile.Length
        SourceLastWriteUtc = $LocalFile.LastWriteTimeUtc.ToString('o')
    }
}

function Get-ThreadIdFromRolloutName {
    param([Parameter(Mandatory)][string]$Name)
    $match = [regex]::Match($Name, '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$')
    if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }
    $null
}

function Get-HistorySourceKey {
    param([Parameter(Mandatory)][string]$Path)
    $normalized = [IO.Path]::GetFullPath($Path).ToLowerInvariant()
    Get-Sha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($normalized))
}

function Get-ThreadIdFromSessionHeader {
    param([Parameter(Mandatory)][string]$Path)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 65536, $true)
    try {
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        $first = $line | ConvertFrom-Json
        if ([string](Get-PropertyValue $first 'type' '') -ne 'session_meta') { return $null }
        $id = [string](Get-PropertyValue (Get-PropertyValue $first 'payload') 'id' '')
        $parsed = [guid]::Empty
        if ([guid]::TryParse($id, [ref]$parsed)) { return $id.ToLowerInvariant() }
        $null
    }
    catch { $null }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Get-WorkingDirectoryFromSessionHeader {
    param([Parameter(Mandatory)][string]$Path)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 65536, $true)
    try {
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) { return $null }
        $first = $line | ConvertFrom-Json
        if ([string](Get-PropertyValue $first 'type' '') -ne 'session_meta') { return $null }
        [string](Get-PropertyValue (Get-PropertyValue $first 'payload') 'cwd' '')
    }
    catch { $null }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Export-LocalSessions {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$VaultRoot, [Parameter(Mandatory)][string]$CodexHome, [switch]$ChangedOnly)
    $index = Get-SessionIndexMap -CodexHome $CodexHome
    $codexProjects = @(Get-CodexLocalProjectCatalog -CodexHome $CodexHome)
    $threadProjectMap = Get-CodexThreadProjectMap -CodexHome $CodexHome
    $localMap = @{}
    $exported = 0
    $skipped = 0
    $unchanged = 0
    $selected = 0
    foreach ($localFile in Get-LocalSessions -CodexHome $CodexHome) {
        if ($localFile.Archived -and -not [bool](Get-PropertyValue $Config 'SyncArchived' $false)) { continue }
        $workingDirectory = Get-WorkingDirectoryFromSessionHeader -Path $localFile.Path
        $sessionProject = Get-CodexSessionProjectInfo -CodexHome $CodexHome -ThreadId (Get-ThreadIdFromSessionHeader -Path $localFile.Path) -WorkingDirectory $workingDirectory -Projects $codexProjects -ThreadProjectMap $threadProjectMap
        $binding = if ($null -ne $sessionProject -and -not [bool](Get-PropertyValue $sessionProject 'Ambiguous' $false)) { Get-HistoryProjectBindingForCodexId -Config $Config -CodexProjectId ([string](Get-PropertyValue $sessionProject 'CodexProjectId' '')) } else { $null }
        if ($null -eq $binding -and $null -ne $sessionProject -and -not [bool](Get-PropertyValue $sessionProject 'Ambiguous' $false)) {
            $matchedProject = @($codexProjects | Where-Object { ([string](Get-PropertyValue $_ 'CodexProjectId' '')).Equals([string](Get-PropertyValue $sessionProject 'CodexProjectId' ''), [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
            $binding = Get-HistoryLegacyBindingForCodexProject -Config $Config -CodexProject $matchedProject -AllCodexProjects $codexProjects
        }
        if ($null -eq $binding -and $null -eq $sessionProject) { $binding = Get-HistoryProjectBindingForPath -Config $Config -WorkingDirectory $workingDirectory }
        if ($null -eq $binding) { continue }
        $selected++
        $projectId = [string](Get-PropertyValue $binding 'ProjectId' '')
        $projectName = [string](Get-PropertyValue $binding 'ProjectName' '')
        $codexProjectId = if ($null -ne $sessionProject) { [string](Get-PropertyValue $sessionProject 'CodexProjectId' '') } else { [string](Get-PropertyValue $binding 'CodexProjectId' '') }
        $codexProjectName = if ($null -ne $sessionProject) { [string](Get-PropertyValue $sessionProject 'CodexProjectName' '') } else { [string](Get-PropertyValue $binding 'CodexProjectName' '') }
        $projectRootIndex = if ($null -ne $sessionProject) { [int](Get-PropertyValue $sessionProject 'RootIndex' 0) } else { 0 }
        $projectRootPath = if ($null -ne $sessionProject) { [string](Get-PropertyValue $sessionProject 'RootPath' '') } else { Get-HistoryBindingRootAtIndex -Binding $binding -Index $projectRootIndex }
        if ([bool](Get-PropertyValue $localFile 'Imported' $false)) {
            $marker = Read-ImportedSessionMarker -SessionPath $localFile.Path
            $markerLength = [int64](Get-PropertyValue $marker 'TargetLength' -1)
            $markerWrite = ConvertTo-HistoryUtcText (Get-PropertyValue $marker 'TargetLastWriteUtc' '')
            $currentWrite = $localFile.LastWriteTimeUtc.ToString('o')
            if ($null -ne $marker -and $markerLength -eq [int64]$localFile.Length -and $markerWrite -eq $currentWrite) {
                $markerId = [string](Get-PropertyValue $marker 'ThreadId' '')
                $markerHash = [string](Get-PropertyValue $marker 'ContentHash' '')
                $markerObject = [string](Get-PropertyValue $marker 'ObjectPath' '')
                if (-not [string]::IsNullOrWhiteSpace($markerId) -and -not [string]::IsNullOrWhiteSpace($markerHash) -and -not [string]::IsNullOrWhiteSpace($markerObject)) {
                    $markerObjectPath = Join-Path $VaultRoot ($markerObject.Replace('/','\'))
                    if ((Test-Path -LiteralPath $markerObjectPath -PathType Leaf) -and (Get-FileSha256Hex -Path $markerObjectPath) -eq $markerHash) {
                        if (-not $ChangedOnly) {
                            $currentMarkerLocal = if ($localMap.ContainsKey($markerId)) { $localMap[$markerId] } else { $null }
                            # Prefer a real local rollout over a synced materialized view
                            # when both contain the same thread. The view is only a fallback
                            # for machines that have not opened the thread locally yet.
                            if ($null -eq $currentMarkerLocal -or [bool](Get-PropertyValue $currentMarkerLocal 'Imported' $false)) {
                                $localMap[$markerId] = [pscustomobject]@{
                                    Id=$markerId; Path=$localFile.Path; Imported=$true; Archived=$localFile.Archived; Hash=$markerHash
                                    Length=[int64](Get-PropertyValue $marker 'ContentLength' ([int64](Get-Item -LiteralPath $markerObjectPath).Length)); Timestamp=''; CanonicalBytes=$null; CanonicalPath=$markerObjectPath; ProjectId=$projectId
                                }
                            }
                        }
                        $unchanged++
                        continue
                    }
                }
            }
            # The imported view changed (normally because the user continued the
            # session). Remove the marker and adopt it as a local source below.
            $staleMarker = Get-ImportedSessionMarkerPath -SessionPath $localFile.Path
            if (Test-Path -LiteralPath $staleMarker -PathType Leaf) { Remove-Item -LiteralPath $staleMarker -Force -ErrorAction SilentlyContinue }
        }
        $session = $null
        try {
            $sourceKey = Get-HistorySourceKey -Path $localFile.Path
            $sourceRefPath = Join-Path $VaultRoot ('refs\' + $Config.MachineId + '\sources\' + $sourceKey + '.json')
            $existingRef = Read-JsonFile -Path $sourceRefPath
            if ($null -eq $existingRef) {
                $idHint = Get-ThreadIdFromSessionHeader -Path $localFile.Path
                if (-not [string]::IsNullOrWhiteSpace($idHint)) {
                    $legacyRefPath = Join-Path $VaultRoot ('refs\' + $Config.MachineId + '\' + $idHint + '.json')
                    $legacyRef = Read-JsonFile -Path $legacyRefPath
                    $legacyLengthMatches = [int64](Get-PropertyValue $legacyRef 'SourceFileLength' -1) -eq [int64]$localFile.Length
                    $legacyWriteMatches = (ConvertTo-HistoryUtcText (Get-PropertyValue $legacyRef 'SourceLastWriteUtc' '')) -eq $localFile.LastWriteTimeUtc.ToString('o')
                    if ($legacyLengthMatches -and $legacyWriteMatches) {
                        Write-AtomicJson -Path $sourceRefPath -Value $legacyRef
                        $existingRef = $legacyRef
                    }
                }
            }
            if ($null -ne $existingRef) {
                $sameLength = [int64](Get-PropertyValue $existingRef 'SourceFileLength' -1) -eq [int64]$localFile.Length
                $sameWrite = (ConvertTo-HistoryUtcText (Get-PropertyValue $existingRef 'SourceLastWriteUtc' '')) -eq $localFile.LastWriteTimeUtc.ToString('o')
                $sameArchive = [bool](Get-PropertyValue $existingRef 'Archived' (-not $localFile.Archived)) -eq [bool]$localFile.Archived
                $sameProject = [string](Get-PropertyValue $existingRef 'ProjectId' '') -eq $projectId
                $sameCodexProject = [string](Get-PropertyValue $existingRef 'CodexProjectId' '') -eq $codexProjectId
                    $existingObject = Resolve-HistoryVaultRelativePath -VaultRoot $VaultRoot -RelativePath ([string](Get-PropertyValue $existingRef 'ObjectPath' ''))
                if ($sameLength -and $sameWrite -and $sameArchive -and $sameProject -and $sameCodexProject -and -not [string]::IsNullOrWhiteSpace($existingObject) -and (Test-Path -LiteralPath $existingObject -PathType Leaf)) {
                    $metadataChanged = $false
                    $latestTimestamp = Get-LatestSessionTimestamp -Path $localFile.Path
                    if (-not [string]::IsNullOrWhiteSpace($latestTimestamp) -and (ConvertTo-HistoryUtcText (Get-PropertyValue $existingRef 'UpdatedUtc' '')) -ne (ConvertTo-HistoryUtcText $latestTimestamp)) {
                        $existingRef.UpdatedUtc = $latestTimestamp
                        $metadataChanged = $true
                    }
                    if ($null -eq $existingRef.PSObject.Properties['SourceFileName']) {
                        $existingRef | Add-Member -NotePropertyName SourceFileName -NotePropertyValue ([string]$localFile.Name)
                        $metadataChanged = $true
                    }
                    if ($null -eq $existingRef.PSObject.Properties['WorkingDirectory']) {
                        $existingRef | Add-Member -NotePropertyName WorkingDirectory -NotePropertyValue $workingDirectory
                        $metadataChanged = $true
                    }
                    if ($metadataChanged) { Write-AtomicJson -Path $sourceRefPath -Value $existingRef }
                    $unchanged++
                    if (-not $ChangedOnly) {
                        $existingId = [string](Get-PropertyValue $existingRef 'ThreadId' '')
                        $existingLength = [int64](Get-PropertyValue $existingRef 'ContentLength' $localFile.Length)
                        $current = if ($localMap.ContainsKey($existingId)) { $localMap[$existingId] } else { $null }
                        if (-not [string]::IsNullOrWhiteSpace($existingId) -and ($null -eq $current -or $existingLength -gt [int64]$current.Length)) {
                            $localMap[$existingId] = [pscustomobject]@{
                                Id=$existingId; Path=$localFile.Path; Archived=$localFile.Archived; Hash=[string](Get-PropertyValue $existingRef 'ContentHash' '')
                                Length=$existingLength; Timestamp=[string](Get-PropertyValue $existingRef 'SessionTimestamp' ''); CanonicalBytes=$null; CanonicalPath=$existingObject; ProjectId=$projectId
                            }
                        }
                    }
                    continue
                }
            }
            $knownRoots = @((Get-PropertyValue $Config 'KnownVolumeRoots' @()) | ForEach-Object { [string]$_ })
            $session = ConvertTo-CanonicalSessionFile -Path $localFile.Path -VaultId $Config.VaultId -VaultRoot $VaultRoot -KnownVolumeRoots $knownRoots -ProjectId $projectId -ProjectRootPath $projectRootPath -ProjectRootIndex $projectRootIndex
            $objectRelative = 'objects\' + $session.Id + '\' + $session.Hash + '.jsonl'
            $objectPath = Join-Path $VaultRoot $objectRelative
            if (Test-Path -LiteralPath $objectPath -PathType Leaf) {
                if ((Get-FileSha256Hex -Path $objectPath) -ne $session.Hash) { throw "历史对象校验失败：$objectPath" }
                if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $session 'TemporaryPath' ''))) { Remove-Item -LiteralPath $session.TemporaryPath -Force -ErrorAction SilentlyContinue }
            }
            else {
                if (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $session 'TemporaryPath' ''))) {
                    $objectDirectory = Split-Path -Parent $objectPath
                    if (-not (Test-Path -LiteralPath $objectDirectory -PathType Container)) { New-Item -ItemType Directory -Path $objectDirectory -Force | Out-Null }
                    Move-Item -LiteralPath $session.TemporaryPath -Destination $objectPath
                }
                else { Write-AtomicBytes -Path $objectPath -Bytes $session.Bytes }
                $exported++
            }
            $entry = if ($index.ContainsKey($session.Id)) { $index[$session.Id] } else { $null }
            $ref = New-HistoryRef -Session $session -LocalFile $localFile -IndexEntry $entry -MachineId $Config.MachineId -MachineName $Config.MachineName -ObjectRelativePath $objectRelative -ProjectId $projectId -ProjectName $projectName -CodexProjectId $codexProjectId -CodexProjectName $codexProjectName -ProjectRootIndex $projectRootIndex -ProjectRootPath $projectRootPath
            Write-AtomicJson -Path $sourceRefPath -Value $ref
            $current = if ($localMap.ContainsKey($session.Id)) { $localMap[$session.Id] } else { $null }
            if ($null -eq $current -or [int64]$session.Length -gt [int64]$current.Length) {
                $localMap[$session.Id] = [pscustomobject]@{
                    Id=$session.Id; Path=$localFile.Path; Archived=$localFile.Archived; Hash=$session.Hash
                    Length=$session.Length; Timestamp=$session.Timestamp; CanonicalBytes=$null; CanonicalPath=$objectPath; ProjectId=$projectId
                }
            }
        }
        catch {
            if ($null -ne $session -and -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $session 'TemporaryPath' '')) -and (Test-Path -LiteralPath $session.TemporaryPath -PathType Leaf)) {
                Remove-Item -LiteralPath $session.TemporaryPath -Force -ErrorAction SilentlyContinue
            }
            $skipped++
            Write-HistorySyncLog -Level WARN -Message "跳过会话 $($localFile.Path)：$($_.Exception.Message)"
        }
    }
    [pscustomobject]@{ LocalMap=$localMap; Exported=$exported; Skipped=$skipped; Unchanged=$unchanged; Selected=$selected; IndexMap=$index }
}

function Get-AllHistoryRefs {
    param([Parameter(Mandatory)][string]$VaultRoot)
    $refs = New-Object Collections.Generic.List[object]
    $root = Join-Path $VaultRoot 'refs'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $refs }
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue) {
        try {
            $ref = Read-JsonFile -Path $file.FullName
            if ([int](Get-PropertyValue $ref 'SchemaVersion' 0) -ge 1 -and -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $ref 'ThreadId' ''))) {
                $refs.Add($ref)
            }
        }
        catch { Write-HistorySyncLog -Level WARN -Message "忽略损坏的引用 $($file.FullName)：$($_.Exception.Message)" }
    }
    $refs
}

function Test-HistoryRefSelected {
    param($Config, $Ref)
    $projectId = [string](Get-PropertyValue $Ref 'ProjectId' '')
    if ([string]::IsNullOrWhiteSpace($projectId)) { return $false }
    $null -ne (Get-HistoryProjectBindingById -Config $Config -ProjectId $projectId)
}

function Get-HistoryProjectCatalog {
    $config = Read-JsonFile -Path (Get-HistorySyncConfigPath)
    if ($null -eq $config) { throw '请先选择历史仓库。' }
    $vaultRoot = Resolve-HistoryVault -Config $config
    if ([string]::IsNullOrWhiteSpace($vaultRoot)) { throw '历史仓库当前未连接。' }
    $codexHome = Get-HistorySyncCodexHome
    $projects = @(Get-AllHistoryProjects -VaultRoot $vaultRoot)
    $projectMap = @{}
    foreach ($project in $projects) { $projectMap[[string](Get-PropertyValue $project 'ProjectId' '')] = $project }
    $bindings = @(Get-HistoryAllProjectBindings -Config $config)
    $codexProjects = @(Get-CodexLocalProjectCatalog -CodexHome $codexHome)
    $threadProjectMap = Get-CodexThreadProjectMap -CodexHome $codexHome

    # Build the local list from Codex's projects.  Each row represents one
    # Codex project and can contain several root paths; cwd is only used to
    # count sessions that lack a thread assignment (legacy data).
    $localProjectStats = @{}
    foreach ($project in $codexProjects) {
        $localProjectStats[[string]$project.CodexProjectId] = [pscustomobject]@{ Active=0; Archived=0; Unassigned=0 }
    }
    $legacyDirectories = @{}
    foreach ($localFile in Get-LocalSessions -CodexHome $codexHome) {
        $threadId = Get-ThreadIdFromSessionHeader -Path $localFile.Path
        $cwd = Get-WorkingDirectoryFromSessionHeader -Path $localFile.Path
        $info = Get-CodexSessionProjectInfo -CodexHome $codexHome -ThreadId $threadId -WorkingDirectory $cwd -Projects $codexProjects -ThreadProjectMap $threadProjectMap
        if ($null -ne $info -and -not [bool](Get-PropertyValue $info 'Ambiguous' $false) -and $localProjectStats.ContainsKey([string]$info.CodexProjectId)) {
            if ($localFile.Archived) { $localProjectStats[[string]$info.CodexProjectId].Archived++ } else { $localProjectStats[[string]$info.CodexProjectId].Active++ }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($cwd)) {
            try {
                $normalized = Normalize-HistoryDirectoryPath -Path $cwd; $key=$normalized.ToLowerInvariant()
                if (-not $legacyDirectories.ContainsKey($key)) { $legacyDirectories[$key]=[pscustomobject]@{Path=$normalized;Active=0;Archived=0} }
                if ($localFile.Archived) { $legacyDirectories[$key].Archived++ } else { $legacyDirectories[$key].Active++ }
            } catch {}
        }
    }

    $localDirectories = New-Object Collections.Generic.List[object]
    foreach ($project in $codexProjects | Sort-Object Name) {
        $localId=[string]$project.CodexProjectId; $stat=$localProjectStats[$localId]
        $binding=Get-HistoryProjectBindingForCodexId -Config $config -CodexProjectId $localId
        if ($null -eq $binding) { $binding = Get-HistoryLegacyBindingForCodexProject -Config $config -CodexProject $project -AllCodexProjects $codexProjects }
        $logicalId=if($null -ne $binding){[string](Get-PropertyValue $binding 'ProjectId' '')}else{''}
        $logicalName=if($null -ne $binding){[string](Get-PropertyValue $binding 'ProjectName' '')}else{''}
        $firstRoot=if(@($project.RootPaths).Count -gt 0){[string]@($project.RootPaths)[0]}else{''}
        $localDirectories.Add([pscustomobject]@{ Path=$firstRoot; CodexProjectId=$localId; CodexProjectName=[string]$project.Name; RootPaths=@($project.RootPaths); ActiveSessionCount=[int]$stat.Active; ArchivedSessionCount=[int]$stat.Archived; TotalSessionCount=([int]$stat.Active+[int]$stat.Archived); Selected=($null -ne $binding); ProjectId=$logicalId; ProjectName=$logicalName; MatchMode='codex-project' })
    }
    # Preserve visibility of old installations that have no global state yet.
    foreach ($local in $legacyDirectories.Values | Sort-Object Path) {
        $binding=Get-HistoryProjectBindingForPath -Config $config -WorkingDirectory $local.Path
        if ($null -ne $binding -and $codexProjects.Count -gt 0) { continue }
        $id=if($null -ne $binding){[string](Get-PropertyValue $binding 'ProjectId' '')}else{''}; $name=if($null -ne $binding){[string](Get-PropertyValue $binding 'ProjectName' '')}else{''}
        $localDirectories.Add([pscustomobject]@{ Path=$local.Path; CodexProjectId=''; CodexProjectName=''; RootPaths=@($local.Path); ActiveSessionCount=[int]$local.Active; ArchivedSessionCount=[int]$local.Archived; TotalSessionCount=([int]$local.Active+[int]$local.Archived); Selected=($null -ne $binding); ProjectId=$id; ProjectName=$name; MatchMode='cwd-legacy' })
    }

    $allRefs = @(Get-AllHistoryRefs -VaultRoot $vaultRoot)
    $projectEntries = New-Object Collections.Generic.List[object]
    foreach ($project in $projects | Sort-Object {[string](Get-PropertyValue $_ 'Name' '')}) {
        $id = [string](Get-PropertyValue $project 'ProjectId' '')
        $refs = @($allRefs | Where-Object { [string](Get-PropertyValue $_ 'ProjectId' '') -eq $id })
        $binding = Get-HistoryProjectBindingById -Config $config -ProjectId $id
        $machines = @($refs | ForEach-Object { [string](Get-PropertyValue $_ 'MachineName' '') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $directories = @($refs | ForEach-Object { [string](Get-PropertyValue $_ 'WorkingDirectory' '') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $updated = @($refs | ForEach-Object { [string](Get-PropertyValue $_ 'UpdatedUtc' '') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Descending | Select-Object -First 1)
        $memberNames=@((Get-PropertyValue $project 'CodexProjectMembers' @()) | ForEach-Object { [string](Get-PropertyValue $_ 'Name' '') } | Where-Object { $_ } | Select-Object -Unique)
        $memberIds=@((Get-PropertyValue $project 'CodexProjectMembers' @()) | ForEach-Object { [string](Get-PropertyValue $_ 'CodexProjectId' '') } | Where-Object { $_ } | Select-Object -Unique)
        $localRootPaths = @()
        if ($null -ne $binding) { $localRootPaths = @(Get-HistoryBindingRootPaths -Binding $binding) }
        $projectEntries.Add([pscustomobject]@{
            ProjectId=$id; Name=[string](Get-PropertyValue $project 'Name' ('同步项目 ' + $id.Substring(0,8)))
            Bound=($null -ne $binding); LocalPath=$(if($localRootPaths.Count -gt 0){[string]$localRootPaths[0]}else{''}); LocalRootPaths=$localRootPaths
            CodexProjectId=$(if($null -ne $binding){[string](Get-PropertyValue $binding 'CodexProjectId' '')}else{''}); CodexProjectIds=($memberIds -join '、'); CodexProjectNames=($memberNames -join '、')
            SessionCount=@($refs | Select-Object -ExpandProperty ThreadId -Unique).Count
            MachineNames=($machines -join '、'); SourceDirectories=($directories -join '；')
            UpdatedUtc=$(if($updated.Count -gt 0){$updated[0]}else{[string](Get-PropertyValue $project 'CreatedUtc' '')})
        })
    }
    [pscustomobject]@{
        Success=$true; Message='已读取同步项目。'; VaultPath=$vaultRoot
        BoundProjectCount=@($bindings | Select-Object -ExpandProperty ProjectId -Unique).Count; LocalDirectoryCount=$localDirectories.Count; CodexProjectCount=$codexProjects.Count; ProjectCount=$projectEntries.Count
        LocalDirectories=@($localDirectories | ForEach-Object { $_ }); LocalProjects=@($localDirectories | ForEach-Object { $_ }); Projects=@($projectEntries | ForEach-Object { $_ })
    }
}

function Add-HistoryProjectBinding {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$VaultRoot, [Parameter(Mandatory)][string]$ProjectId, [Parameter(Mandatory)][string]$ProjectName, [Parameter(Mandatory)][string]$LocalPath)
    $normalized = Normalize-HistoryDirectoryPath -Path $LocalPath
    $bindings = New-Object Collections.Generic.List[object]
    $knownPaths = @($normalized)
    foreach ($binding in Get-HistoryProjectBindings -Config $Config) {
        $existingId = [string](Get-PropertyValue $binding 'ProjectId' '')
        $existingPath = Normalize-HistoryDirectoryPath -Path ([string](Get-PropertyValue $binding 'LocalPath' ''))
        if ($existingPath.Equals($normalized, [StringComparison]::OrdinalIgnoreCase) -and -not $existingId.Equals($ProjectId, [StringComparison]::OrdinalIgnoreCase)) {
            throw "本机目录已绑定到另一个同步项目：$normalized"
        }
        if (-not $existingId.Equals($ProjectId, [StringComparison]::OrdinalIgnoreCase)) { $bindings.Add($binding) }
        else {
            $knownPaths += @($existingPath)
            $knownPaths += @((Get-PropertyValue $binding 'KnownLocalPaths' @()) | ForEach-Object { [string]$_ })
        }
    }
    $vaultVolumeRoot = [IO.Path]::GetPathRoot($VaultRoot)
    $relativeToVolume = if ([IO.Path]::GetPathRoot($normalized).Equals($vaultVolumeRoot, [StringComparison]::OrdinalIgnoreCase)) { Get-RelativePathFromRoot -Root $vaultVolumeRoot -Path $normalized } else { $null }
    $bindings.Add([pscustomobject]@{
        ProjectId=$ProjectId; ProjectName=$ProjectName; LocalPath=$normalized; KnownLocalPaths=@($knownPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        PathRelativeToVolume=$relativeToVolume; BoundUtc=[DateTime]::UtcNow.ToString('o')
    })
    Save-HistoryProjectBindings -Config $Config -Bindings @($bindings | ForEach-Object { $_ })
}

function Add-HistoryCodexProjectBinding {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$VaultRoot,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)]$CodexProject,
        [string]$CodexProjectId
    )
    $localId = if ([string]::IsNullOrWhiteSpace($CodexProjectId)) { [string](Get-PropertyValue $CodexProject 'CodexProjectId' '') } else { $CodexProjectId }
    if ([string]::IsNullOrWhiteSpace($localId)) { throw 'Codex 项目 ID 不能为空。' }
    $roots = New-Object Collections.Generic.List[object]
    $vaultVolumeRoot = [IO.Path]::GetPathRoot($VaultRoot)
    foreach ($rootPath in @((Get-PropertyValue $CodexProject 'RootPaths' @()))) {
        try {
            $normalized = Normalize-HistoryDirectoryPath -Path ([string]$rootPath)
            $relative = if ([IO.Path]::GetPathRoot($normalized).Equals($vaultVolumeRoot, [StringComparison]::OrdinalIgnoreCase)) { Get-RelativePathFromRoot -Root $vaultVolumeRoot -Path $normalized } else { $null }
            $roots.Add([pscustomobject]@{ LocalPath=$normalized; KnownLocalPaths=@($normalized); PathRelativeToVolume=$relative })
        }
        catch {}
    }
    if ($roots.Count -eq 0) { throw "Codex 项目没有有效的根目录：$localId" }
    $bindings = New-Object Collections.Generic.List[object]
    $existingBindings = @(Get-HistoryCodexProjectBindings -Config $Config)
    foreach ($binding in $existingBindings) {
        $existingId = [string](Get-PropertyValue $binding 'ProjectId' '')
        $existingCodexId = [string](Get-PropertyValue $binding 'CodexProjectId' '')
        if ($existingCodexId.Equals($localId, [StringComparison]::OrdinalIgnoreCase) -and -not $existingId.Equals($ProjectId, [StringComparison]::OrdinalIgnoreCase)) {
            throw "本机 Codex 项目已绑定到另一个同步项目：$localId"
        }
        if (-not ($existingId.Equals($ProjectId, [StringComparison]::OrdinalIgnoreCase) -and $existingCodexId.Equals($localId, [StringComparison]::OrdinalIgnoreCase))) { $bindings.Add($binding) }
    }
    $bindings.Add([pscustomobject]@{
        SchemaVersion=1; ProjectId=$ProjectId; ProjectName=$ProjectName; CodexProjectId=$localId; MachineId=[string]$Config.MachineId; MachineName=[string]$Config.MachineName
        CodexProjectName=[string](Get-PropertyValue $CodexProject 'Name' $ProjectName)
        RootPaths=@($roots.ToArray()); LocalPath=[string]$roots[0].LocalPath; BoundUtc=[DateTime]::UtcNow.ToString('o')
    })
    Save-HistoryCodexProjectBindings -Config $Config -Bindings @($bindings | ForEach-Object { $_ })

    # Keep a member record in the vault so another machine can see the Codex
    # project identity and its roots before binding its own local project.
    $projectPath = Get-HistoryProjectPath -VaultRoot $VaultRoot -ProjectId $ProjectId
    $project = Read-JsonFile -Path $projectPath
    if ($null -eq $project) { throw '共享仓库中不存在该同步项目。' }
    $members = New-Object Collections.Generic.List[object]
    foreach ($member in @((Get-PropertyValue $project 'CodexProjectMembers' @()))) {
        if (-not ([string](Get-PropertyValue $member 'CodexProjectId' '')).Equals($localId,[StringComparison]::OrdinalIgnoreCase)) { $members.Add($member) }
    }
    $members.Add([pscustomobject]@{ MachineId=[string]$Config.MachineId; MachineName=[string]$Config.MachineName; CodexProjectId=$localId; Name=[string](Get-PropertyValue $CodexProject 'Name' $ProjectName); RootPaths=@($roots | ForEach-Object { $_.LocalPath }); BoundUtc=[DateTime]::UtcNow.ToString('o') })
    $memberArray = @($members.ToArray())
    if ($project.PSObject.Properties['CodexProjectMembers']) { $project.CodexProjectMembers=$memberArray } else { $project | Add-Member -NotePropertyName CodexProjectMembers -NotePropertyValue $memberArray }
    if ($project.PSObject.Properties['SchemaVersion']) { $project.SchemaVersion=2 }
    Write-AtomicJson -Path $projectPath -Value $project
}

function Get-HistoryProjectBindingForCodexId {
    param($Config, [string]$CodexProjectId)
    if ([string]::IsNullOrWhiteSpace($CodexProjectId)) { return $null }
    $binding = @(Get-HistoryCodexProjectBindingByCodexId -Config $Config -CodexProjectId $CodexProjectId | Select-Object -First 1)
    if ($binding.Count -gt 0) { return $binding[0] }
    $null
}

function New-HistoryProject {
    param([string]$LocalPath, [string]$Name, [string]$CodexProjectId)
    $config = Read-JsonFile -Path (Get-HistorySyncConfigPath)
    if ($null -eq $config) { throw '请先选择历史仓库。' }
    $vaultRoot = Resolve-HistoryVault -Config $config
    if ([string]::IsNullOrWhiteSpace($vaultRoot)) { throw '历史仓库当前未连接。' }
    if (-not [string]::IsNullOrWhiteSpace($CodexProjectId)) {
        $codexProjects = @(Get-CodexLocalProjectCatalog -CodexHome (Get-HistorySyncCodexHome))
        $codexProject = @($codexProjects | Where-Object { ([string](Get-PropertyValue $_ 'CodexProjectId' '')).Equals($CodexProjectId,[StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
        if ($null -eq $codexProject) { throw "找不到本机 Codex 项目：$CodexProjectId" }
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name=[string](Get-PropertyValue $codexProject 'Name' $CodexProjectId) }
        $Name=$Name.Trim(); if ($Name.Length -gt 120) { $Name=$Name.Substring(0,120) }
        $projectId=[guid]::NewGuid().ToString()
        $lock=Enter-HistoryVaultLock -VaultRoot $vaultRoot
        try {
            Write-AtomicJson -Path (Get-HistoryProjectPath -VaultRoot $vaultRoot -ProjectId $projectId) -Value ([pscustomobject]@{ SchemaVersion=2; ProjectId=$projectId; Name=$Name; CreatedUtc=[DateTime]::UtcNow.ToString('o'); CreatedByMachineId=[string]$config.MachineId; CreatedByMachineName=[string]$config.MachineName; CodexProjectMembers=@() })
            Add-HistoryCodexProjectBinding -Config $config -VaultRoot $vaultRoot -ProjectId $projectId -ProjectName $Name -CodexProject $codexProject -CodexProjectId $CodexProjectId
        }
        finally { $lock.Dispose() }
        return Get-HistoryProjectCatalog
    }
    if ([string]::IsNullOrWhiteSpace($LocalPath)) { throw '必须提供本机工作目录或 Codex 项目 ID。' }
    $normalized = Normalize-HistoryDirectoryPath -Path $LocalPath
    $existing = Get-HistoryProjectBindingForPath -Config $config -WorkingDirectory $normalized
    if ($null -ne $existing) { throw "该目录已经加入同步：$normalized" }
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = [IO.Path]::GetFileName($normalized) }
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $normalized }
    $Name = $Name.Trim()
    if ($Name.Length -gt 120) { $Name = $Name.Substring(0,120) }
    $projectId = [guid]::NewGuid().ToString()
    $lock = Enter-HistoryVaultLock -VaultRoot $vaultRoot
    try {
        $projectPath = Get-HistoryProjectPath -VaultRoot $vaultRoot -ProjectId $projectId
        Write-AtomicJson -Path $projectPath -Value ([pscustomobject]@{
            SchemaVersion=1; ProjectId=$projectId; Name=$Name; CreatedUtc=[DateTime]::UtcNow.ToString('o')
            CreatedByMachineId=[string]$config.MachineId; CreatedByMachineName=[string]$config.MachineName
        })
        Add-HistoryProjectBinding -Config $config -VaultRoot $vaultRoot -ProjectId $projectId -ProjectName $Name -LocalPath $normalized
    }
    finally { $lock.Dispose() }
    Get-HistoryProjectCatalog
}

function Set-HistoryProjectBinding {
    param([Parameter(Mandatory)][string]$ProjectId, [string]$LocalPath, [string]$CodexProjectId)
    $parsedProjectId = [guid]::Empty
    if (-not [guid]::TryParse($ProjectId, [ref]$parsedProjectId)) { throw '同步项目 ID 无效。' }
    $ProjectId = $parsedProjectId.ToString()
    $config = Read-JsonFile -Path (Get-HistorySyncConfigPath)
    if ($null -eq $config) { throw '请先选择历史仓库。' }
    $vaultRoot = Resolve-HistoryVault -Config $config
    if ([string]::IsNullOrWhiteSpace($vaultRoot)) { throw '历史仓库当前未连接。' }
    $project = Read-JsonFile -Path (Get-HistoryProjectPath -VaultRoot $vaultRoot -ProjectId $ProjectId)
    if ($null -eq $project) { throw '共享仓库中不存在该同步项目。' }
    $name = [string](Get-PropertyValue $project 'Name' ('同步项目 ' + $ProjectId.Substring(0,8)))
    if (-not [string]::IsNullOrWhiteSpace($CodexProjectId)) {
        $codexProjects = @(Get-CodexLocalProjectCatalog -CodexHome (Get-HistorySyncCodexHome))
        $codexProject = @($codexProjects | Where-Object { ([string](Get-PropertyValue $_ 'CodexProjectId' '')).Equals($CodexProjectId,[StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
        if ($null -eq $codexProject) { throw "找不到本机 Codex 项目：$CodexProjectId" }
        $lock = Enter-HistoryVaultLock -VaultRoot $vaultRoot
        try { Add-HistoryCodexProjectBinding -Config $config -VaultRoot $vaultRoot -ProjectId $ProjectId -ProjectName $name -CodexProject $codexProject -CodexProjectId $CodexProjectId }
        finally { $lock.Dispose() }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($LocalPath)) { throw '必须提供本机工作目录或 Codex 项目 ID。' }
        Add-HistoryProjectBinding -Config $config -VaultRoot $vaultRoot -ProjectId $ProjectId -ProjectName $name -LocalPath $LocalPath
    }
    Get-HistoryProjectCatalog
}

function Remove-HistoryProjectBinding {
    param([Parameter(Mandatory)][string]$ProjectId)
    $parsedProjectId = [guid]::Empty
    if (-not [guid]::TryParse($ProjectId, [ref]$parsedProjectId)) { throw '同步项目 ID 无效。' }
    $ProjectId = $parsedProjectId.ToString()
    $config = Read-JsonFile -Path (Get-HistorySyncConfigPath)
    if ($null -eq $config) { throw '请先选择历史仓库。' }
    $remaining = @(Get-HistoryProjectBindings -Config $config | Where-Object { -not ([string](Get-PropertyValue $_ 'ProjectId' '')).Equals($ProjectId, [StringComparison]::OrdinalIgnoreCase) })
    $remainingModern = @(Get-HistoryCodexProjectBindings -Config $config | Where-Object { -not ([string](Get-PropertyValue $_ 'ProjectId' '')).Equals($ProjectId, [StringComparison]::OrdinalIgnoreCase) })
    Save-HistoryProjectBindings -Config $config -Bindings $remaining
    Save-HistoryCodexProjectBindings -Config $config -Bindings $remainingModern
    Get-HistoryProjectCatalog
}

function Get-PendingExternalVersionCount {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$VaultRoot)
    $own = @{}
    $allRefs = @(Get-AllHistoryRefs -VaultRoot $VaultRoot)
    foreach ($ref in $allRefs | Where-Object { [string](Get-PropertyValue $_ 'MachineId' '') -eq [string]$Config.MachineId }) {
        $own[[string]$ref.ThreadId + '|' + [string]$ref.ContentHash] = $true
    }
    $pending = @{}
    foreach ($ref in $allRefs | Where-Object { [string](Get-PropertyValue $_ 'MachineId' '') -ne [string]$Config.MachineId }) {
        if ([bool](Get-PropertyValue $ref 'Archived' $false) -and -not [bool](Get-PropertyValue $Config 'SyncArchived' $false)) { continue }
        if (-not (Test-HistoryRefSelected -Config $Config -Ref $ref)) { continue }
        $threadId = [string](Get-PropertyValue $ref 'ThreadId' '')
        $hash = [string](Get-PropertyValue $ref 'ContentHash' '')
        if (-not $own.ContainsKey($threadId + '|' + $hash)) { $pending[$threadId + '|' + $hash] = $true }
    }
    $pending.Count
}

function Get-HistoryVaultList {
    $config = Read-JsonFile -Path (Get-HistorySyncConfigPath)
    if ($null -eq $config) { throw '尚未配置历史仓库。' }
    $vaultRoot = Resolve-HistoryVault -Config $config
    if ([string]::IsNullOrWhiteSpace($vaultRoot)) { throw '历史仓库当前未连接。' }
    $entries = New-Object Collections.Generic.List[object]
    $refs = @(Get-AllHistoryRefs -VaultRoot $vaultRoot)
    $projectNames = Get-HistoryProjectNameMap -VaultRoot $vaultRoot
    # A single Codex thread can have many paginated rollout files and therefore
    # many content hashes. Present one logical entry per project/thread and keep
    # the newest complete replica as the representative row.
    foreach ($group in $refs | Group-Object { [string](Get-PropertyValue $_ 'ProjectId' '') + '|' + [string]$_.ThreadId }) {
        $versions = @($group.Group | Sort-Object {[int64](Get-PropertyValue $_ 'ContentLength' 0)}, {[string](Get-PropertyValue $_ 'UpdatedUtc' '')} -Descending)
        if ($versions.Count -eq 0) { continue }
        $latest = $versions[0]
        $title = [string](Get-PropertyValue $latest 'Title' '')
        if ([string]::IsNullOrWhiteSpace($title)) { $title = '未命名会话 ' + ([string]$latest.ThreadId).Substring(0,8) }
        $machines = @($versions | ForEach-Object { [string](Get-PropertyValue $_ 'MachineName' '未知电脑') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $projectId = [string](Get-PropertyValue $latest 'ProjectId' '')
        $projectName = [string](Get-PropertyValue $latest 'ProjectName' '')
        if ([string]::IsNullOrWhiteSpace($projectName) -and $projectNames.ContainsKey($projectId)) { $projectName = [string]$projectNames[$projectId] }
        $binding = if ([string]::IsNullOrWhiteSpace($projectId)) { $null } else { Get-HistoryProjectBindingById -Config $config -ProjectId $projectId }
        $latestRootIndex = [int](Get-PropertyValue $latest 'ProjectRootIndex' 0)
        $localWorkingDirectory = if ($null -ne $binding) { Get-HistoryBindingRootAtIndex -Binding $binding -Index $latestRootIndex } else { '' }
        $entries.Add([pscustomobject]@{
            ThreadId = [string]$latest.ThreadId
            Title = $title
            UpdatedUtc = [string](Get-PropertyValue $latest 'UpdatedUtc' '')
            MachineNames = ($machines -join '、')
            Archived = [bool](Get-PropertyValue $latest 'Archived' $false)
            ModelProvider = [string](Get-PropertyValue $latest 'ModelProvider' '')
            WorkingDirectory = [string](Get-PropertyValue $latest 'WorkingDirectory' '')
            LocalWorkingDirectory = $localWorkingDirectory
            ProjectId = $projectId
            ProjectName = $projectName
            CodexProjectId = [string](Get-PropertyValue $latest 'CodexProjectId' '')
            CodexProjectName = [string](Get-PropertyValue $latest 'CodexProjectName' '')
            ProjectRootIndex = $latestRootIndex
            ProjectRootPath = [string](Get-PropertyValue $latest 'ProjectRootPath' '')
            ContentHash = [string](Get-PropertyValue $latest 'ContentHash' '')
            ContentLength = [int64](Get-PropertyValue $latest 'ContentLength' 0)
            IsConflict = $title.Contains('冲突副本')
            ReplicaCount = $versions.Count
        })
    }
    [pscustomobject]@{
        Success=$true; Message='已读取历史仓库。'; VaultPath=$vaultRoot
        EntryCount=$entries.Count; Entries=@($entries | Sort-Object UpdatedUtc -Descending)
    }
}

function Test-BytePrefix {
    param([Parameter(Mandatory)][byte[]]$Prefix, [Parameter(Mandatory)][byte[]]$Candidate)
    if ($Prefix.Length -gt $Candidate.Length) { return $false }
    for ($i = 0; $i -lt $Prefix.Length; $i++) { if ($Prefix[$i] -ne $Candidate[$i]) { return $false } }
    $true
}

function Test-FilePrefix {
    param([Parameter(Mandatory)][string]$PrefixPath, [Parameter(Mandatory)][string]$CandidatePath)
    $prefixInfo = Get-Item -LiteralPath $PrefixPath -ErrorAction Stop
    $candidateInfo = Get-Item -LiteralPath $CandidatePath -ErrorAction Stop
    if ($prefixInfo.Length -gt $candidateInfo.Length) { return $false }
    $prefix = New-Object IO.FileStream($PrefixPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $candidate = New-Object IO.FileStream($CandidatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $prefixBuffer = New-Object byte[] 1048576
        $candidateBuffer = New-Object byte[] 1048576
        $remaining = [int64]$prefixInfo.Length
        while ($remaining -gt 0) {
            $wanted = [int][Math]::Min([int64]$prefixBuffer.Length, $remaining)
            $prefixRead = $prefix.Read($prefixBuffer, 0, $wanted)
            $candidateRead = $candidate.Read($candidateBuffer, 0, $wanted)
            if ($prefixRead -ne $wanted -or $candidateRead -ne $wanted) { return $false }
            for ($index = 0; $index -lt $wanted; $index++) {
                if ($prefixBuffer[$index] -ne $candidateBuffer[$index]) { return $false }
            }
            $remaining -= $wanted
        }
        $true
    }
    finally { $candidate.Dispose(); $prefix.Dispose() }
}

function Write-MaterializedSessionFile {
    param(
        [Parameter(Mandatory)][string]$CanonicalPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$VaultId,
        [Parameter(Mandatory)][string]$VaultRoot,
        [string]$ProjectLocalPath,
        [string[]]$ProjectRootPaths,
        [int]$ProjectRootIndex = 0,
        [string]$ReplacementId
    )
    $directory = Split-Path -Parent $TargetPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = Join-Path $directory ('.writing-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $source = $null
    $destination = $null
    try {
        $source = New-Object IO.FileStream($CanonicalPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $firstBuffer = New-Object IO.MemoryStream
        try {
            while ($true) {
                $value = $source.ReadByte()
                if ($value -lt 0 -or $value -eq 10) { break }
                if ($value -ne 13) { $firstBuffer.WriteByte([byte]$value) }
            }
            $firstText = [Text.Encoding]::UTF8.GetString($firstBuffer.ToArray()).TrimStart([char]0xFEFF)
        }
        finally { $firstBuffer.Dispose() }
        if ([string]::IsNullOrWhiteSpace($firstText)) { throw "历史对象缺少会话首行：$CanonicalPath" }
        $first = $firstText | ConvertFrom-Json
        $payload = Get-PropertyValue $first 'payload'
        $cwd = [string](Get-PropertyValue $payload 'cwd' '')
        Set-HistoryMaterializedCwd -Payload $payload -CanonicalCwd $cwd -ProjectLocalPath $ProjectLocalPath -ProjectRootPaths $ProjectRootPaths -ProjectRootIndex $ProjectRootIndex -VaultId $VaultId -VaultRoot $VaultRoot
        if (-not [string]::IsNullOrWhiteSpace($ReplacementId)) {
            $payload.id = $ReplacementId
            if ($payload.PSObject.Properties['session_id']) { $payload.session_id = $ReplacementId }
        }

        $firstBytes = [Text.Encoding]::UTF8.GetBytes(($first | ConvertTo-Json -Depth 32 -Compress) + "`n")
        $destination = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $destination.Write($firstBytes, 0, $firstBytes.Length)
        $buffer = New-Object byte[] 1048576
        while (($read = $source.Read($buffer, 0, $buffer.Length)) -gt 0) { $destination.Write($buffer, 0, $read) }
        $destination.Flush($true)
        $destination.Dispose(); $destination = $null
        $source.Dispose(); $source = $null
        Move-Item -LiteralPath $temporary -Destination $TargetPath -Force
    }
    finally {
        if ($null -ne $destination) { $destination.Dispose() }
        if ($null -ne $source) { $source.Dispose() }
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function New-ConflictThreadId {
    param([Parameter(Mandatory)][string]$OriginalId, [Parameter(Mandatory)][string]$Hash)
    $seed = [Text.Encoding]::UTF8.GetBytes('codex-proxy-conflict-v1|' + $OriginalId + '|' + $Hash)
    $hex = Get-Sha256Hex -Bytes $seed
    $chars = $hex.Substring(0, 32).ToCharArray()
    $chars[12] = '5'
    $variant = [Convert]::ToInt32([string]$chars[16], 16)
    $chars[16] = ('89ab'[$variant % 4])
    $guidHex = -join $chars
    $guidHex.Substring(0,8) + '-' + $guidHex.Substring(8,4) + '-' + $guidHex.Substring(12,4) + '-' + $guidHex.Substring(16,4) + '-' + $guidHex.Substring(20,12)
}

function Test-HistoryPaginationRef {
    param($Ref, [string]$LocalPath)
    $sourceName = [string](Get-PropertyValue $Ref 'SourceFileName' '')
    if ($sourceName -match '(?i)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$') { return $true }
    if (-not [string]::IsNullOrWhiteSpace($LocalPath)) {
        $localName = [IO.Path]::GetFileName($LocalPath)
        if ($localName -match '(?i)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$') { return $true }
    }
    [string](Get-PropertyValue $Ref 'HistoryMode' '') -eq 'paginated'
}

function Get-ImportPath {
    param([string]$CodexHome, [string]$VaultId, [string]$ThreadId, [string]$Timestamp, [bool]$Archived)
    $date = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Timestamp, [ref]$date)) { $date = [DateTimeOffset]::UtcNow }
    $safeTime = $date.UtcDateTime.ToString('yyyy-MM-ddTHH-mm-ss')
    if ($Archived) {
        $directory = Join-Path $CodexHome ('archived_sessions\synced-' + $VaultId.Substring(0,8))
    }
    else {
        $directory = Join-Path $CodexHome ('sessions\synced-' + $VaultId.Substring(0,8) + '\' + $date.UtcDateTime.ToString('yyyy\\MM\\dd'))
    }
    Join-Path $directory ('rollout-' + $safeTime + '-' + $ThreadId + '.jsonl')
}

function Copy-HistoryBackup {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$CodexHome, [Parameter(Mandatory)][string]$BackupRoot)
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return }
    $relative = Get-RelativePathFromRoot -Root $CodexHome -Path $Source
    if ($null -eq $relative) { $relative = [IO.Path]::GetFileName($Source) }
    $destination = Join-Path $BackupRoot $relative
    $directory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $destination -Force
}

function Append-SessionIndexEntry {
    param([string]$CodexHome, [string]$ThreadId, [string]$Title, [string]$UpdatedUtc, [hashtable]$IndexMap, [string]$BackupRoot)
    if ([string]::IsNullOrWhiteSpace($Title)) { $Title = '已同步会话 ' + $ThreadId.Substring(0, 8) }
    $existing = if ($IndexMap.ContainsKey($ThreadId)) { [string](Get-PropertyValue $IndexMap[$ThreadId] 'thread_name' '') } else { '' }
    if ($existing -eq $Title) { return $false }
    $path = Join-Path $CodexHome 'session_index.jsonl'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $backupPath = Join-Path $BackupRoot 'session_index.jsonl'
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { Copy-HistoryBackup -Source $path -CodexHome $CodexHome -BackupRoot $BackupRoot }
    }
    $entry = [ordered]@{ id=$ThreadId; thread_name=$Title; updated_at=$UpdatedUtc }
    $IndexMap[$ThreadId] = [pscustomobject]$entry
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $lines = New-Object Collections.Generic.List[string]
    foreach ($value in $IndexMap.Values | Sort-Object @{Expression={ [string](Get-PropertyValue $_ 'updated_at' '') }; Descending=$false }) {
        $lines.Add(($value | ConvertTo-Json -Compress))
    }
    Write-AtomicText -Path $path -Text (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    $true
}

function Set-CodexThreadProjectAssignment {
    param([Parameter(Mandatory)][string]$CodexHome, [Parameter(Mandatory)][string]$ThreadId, [string]$CodexProjectId, [Parameter(Mandatory)][string]$BackupRoot)
    if ([string]::IsNullOrWhiteSpace($CodexProjectId)) { return $false }
    $path = Get-CodexGlobalStatePath -CodexHome $CodexHome
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $stateFileBefore = Get-Item -LiteralPath $path -ErrorAction Stop
    $stateLengthBefore = [int64]$stateFileBefore.Length
    $stateWriteBefore = $stateFileBefore.LastWriteTimeUtc.Ticks
    $state = Read-JsonFile -Path $path
    if ($null -eq $state) { return $false }
    $persisted = Get-CodexPersistedAtomState -GlobalState $state
    if ($null -eq $persisted) { return $false }
    $owner = $state
    $assignments = Get-PropertyValue $state 'thread-project-assignments' $null
    if ($null -eq $assignments) { $owner = $persisted; $assignments=Get-PropertyValue $persisted 'thread-project-assignments' $null }
    if ($null -eq $assignments) { $assignments=[pscustomobject]@{}; $owner | Add-Member -NotePropertyName 'thread-project-assignments' -NotePropertyValue $assignments }
    $newValue=[pscustomobject]@{ projectKind='local'; projectId=$CodexProjectId }
    $property=$assignments.PSObject.Properties[$ThreadId]
    $changed=$true
    if ($null -ne $property -and $null -ne $property.Value -and ([string](Get-PropertyValue $property.Value 'projectId' '')).Equals($CodexProjectId,[StringComparison]::OrdinalIgnoreCase) -and [string](Get-PropertyValue $property.Value 'projectKind' '') -eq 'local') { $changed=$false }
    if ($changed) {
        if ($null -ne $property) { $property.Value=$newValue } else { $assignments | Add-Member -NotePropertyName $ThreadId -NotePropertyValue $newValue }
        $projectless=@((Get-PropertyValue $state 'projectless-thread-ids' @()) | Where-Object { -not ([string]$_).Equals($ThreadId,[StringComparison]::OrdinalIgnoreCase) })
        if ($state.PSObject.Properties['projectless-thread-ids']) { $state.'projectless-thread-ids'=@($projectless) }
        if (-not (Test-Path -LiteralPath (Join-Path $BackupRoot '.codex-global-state.json') -PathType Leaf)) { Copy-HistoryBackup -Source $path -CodexHome $CodexHome -BackupRoot $BackupRoot }
        $stateFileNow = Get-Item -LiteralPath $path -ErrorAction Stop
        if ([int64]$stateFileNow.Length -ne $stateLengthBefore -or $stateFileNow.LastWriteTimeUtc.Ticks -ne $stateWriteBefore) {
            throw 'Codex 项目状态在同步过程中发生变化，已取消本次索引回填以避免覆盖新数据。'
        }
        Write-AtomicJson -Path $path -Value $state
    }
    $changed
}

function Import-HistoryRef {
    param(
        [Parameter(Mandatory)]$Ref,
        [Parameter(Mandatory)][string]$CanonicalPath,
        [Parameter(Mandatory)][string]$TargetId,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$VaultRoot,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$ProjectLocalPath,
        [string[]]$ProjectRootPaths,
        [int]$ProjectRootIndex = 0,
        [string]$CodexProjectId,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][hashtable]$IndexMap,
        [switch]$Conflict
    )
    $replacement = if ($TargetId -eq [string]$Ref.ThreadId) { $null } else { $TargetId }
    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) { Copy-HistoryBackup -Source $TargetPath -CodexHome $CodexHome -BackupRoot $BackupRoot }
    Write-MaterializedSessionFile -CanonicalPath $CanonicalPath -TargetPath $TargetPath -VaultId $Config.VaultId -VaultRoot $VaultRoot -ProjectLocalPath $ProjectLocalPath -ProjectRootPaths $ProjectRootPaths -ProjectRootIndex $ProjectRootIndex -ReplacementId $replacement
    $title = [string](Get-PropertyValue $Ref 'Title' '')
    if ($Conflict) {
        $machine = [string](Get-PropertyValue $Ref 'MachineName' '其他电脑')
        if ([string]::IsNullOrWhiteSpace($title)) { $title = '冲突恢复会话' }
        $title += '（冲突副本 · ' + $machine + '）'
    }
    $refUpdatedUtc = [string](Get-PropertyValue $Ref 'UpdatedUtc' ([DateTime]::UtcNow.ToString('o')))
    Append-SessionIndexEntry -CodexHome $CodexHome -ThreadId $TargetId -Title $title -UpdatedUtc $refUpdatedUtc -IndexMap $IndexMap -BackupRoot $BackupRoot | Out-Null
    Set-CodexThreadProjectAssignment -CodexHome $CodexHome -ThreadId $TargetId -CodexProjectId $CodexProjectId -BackupRoot $BackupRoot | Out-Null
    Write-ImportedSessionMarker -SessionPath $TargetPath -Ref ([pscustomobject]@{
        ThreadId=$TargetId; ContentHash=[string](Get-PropertyValue $Ref 'ContentHash' ''); ContentLength=[int64](Get-PropertyValue $Ref 'ContentLength' 0)
    }) -ObjectRelativePath ([string](Get-PropertyValue $Ref 'ObjectPath' ''))
    [pscustomobject]@{
        Id=$TargetId; Path=$TargetPath; Archived=[bool](Get-PropertyValue $Ref 'Archived' $false)
        Hash=[string]$Ref.ContentHash; Length=[int64]$Ref.ContentLength
        Timestamp=[string](Get-PropertyValue $Ref 'SessionTimestamp' ''); CanonicalBytes=$null; CanonicalPath=$CanonicalPath
    }
}

function Initialize-WinSqliteInterop {
    if ('CodexProxy.WinSqlite' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CodexProxy {
    public static class WinSqlite {
        [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Unicode)]
        public static extern int sqlite3_open16(string filename, out IntPtr db);
        [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        public static extern int sqlite3_close(IntPtr db);
        [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        public static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);
        [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
        public static extern int sqlite3_exec(IntPtr db, string sql, IntPtr callback, IntPtr argument, out IntPtr error);
        [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        public static extern void sqlite3_free(IntPtr value);
        [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
        public static extern IntPtr sqlite3_backup_init(IntPtr destination, string destinationName, IntPtr source, string sourceName);
        [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        public static extern int sqlite3_backup_step(IntPtr backup, int pages);
        [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        public static extern int sqlite3_backup_finish(IntPtr backup);
        [DllImport("winsqlite3.dll", CallingConvention=CallingConvention.Cdecl)]
        public static extern IntPtr sqlite3_errmsg(IntPtr db);
    }
}
'@
}

function Get-SqliteErrorMessage {
    param([IntPtr]$Database)
    $pointer = [CodexProxy.WinSqlite]::sqlite3_errmsg($Database)
    if ($pointer -eq [IntPtr]::Zero) { return 'unknown SQLite error' }
    [Runtime.InteropServices.Marshal]::PtrToStringAnsi($pointer)
}

function Open-WinSqlite {
    param([Parameter(Mandatory)][string]$Path)
    Initialize-WinSqliteInterop
    $database = [IntPtr]::Zero
    $code = [CodexProxy.WinSqlite]::sqlite3_open16($Path, [ref]$database)
    if ($code -ne 0) {
        $message = if ($database -ne [IntPtr]::Zero) { Get-SqliteErrorMessage -Database $database } else { '无法打开数据库' }
        if ($database -ne [IntPtr]::Zero) { [CodexProxy.WinSqlite]::sqlite3_close($database) | Out-Null }
        throw "SQLite 打开失败：$message"
    }
    [CodexProxy.WinSqlite]::sqlite3_busy_timeout($database, 5000) | Out-Null
    $database
}

function Invoke-WinSqliteExec {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sql)
    $database = Open-WinSqlite -Path $Path
    try {
        $errorPointer = [IntPtr]::Zero
        $code = [CodexProxy.WinSqlite]::sqlite3_exec($database, $Sql, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$errorPointer)
        if ($code -ne 0) {
            $message = if ($errorPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorPointer) } else { Get-SqliteErrorMessage -Database $database }
            if ($errorPointer -ne [IntPtr]::Zero) { [CodexProxy.WinSqlite]::sqlite3_free($errorPointer) }
            throw "SQLite 执行失败：$message"
        }
    }
    finally { [CodexProxy.WinSqlite]::sqlite3_close($database) | Out-Null }
}

function Backup-WinSqlite {
    param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$DestinationPath)
    $directory = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) { Remove-Item -LiteralPath $DestinationPath -Force }
    $source = Open-WinSqlite -Path $SourcePath
    $destination = Open-WinSqlite -Path $DestinationPath
    try {
        $backup = [CodexProxy.WinSqlite]::sqlite3_backup_init($destination, 'main', $source, 'main')
        if ($backup -eq [IntPtr]::Zero) { throw ('SQLite 备份初始化失败：' + (Get-SqliteErrorMessage -Database $destination)) }
        $stepCode = [CodexProxy.WinSqlite]::sqlite3_backup_step($backup, -1)
        $finishCode = [CodexProxy.WinSqlite]::sqlite3_backup_finish($backup)
        if ($stepCode -ne 101 -or $finishCode -ne 0) { throw "SQLite 备份失败：step=$stepCode finish=$finishCode" }
    }
    finally {
        [CodexProxy.WinSqlite]::sqlite3_close($destination) | Out-Null
        [CodexProxy.WinSqlite]::sqlite3_close($source) | Out-Null
    }
}

function Find-CodexStateDatabase {
    param([Parameter(Mandatory)][string]$CodexHome)
    $roots = New-Object Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_SQLITE_HOME)) { $roots.Add([IO.Path]::GetFullPath($env:CODEX_SQLITE_HOME)) }
    $configToml = Join-Path $CodexHome 'config.toml'
    if (Test-Path -LiteralPath $configToml -PathType Leaf) {
        $match = [regex]::Match((Get-Content -LiteralPath $configToml -Raw), '(?im)^\s*sqlite_home\s*=\s*["'']([^"'']+)["'']')
        if ($match.Success) {
            $candidate = [Environment]::ExpandEnvironmentVariables($match.Groups[1].Value)
            if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $CodexHome $candidate }
            $roots.Add([IO.Path]::GetFullPath($candidate))
        }
    }
    $roots.Add($CodexHome)
    $roots.Add((Join-Path $CodexHome 'sqlite'))
    foreach ($root in @($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $database = Get-ChildItem -LiteralPath $root -File -Filter 'state_*.sqlite' -ErrorAction SilentlyContinue | Sort-Object { if ($_.BaseName -match 'state_(\d+)') { [int]$Matches[1] } else { 0 } } -Descending | Select-Object -First 1
        if ($database) { return $database.FullName }
    }
    $null
}

function Rearm-CodexBackfill {
    param([Parameter(Mandatory)][string]$CodexHome, [Parameter(Mandatory)][string]$BackupRoot)
    $database = Find-CodexStateDatabase -CodexHome $CodexHome
    if ([string]::IsNullOrWhiteSpace($database)) { return $null }
    $backupPath = Join-Path $BackupRoot ([IO.Path]::GetFileName($database))
    Backup-WinSqlite -SourcePath $database -DestinationPath $backupPath
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $sql = "BEGIN IMMEDIATE; UPDATE backfill_state SET status='pending', last_watermark=NULL, last_success_at=NULL, updated_at=$now WHERE id=1; COMMIT;"
    Invoke-WinSqliteExec -Path $database -Sql $sql
    $backupPath
}

function Invoke-HistoryImport {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$VaultRoot, [Parameter(Mandatory)][string]$CodexHome, [Parameter(Mandatory)]$ExportResult)
    $backupBase = if (-not [string]::IsNullOrWhiteSpace($ConfigPathOverride)) { Join-Path (Split-Path -Parent (Get-HistorySyncConfigPath)) 'history-backups' } else { Join-Path (Get-HistorySyncLocalRoot) 'history-backups' }
    $backupRoot = Join-Path $backupBase ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + $script:SyncRunId)
    $localMap = $ExportResult.LocalMap
    $indexMap = $ExportResult.IndexMap
    $refs = @(Get-AllHistoryRefs -VaultRoot $VaultRoot | Sort-Object {[string](Get-PropertyValue $_ 'UpdatedUtc' '')}, {[int64](Get-PropertyValue $_ 'ContentLength' 0)} -Descending)
    $paginationThreads = @{}
    foreach ($candidate in $refs) {
        $candidateId = [string](Get-PropertyValue $candidate 'ThreadId' '')
        if (-not [string]::IsNullOrWhiteSpace($candidateId) -and (Test-HistoryPaginationRef -Ref $candidate -LocalPath '')) { $paginationThreads[$candidateId] = $true }
    }
    $seen = @{}
    $imported = 0
    $updated = 0
    $conflicts = 0
    foreach ($ref in $refs) {
        # A vault may contain several historical refs created before a drive was
        # reconnected or after an older client re-exported imported files. They are
        # still ours, so importing them back would manufacture deterministic conflict
        # threads from our own pagination snapshots. Only external machine refs are
        # eligible for materialization on this computer.
        if ([string](Get-PropertyValue $ref 'MachineId' '') -eq [string]$Config.MachineId) { continue }
        if ([bool](Get-PropertyValue $ref 'Archived' $false) -and -not [bool](Get-PropertyValue $Config 'SyncArchived' $false)) { continue }
        if (-not (Test-HistoryRefSelected -Config $Config -Ref $ref)) { continue }
        $projectId = [string](Get-PropertyValue $ref 'ProjectId' '')
        $binding = Get-HistoryProjectBindingForRef -Config $Config -Ref $ref
        $projectRootIndex = [int](Get-PropertyValue $ref 'ProjectRootIndex' 0)
        $projectRootPaths = @(Get-HistoryBindingRootPaths -Binding $binding)
        $projectLocalPath = Get-HistoryBindingRootAtIndex -Binding $binding -Index $projectRootIndex
        $codexProjectId = [string](Get-PropertyValue $binding 'CodexProjectId' '')
        $threadId = [string](Get-PropertyValue $ref 'ThreadId' '')
        $hash = [string](Get-PropertyValue $ref 'ContentHash' '')
        if ([string]::IsNullOrWhiteSpace($threadId) -or [string]::IsNullOrWhiteSpace($hash)) { continue }
        $dedupeKey = $threadId + '|' + $hash
        if ($seen.ContainsKey($dedupeKey)) { continue }
        $seen[$dedupeKey] = $true
        $objectRelative = ([string](Get-PropertyValue $ref 'ObjectPath' '')).Replace('/', '\')
        if ([IO.Path]::IsPathRooted($objectRelative) -or $objectRelative -match '(^|\\)\.\.(\\|$)') { throw '历史引用包含不安全的对象路径。' }
        $objectPath = [IO.Path]::GetFullPath((Join-Path $VaultRoot $objectRelative))
        $vaultFull = [IO.Path]::GetFullPath($VaultRoot).TrimEnd('\') + '\'
        if (-not $objectPath.StartsWith($vaultFull, [StringComparison]::OrdinalIgnoreCase)) { throw '历史对象路径超出仓库根目录。' }
        if (-not (Test-Path -LiteralPath $objectPath -PathType Leaf)) { throw "历史对象不存在：$objectPath" }
        if ((Get-FileSha256Hex -Path $objectPath) -ne $hash) { throw "历史对象哈希校验失败：$objectPath" }
        $local = if ($localMap.ContainsKey($threadId)) { $localMap[$threadId] } else { $null }
        if ($null -eq $local) {
            $targetPath = Get-ImportPath -CodexHome $CodexHome -VaultId $Config.VaultId -ThreadId $threadId -Timestamp ([string](Get-PropertyValue $ref 'SessionTimestamp' '')) -Archived ([bool](Get-PropertyValue $ref 'Archived' $false))
            $newLocal = Import-HistoryRef -Ref $ref -CanonicalPath $objectPath -TargetId $threadId -TargetPath $targetPath -Config $Config -VaultRoot $VaultRoot -CodexHome $CodexHome -ProjectLocalPath $projectLocalPath -ProjectRootPaths $projectRootPaths -ProjectRootIndex $projectRootIndex -CodexProjectId $codexProjectId -BackupRoot $backupRoot -IndexMap $indexMap
            $localMap[$threadId] = $newLocal
            $imported++
            continue
        }
        if ($local.Hash -eq $hash) { continue }
        $localCanonicalPath = [string](Get-PropertyValue $local 'CanonicalPath' '')
        if ([string]::IsNullOrWhiteSpace($localCanonicalPath) -or -not (Test-Path -LiteralPath $localCanonicalPath -PathType Leaf)) { throw "本机规范化会话对象不存在：$threadId" }
        if ($paginationThreads.ContainsKey($threadId) -or (Test-HistoryPaginationRef -Ref $ref -LocalPath ([string](Get-PropertyValue $local 'Path' '')))) {
            # Codex stores long conversations as a chain of paginated rollout files:
            # each file keeps the same logical session id but may have a suffix UUID
            # and overlapping ordinals. They are snapshots of one thread, not a user
            # conflict. Keep the largest complete snapshot and never mint a conflict
            # id for a shorter continuation page.
            if ([int64](Get-PropertyValue $ref 'ContentLength' 0) -gt [int64](Get-PropertyValue $local 'Length' 0)) {
                $newLocal = Import-HistoryRef -Ref $ref -CanonicalPath $objectPath -TargetId $threadId -TargetPath $local.Path -Config $Config -VaultRoot $VaultRoot -CodexHome $CodexHome -ProjectLocalPath $projectLocalPath -ProjectRootPaths $projectRootPaths -ProjectRootIndex $projectRootIndex -CodexProjectId $codexProjectId -BackupRoot $backupRoot -IndexMap $indexMap
                $localMap[$threadId] = $newLocal
                $updated++
            }
            continue
        }
        if (Test-FilePrefix -PrefixPath $localCanonicalPath -CandidatePath $objectPath) {
            $newLocal = Import-HistoryRef -Ref $ref -CanonicalPath $objectPath -TargetId $threadId -TargetPath $local.Path -Config $Config -VaultRoot $VaultRoot -CodexHome $CodexHome -ProjectLocalPath $projectLocalPath -ProjectRootPaths $projectRootPaths -ProjectRootIndex $projectRootIndex -CodexProjectId $codexProjectId -BackupRoot $backupRoot -IndexMap $indexMap
            $localMap[$threadId] = $newLocal
            $updated++
            continue
        }
        if (Test-FilePrefix -PrefixPath $objectPath -CandidatePath $localCanonicalPath) { continue }
        $conflictId = New-ConflictThreadId -OriginalId $threadId -Hash $hash
        if ($localMap.ContainsKey($conflictId)) { continue }
        $conflictPath = Get-ImportPath -CodexHome $CodexHome -VaultId $Config.VaultId -ThreadId $conflictId -Timestamp ([string](Get-PropertyValue $ref 'SessionTimestamp' '')) -Archived ([bool](Get-PropertyValue $ref 'Archived' $false))
        $newConflict = Import-HistoryRef -Ref $ref -CanonicalPath $objectPath -TargetId $conflictId -TargetPath $conflictPath -Config $Config -VaultRoot $VaultRoot -CodexHome $CodexHome -ProjectLocalPath $projectLocalPath -ProjectRootPaths $projectRootPaths -ProjectRootIndex $projectRootIndex -CodexProjectId $codexProjectId -BackupRoot $backupRoot -IndexMap $indexMap -Conflict
        $localMap[$conflictId] = $newConflict
        $conflicts++
    }
    $changed = $imported + $updated + $conflicts
    $databaseBackup = $null
    if ($changed -gt 0) { $databaseBackup = Rearm-CodexBackfill -CodexHome $CodexHome -BackupRoot $backupRoot }
    [pscustomobject]@{ Imported=$imported; Updated=$updated; Conflicts=$conflicts; Changed=$changed; BackupRoot=$(if($changed -gt 0){$backupRoot}else{$null}); DatabaseBackup=$databaseBackup }
}

function Enter-HistoryVaultLock {
    param([Parameter(Mandatory)][string]$VaultRoot)
    $path = Join-Path $VaultRoot 'sync.lock'
    try {
        $stream = New-Object IO.FileStream($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $contents = [Text.Encoding]::UTF8.GetBytes(([pscustomobject]@{ Machine=[Environment]::MachineName; Process=$PID; StartedUtc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress))
        $stream.SetLength(0); $stream.Write($contents, 0, $contents.Length); $stream.Flush($true)
        $stream
    }
    catch { throw '历史仓库正在被另一台电脑或另一个进程同步，请稍后重试。' }
}

function Start-HistorySyncTransaction {
    param([Parameter(Mandatory)][string]$VaultRoot, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][bool]$LiveMode)
    $path = Join-Path $VaultRoot 'sync.inflight.json'
    $existing = Read-JsonFile -Path $path
    if ($null -ne $existing) {
        $started = [DateTimeOffset]::MinValue
        $text = [string](Get-PropertyValue $existing 'StartedUtc' '')
        if ([DateTimeOffset]::TryParse($text, [ref]$started) -and ([DateTimeOffset]::UtcNow - $started).TotalHours -lt 24) {
            Write-HistorySyncLog -Level WARN -Message "发现未完成同步事务，将在仓库锁保护下恢复：$path"
        }
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    Write-AtomicJson -Path $path -Value ([pscustomobject]@{
        SchemaVersion=1; RunId=$script:SyncRunId; MachineId=[string]$Config.MachineId
        StartedUtc=[DateTime]::UtcNow.ToString('o'); LiveMode=$LiveMode
    })
    $path
}

function Complete-HistorySyncTransaction {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Get-HistorySyncStatus {
    $configPath = Get-HistorySyncConfigPath
    $config = Read-JsonFile -Path $configPath
    $codexHome = Get-HistorySyncCodexHome
    if ($null -eq $config) {
        return [pscustomobject]@{ Success=$true; Configured=$false; Enabled=$false; AutomaticWriteEnabled=$false; AutomaticReady=$false; SyncArchived=$false; Ready=$false; VaultConnected=$false; VaultPath=$null; VaultId=$null; MachineId=$null; LocalSessionCount=@(Get-LocalSessions -CodexHome $codexHome).Count; SelectedProjectCount=0; SelectedLocalSessionCount=0; VaultSessionCount=0; SelectedVaultSessionCount=0; LastSyncUtc=$null; LastSyncOutcome='Never'; Message='尚未选择历史仓库。'; CodexRunning=(Test-CodexDesktopRunning) }
    }
    $vaultRoot = Resolve-HistoryVault -Config $config
    $connected = -not [string]::IsNullOrWhiteSpace($vaultRoot)
    $vaultCount = 0
    $selectedVaultCount = 0
    $bindings = @(Get-HistoryAllProjectBindings -Config $config)
    if ($connected) {
        try {
            $allRefs = @(Get-AllHistoryRefs -VaultRoot $vaultRoot)
            $vaultCount = @(($allRefs | Select-Object -ExpandProperty ThreadId -Unique)).Count
            $selectedVaultCount = @(($allRefs | Where-Object { Test-HistoryRefSelected -Config $config -Ref $_ } | Select-Object -ExpandProperty ThreadId -Unique)).Count
        } catch {}
    }
    $localSessions = @(Get-LocalSessions -CodexHome $codexHome)
    $codexProjects = @(Get-CodexLocalProjectCatalog -CodexHome $codexHome)
    $threadProjectMap = Get-CodexThreadProjectMap -CodexHome $codexHome
    $selectedLocalCount = 0
    foreach ($localFile in $localSessions) {
        if ($localFile.Archived -and -not [bool](Get-PropertyValue $config 'SyncArchived' $false)) { continue }
        $threadId = Get-ThreadIdFromSessionHeader -Path $localFile.Path
        $cwd = Get-WorkingDirectoryFromSessionHeader -Path $localFile.Path
        $info = Get-CodexSessionProjectInfo -CodexHome $codexHome -ThreadId $threadId -WorkingDirectory $cwd -Projects $codexProjects -ThreadProjectMap $threadProjectMap
        $selected = if($null -ne $info -and -not [bool](Get-PropertyValue $info 'Ambiguous' $false)){ $null -ne (Get-HistoryProjectBindingForCodexId -Config $config -CodexProjectId ([string]$info.CodexProjectId)) }else{$false}
        if (-not $selected) { $selected = $null -ne (Get-HistoryProjectBindingForPath -Config $config -WorkingDirectory $cwd) }
        if ($selected) { $selectedLocalCount++ }
    }
    $enabled = [bool](Get-PropertyValue $config 'Enabled' $false)
    $automaticWriteEnabled = [bool](Get-PropertyValue $config 'AutomaticWriteEnabled' $false)
    $ready = ($enabled -and $connected -and $bindings.Count -gt 0)
    $message = if (-not $enabled) { '历史同步已暂停。' } elseif (-not $connected) { '未找到移动历史仓库；请连接移动硬盘或重新选择目录。' } elseif ($bindings.Count -eq 0) { '历史仓库已连接；请选择需要同步的 Codex 项目。' } elseif (-not $automaticWriteEnabled) { '后台自动写入已关闭；请使用“立即同步”手动应用变更。' } else { '历史仓库已连接。' }
    [pscustomobject]@{
        Success=$true; Configured=$true; Enabled=$enabled; AutomaticWriteEnabled=$automaticWriteEnabled; AutomaticReady=($ready -and $automaticWriteEnabled); SyncArchived=[bool](Get-PropertyValue $config 'SyncArchived' $false); Ready=$ready; VaultConnected=$connected
        VaultPath=$vaultRoot; VaultId=[string]$config.VaultId; MachineId=[string]$config.MachineId
        LocalSessionCount=$localSessions.Count; SelectedProjectCount=$bindings.Count; SelectedLocalSessionCount=$selectedLocalCount; VaultSessionCount=$vaultCount; SelectedVaultSessionCount=$selectedVaultCount
        LastSyncUtc=[string](Get-PropertyValue $config 'LastSyncUtc' ''); LastSyncOutcome=[string](Get-PropertyValue $config 'LastSyncOutcome' 'Never')
        Message=$message; CodexRunning=(Test-CodexDesktopRunning)
    }
}

function Save-SyncOutcome {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Outcome, [Parameter(Mandatory)][string]$Message)
    $Config.LastSyncUtc = [DateTime]::UtcNow.ToString('o')
    $Config.LastSyncOutcome = $Outcome
    $Config.LastSyncMessage = $Message
    Write-AtomicJson -Path (Get-HistorySyncConfigPath) -Value $Config
}

function Invoke-HistorySync {
    param([switch]$Automatic)
    $config = Read-JsonFile -Path (Get-HistorySyncConfigPath)
    if ($null -eq $config) { throw '请先在界面中选择移动硬盘上的历史仓库。' }
    if (-not [bool](Get-PropertyValue $config 'Enabled' $false)) { throw '历史同步已暂停，请先启用。' }
    if (@(Get-HistoryAllProjectBindings -Config $config).Count -eq 0) { throw '请先在“同步项目”页面选择至少一个 Codex 项目。' }
    $codexRunning = Test-CodexDesktopRunning
    $automaticWriteEnabled = [bool](Get-PropertyValue $config 'AutomaticWriteEnabled' $false)
    if ($Automatic -and -not $automaticWriteEnabled) {
        return [pscustomobject]@{
            Success=$true; AutomaticBlocked=$true; ManualRequired=$true; LiveMode=$codexRunning
            Message='后台自动写入已关闭，本次自动同步已跳过。请在界面点击“立即同步”，或在设置中开启后台自动写入。'
            VaultPath=[string](Get-PropertyValue $config 'LastKnownVaultPath' '')
            LocalSessionCount=0; Saved=0; Exported=0; Imported=0; Updated=0; Conflicts=0; Skipped=0; PendingImports=0; BackupRoot=$null; DatabaseBackup=$null
        }
    }
    $vaultRoot = Resolve-HistoryVault -Config $config
    if ([string]::IsNullOrWhiteSpace($vaultRoot)) { throw '找不到历史仓库，请连接移动硬盘或重新选择目录。' }
    $codexHome = Get-HistorySyncCodexHome
    if (-not (Test-Path -LiteralPath $codexHome -PathType Container)) { New-Item -ItemType Directory -Path $codexHome -Force | Out-Null }
    $lock = Enter-HistoryVaultLock -VaultRoot $vaultRoot
    $transactionPath = $null
    try {
        Write-HistorySyncLog -Message "开始同步；home=$codexHome；vault=$vaultRoot；machine=$($config.MachineId)。"
        $transactionPath = Start-HistorySyncTransaction -VaultRoot $vaultRoot -Config $config -LiveMode:$codexRunning
        $export = Export-LocalSessions -Config $config -VaultRoot $vaultRoot -CodexHome $codexHome -ChangedOnly:$codexRunning
        if ($codexRunning) {
            $machinePath = Join-Path $vaultRoot ('machines\' + $config.MachineId + '.json')
            $existingMachine = Read-JsonFile -Path $machinePath
            Write-AtomicJson -Path $machinePath -Value ([pscustomobject]@{
                SchemaVersion=1; MachineId=$config.MachineId; MachineName=$config.MachineName
                FirstSeenUtc=[string](Get-PropertyValue $existingMachine 'FirstSeenUtc' ([DateTime]::UtcNow.ToString('o')))
                LastSeenUtc=[DateTime]::UtcNow.ToString('o')
            })
            $pendingVersions = Get-PendingExternalVersionCount -Config $config -VaultRoot $vaultRoot
            $message = "实时保存完成：已选项目内处理 $($export.LocalMap.Count) 个变化会话，新对象 $($export.Exported)，跳过写入中 $($export.Skipped)，外部待应用版本 $pendingVersions。"
            Save-SyncOutcome -Config $config -Outcome 'LiveSnapshot' -Message $message
            Write-HistorySyncLog -Message $message
            $result = [pscustomobject]@{
                Success=$true; AutomaticBlocked=$false; ManualRequired=$false; LiveMode=$true; Message=$message; VaultPath=$vaultRoot
                LocalSessionCount=@(Get-LocalSessions -CodexHome $codexHome).Count; Saved=$export.LocalMap.Count
                Exported=$export.Exported; Imported=0; Updated=0; Conflicts=0; Skipped=$export.Skipped
                PendingImports=$pendingVersions; BackupRoot=$null; DatabaseBackup=$null
            }
            Complete-HistorySyncTransaction -Path $transactionPath
            return $result
        }
        $import = Invoke-HistoryImport -Config $config -VaultRoot $vaultRoot -CodexHome $codexHome -ExportResult $export
        $machinePath = Join-Path $vaultRoot ('machines\' + $config.MachineId + '.json')
        $existingMachine = Read-JsonFile -Path $machinePath
        Write-AtomicJson -Path $machinePath -Value ([pscustomobject]@{
            SchemaVersion=1; MachineId=$config.MachineId; MachineName=$config.MachineName
            FirstSeenUtc=[string](Get-PropertyValue $existingMachine 'FirstSeenUtc' ([DateTime]::UtcNow.ToString('o')))
            LastSeenUtc=[DateTime]::UtcNow.ToString('o')
        })
        $message = "同步完成：上传 $($export.Exported)，导入 $($import.Imported)，更新 $($import.Updated)，冲突副本 $($import.Conflicts)，跳过 $($export.Skipped)。"
        Save-SyncOutcome -Config $config -Outcome 'Succeeded' -Message $message
        Write-HistorySyncLog -Message $message
        $result = [pscustomobject]@{
            Success=$true; AutomaticBlocked=$false; ManualRequired=$false; Message=$message; VaultPath=$vaultRoot; LocalSessionCount=$export.LocalMap.Count
            Exported=$export.Exported; Imported=$import.Imported; Updated=$import.Updated; Conflicts=$import.Conflicts; Skipped=$export.Skipped
            BackupRoot=$import.BackupRoot; DatabaseBackup=$import.DatabaseBackup
        }
        Complete-HistorySyncTransaction -Path $transactionPath
        $result
    }
    catch {
        try { Save-SyncOutcome -Config $config -Outcome 'Failed' -Message $_.Exception.Message } catch {}
        Write-HistorySyncLog -Level ERROR -Message $_.Exception.Message
        throw
    }
    finally { $lock.Dispose() }
}

function Set-HistorySyncEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)
    $config = Read-JsonFile -Path (Get-HistorySyncConfigPath)
    if ($null -eq $config) { throw '请先选择历史仓库。' }
    $config.Enabled = $Enabled
    Write-AtomicJson -Path (Get-HistorySyncConfigPath) -Value $config
    Get-HistorySyncStatus
}

function Set-HistoryAutomaticWriteEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)
    $config = Read-JsonFile -Path (Get-HistorySyncConfigPath)
    if ($null -eq $config) { throw '请先选择历史仓库。' }
    if ($config.PSObject.Properties['AutomaticWriteEnabled']) { $config.AutomaticWriteEnabled = $Enabled }
    else { $config | Add-Member -NotePropertyName AutomaticWriteEnabled -NotePropertyValue $Enabled }
    if ($config.PSObject.Properties['SchemaVersion']) { $config.SchemaVersion = 3 }
    Write-AtomicJson -Path (Get-HistorySyncConfigPath) -Value $config
    Get-HistorySyncStatus
}

function Set-HistoryArchivedSyncEnabled {
    param([Parameter(Mandatory)][bool]$Enabled)
    $config = Read-JsonFile -Path (Get-HistorySyncConfigPath)
    if ($null -eq $config) { throw '请先选择历史仓库。' }
    if ($config.PSObject.Properties['SyncArchived']) { $config.SyncArchived = $Enabled }
    else { $config | Add-Member -NotePropertyName SyncArchived -NotePropertyValue $Enabled }
    Write-AtomicJson -Path (Get-HistorySyncConfigPath) -Value $config
    Get-HistorySyncStatus
}

try {
    $result = switch ($Action) {
        'Status' { Get-HistorySyncStatus }
        'Configure' {
            if ([string]::IsNullOrWhiteSpace($VaultPath)) { throw '必须提供历史仓库目录。' }
            $existing = Read-JsonFile -Path (Get-HistorySyncConfigPath)
            $initialized = Initialize-HistoryVault -SelectedPath $VaultPath -ExistingConfig $existing
            Get-HistorySyncStatus
        }
        'Sync' { Invoke-HistorySync -Automatic:$Automatic }
        'List' { Get-HistoryVaultList }
        'Projects' { Get-HistoryProjectCatalog }
        'CreateProject' {
            if ([string]::IsNullOrWhiteSpace($LocalPath) -and [string]::IsNullOrWhiteSpace($CodexProjectId)) { throw '必须提供本机 Codex 项目或工作目录。' }
            New-HistoryProject -LocalPath $LocalPath -CodexProjectId $CodexProjectId -Name $ProjectName
        }
        'BindProject' {
            if ([string]::IsNullOrWhiteSpace($ProjectId) -or ([string]::IsNullOrWhiteSpace($LocalPath) -and [string]::IsNullOrWhiteSpace($CodexProjectId))) { throw '必须提供同步项目和本机 Codex 项目。' }
            Set-HistoryProjectBinding -ProjectId $ProjectId -LocalPath $LocalPath -CodexProjectId $CodexProjectId
        }
        'UnbindProject' {
            if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw '必须提供同步项目。' }
            Remove-HistoryProjectBinding -ProjectId $ProjectId
        }
        'Enable' { Set-HistorySyncEnabled -Enabled $true }
        'Disable' { Set-HistorySyncEnabled -Enabled $false }
        'EnableAutomatic' { Set-HistoryAutomaticWriteEnabled -Enabled $true }
        'DisableAutomatic' { Set-HistoryAutomaticWriteEnabled -Enabled $false }
        'EnableArchived' { Set-HistoryArchivedSyncEnabled -Enabled $true }
        'DisableArchived' { Set-HistoryArchivedSyncEnabled -Enabled $false }
        'OpenVault' {
            $config = Read-JsonFile -Path (Get-HistorySyncConfigPath)
            if ($null -eq $config) { throw '尚未配置历史仓库。' }
            $vaultRoot = Resolve-HistoryVault -Config $config
            if ([string]::IsNullOrWhiteSpace($vaultRoot)) { throw '历史仓库当前未连接。' }
            Start-Process -FilePath 'explorer.exe' -ArgumentList @($vaultRoot)
            [pscustomobject]@{ Success=$true; Message='已打开历史仓库。'; VaultPath=$vaultRoot }
        }
    }
    if ($Json) { $result | ConvertTo-Json -Depth 12 -Compress }
    else { $result }
}
catch {
    Write-HistorySyncLog -Level ERROR -Message "[$Action] $($_.Exception.Message)"
    $failure = [pscustomobject]@{ Success=$false; Message=$_.Exception.Message; Action=$Action }
    if ($Json) { $failure | ConvertTo-Json -Compress }
    else { [Console]::Error.WriteLine($_.Exception.Message) }
    exit 1
}
