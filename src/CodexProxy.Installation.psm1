Set-StrictMode -Version Latest

function ConvertTo-CodexProxyInstallPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
        $fullPath = [IO.Path]::GetFullPath($expanded).TrimEnd('\')
        $driveRoot = [IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($fullPath) -or $fullPath.Equals($driveRoot, [StringComparison]::OrdinalIgnoreCase)) { return $null }
        return $fullPath
    }
    catch { return $null }
}

function Get-CodexProxyRegistryCandidates {
    $result = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $subKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexProxy'
    $registries = @(
        @{ Hive=[Microsoft.Win32.RegistryHive]::CurrentUser; View=[Microsoft.Win32.RegistryView]::Registry64; Source='RegistryCurrentUser64'; Priority=100 },
        @{ Hive=[Microsoft.Win32.RegistryHive]::CurrentUser; View=[Microsoft.Win32.RegistryView]::Registry32; Source='RegistryCurrentUser32'; Priority=110 },
        @{ Hive=[Microsoft.Win32.RegistryHive]::LocalMachine; View=[Microsoft.Win32.RegistryView]::Registry64; Source='RegistryLocalMachine64'; Priority=120 },
        @{ Hive=[Microsoft.Win32.RegistryHive]::LocalMachine; View=[Microsoft.Win32.RegistryView]::Registry32; Source='RegistryLocalMachine32'; Priority=130 }
    )
    foreach ($registry in $registries) {
        $baseKey = $null
        $key = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($registry.Hive, $registry.View)
            $key = $baseKey.OpenSubKey($subKey)
            if (-not $key) { continue }
            $location = [string]$key.GetValue('InstallLocation', $null)
            if (-not [string]::IsNullOrWhiteSpace($location)) {
                $result.Add([pscustomobject]@{ Source=$registry.Source; Path=$location; Priority=$registry.Priority })
            }
            $icon = [string]$key.GetValue('DisplayIcon', $null)
            if (-not [string]::IsNullOrWhiteSpace($icon)) {
                $iconPath = ($icon -split ',', 2)[0].Trim().Trim('"')
                if (-not [string]::IsNullOrWhiteSpace($iconPath)) {
                    $result.Add([pscustomobject]@{ Source=($registry.Source + 'DisplayIcon'); Path=(Split-Path -Parent $iconPath); Priority=($registry.Priority + 1) })
                }
            }
        }
        catch { $errors.Add("$($registry.Source): $($_.Exception.Message)") }
        finally {
            if ($key) { $key.Dispose() }
            if ($baseKey) { $baseKey.Dispose() }
        }
    }
    [pscustomobject]@{ Candidates=$result.ToArray(); Errors=$errors.ToArray() }
}

function Get-CodexProxyShortcutCandidates {
    $result = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $shortcutPaths = @(
        @{ Path=(Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Codex-Proxy.lnk'); Source='DesktopShortcut'; Priority=200 },
        @{ Path=(Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Codex Proxy.lnk'); Source='DesktopShortcut'; Priority=201 },
        @{ Path=(Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Proxy\Codex Proxy.lnk'); Source='StartMenuShortcut'; Priority=210 },
        @{ Path=(Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Codex-Proxy.lnk'); Source='CommonDesktopShortcut'; Priority=220 },
        @{ Path=(Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Codex Proxy\Codex Proxy.lnk'); Source='CommonStartMenuShortcut'; Priority=230 }
    )
    $shell = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($shortcutInfo in $shortcutPaths) {
            if (-not (Test-Path -LiteralPath $shortcutInfo.Path -PathType Leaf)) { continue }
            try {
                $shortcut = $shell.CreateShortcut($shortcutInfo.Path)
                if (-not [string]::IsNullOrWhiteSpace([string]$shortcut.TargetPath)) {
                    $result.Add([pscustomobject]@{ Source=$shortcutInfo.Source; Path=(Split-Path -Parent ([string]$shortcut.TargetPath)); Priority=$shortcutInfo.Priority })
                }
            }
            catch { $errors.Add("$($shortcutInfo.Source): $($_.Exception.Message)") }
        }
    }
    catch { $errors.Add("ShortcutDiscovery: $($_.Exception.Message)") }
    finally {
        if ($shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    }
    [pscustomobject]@{ Candidates=$result.ToArray(); Errors=$errors.ToArray() }
}

function Get-CodexProxyInstallSourceDescription {
    param([string]$Source)
    if ($Source -like 'Registry*') { return 'Windows installed-app registry' }
    if ($Source -like '*StartMenuShortcut') { return 'Start menu shortcut' }
    if ($Source -like '*DesktopShortcut') { return 'Desktop shortcut' }
    if ($Source -eq 'DefaultDirectory') { return 'Default install directory' }
    return 'Existing installation record'
}

function Resolve-CodexProxyInstallation {
    [CmdletBinding()]
    param([AllowNull()][object[]]$CandidateOverride)

    $errors = [Collections.Generic.List[string]]::new()
    if ($PSBoundParameters.ContainsKey('CandidateOverride')) {
        $candidates = @($CandidateOverride)
    }
    else {
        $registry = Get-CodexProxyRegistryCandidates
        $shortcuts = Get-CodexProxyShortcutCandidates
        foreach ($errorText in @($registry.Errors) + @($shortcuts.Errors)) { $errors.Add([string]$errorText) }
        $candidates = @($registry.Candidates) + @($shortcuts.Candidates) + @(
            [pscustomobject]@{
                Source='DefaultDirectory'
                Path=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexProxy')
                Priority=900
            }
        )
    }

    $rejected = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($candidates | Sort-Object { [int]$_.Priority })) {
        $normalised = ConvertTo-CodexProxyInstallPath -Path ([string]$candidate.Path)
        if (-not $normalised) {
            $rejected.Add([pscustomobject]@{ Source=[string]$candidate.Source; Path=[string]$candidate.Path; Reason='InvalidPath' })
            continue
        }
        if (-not $seen.Add($normalised)) { continue }
        $applicationPath = Join-Path $normalised 'CodexProxy.exe'
        if (-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)) {
            $rejected.Add([pscustomobject]@{ Source=[string]$candidate.Source; Path=$normalised; Reason='ApplicationMissing' })
            continue
        }
        $version = $null
        try { $version = [string](Get-Item -LiteralPath $applicationPath).VersionInfo.FileVersion } catch { }
        return [pscustomobject]@{
            Found=$true
            InstallDirectory=$normalised
            ApplicationPath=$applicationPath
            Source=[string]$candidate.Source
            SourceDescription=(Get-CodexProxyInstallSourceDescription -Source ([string]$candidate.Source))
            InstalledVersion=$version
            RejectedCandidates=$rejected.ToArray()
            Errors=$errors.ToArray()
        }
    }

    [pscustomobject]@{
        Found=$false
        InstallDirectory=$null
        ApplicationPath=$null
        Source=$null
        SourceDescription=$null
        InstalledVersion=$null
        RejectedCandidates=$rejected.ToArray()
        Errors=$errors.ToArray()
    }
}

function Resolve-CodexProxyInstallTarget {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$DetectedInstallation,
        [AllowNull()][string]$RequestedDirectory,
        [Parameter(Mandatory)][string]$DefaultDirectory,
        [switch]$Portable,
        [AllowNull()][string]$PortableDirectory
    )

    if ($Portable) {
        $portableRoot = ConvertTo-CodexProxyInstallPath -Path $PortableDirectory
        if (-not $portableRoot) { throw 'The portable installation directory is invalid.' }
        return [pscustomobject]@{ InstallDirectory=$portableRoot; IsUpgrade=$false; Source='Portable' }
    }

    $requested = if ([string]::IsNullOrWhiteSpace($RequestedDirectory)) { $null } else { ConvertTo-CodexProxyInstallPath -Path $RequestedDirectory }
    if (-not [string]::IsNullOrWhiteSpace($RequestedDirectory) -and -not $requested) { throw 'InstallDirectory is invalid or points to a drive root.' }
    $existing = if ($DetectedInstallation -and $DetectedInstallation.Found) { ConvertTo-CodexProxyInstallPath -Path ([string]$DetectedInstallation.InstallDirectory) } else { $null }
    if ($existing) {
        if ($requested -and -not $requested.Equals($existing, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Codex Proxy is already installed at '$existing'. An upgrade must use the existing directory. Uninstall it first to change the installation directory."
        }
        return [pscustomobject]@{ InstallDirectory=$existing; IsUpgrade=$true; Source=[string]$DetectedInstallation.Source }
    }

    $target = if ($requested) { $requested } else { ConvertTo-CodexProxyInstallPath -Path $DefaultDirectory }
    if (-not $target) { throw 'The default installation directory is invalid.' }
    [pscustomobject]@{ InstallDirectory=$target; IsUpgrade=$false; Source=$(if($requested){'Requested'}else{'Default'}) }
}

function Remove-CodexProxyRetiredFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallDirectory)

    $installRoot = ConvertTo-CodexProxyInstallPath -Path $InstallDirectory
    if (-not $installRoot) { throw 'The installation directory is invalid.' }
    # Only remove obsolete product files. User settings, backups and vaults stay intact.
    foreach ($relativePath in @('HistorySync.ps1', 'Repair-CodexHistory.ps1', 'docs\history-sync-design.md')) {
        $path = Join-Path $installRoot $relativePath
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    }
}

Export-ModuleMember -Function Resolve-CodexProxyInstallation,Resolve-CodexProxyInstallTarget,Remove-CodexProxyRetiredFiles
