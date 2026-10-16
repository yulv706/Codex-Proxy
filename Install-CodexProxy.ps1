[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 65535)][int]$ProxyPort = 7891,
    [string]$InstallDirectory,
    [switch]$Portable,
    [switch]$ForceShortcutReplacement,
    [switch]$NoDesktopShortcut,
    [switch]$NoStartMenuShortcut,
    [switch]$NoLaunch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$productVersion = '4.1.0'
$sourceRoot = $PSScriptRoot
$sourceModulePath = Join-Path $sourceRoot 'src\CodexProxy.Common.psm1'
$installationModulePath = Join-Path $sourceRoot 'src\CodexProxy.Installation.psm1'
$sourceConfigPath = Join-Path $sourceRoot 'CodexProxy.config.psd1'
Import-Module -Name $sourceModulePath -Force
Import-Module -Name $installationModulePath -Force
$proxyPortWasSpecified = $PSBoundParameters.ContainsKey('ProxyPort')
$baseConfig = Get-CodexProxyConfig -Path $sourceConfigPath
$installDirectoryWasSpecified = $PSBoundParameters.ContainsKey('InstallDirectory')
if ($Portable -and $installDirectoryWasSpecified) { throw 'InstallDirectory 不能与 Portable 同时使用。' }
if ($installDirectoryWasSpecified -and [string]::IsNullOrWhiteSpace($InstallDirectory)) { throw 'InstallDirectory 不能为空。' }
$detectedInstallation = if ($Portable) { $null } else { Resolve-CodexProxyInstallation }
$installTarget = Resolve-CodexProxyInstallTarget -DetectedInstallation $detectedInstallation -RequestedDirectory $(if($installDirectoryWasSpecified){$InstallDirectory}else{$null}) -DefaultDirectory $baseConfig.InstallDirectory -Portable:$Portable -PortableDirectory $sourceRoot
$customInstallRoot = if ($installDirectoryWasSpecified -and -not $installTarget.IsUpgrade) { $installTarget.InstallDirectory } else { $null }
$preliminaryInstallRoot = $installTarget.InstallDirectory
$existingUserConfigPath = Join-Path $preliminaryInstallRoot 'CodexProxy.user.psd1'
if (-not (Test-Path -LiteralPath $existingUserConfigPath -PathType Leaf) -and $customInstallRoot) {
    $legacyUserConfigPath = Join-Path $baseConfig.InstallDirectory 'CodexProxy.user.psd1'
    if (Test-Path -LiteralPath $legacyUserConfigPath -PathType Leaf) { $existingUserConfigPath = $legacyUserConfigPath }
}
if (-not $proxyPortWasSpecified -and (Test-Path -LiteralPath $existingUserConfigPath -PathType Leaf)) {
    $ProxyPort = (Get-CodexProxyConfig -Path $sourceConfigPath -UserPath $existingUserConfigPath).ProxyPort
}
$config = Get-CodexProxyConfig -Path $sourceConfigPath -ProxyPortOverride $ProxyPort
$installRoot = $installTarget.InstallDirectory
$buildScriptPath = Join-Path $sourceRoot 'Build-CodexProxyApp.ps1'
$builtApplicationPath = Join-Path $sourceRoot 'bin\CodexProxy.exe'
$applicationPath = Join-Path $installRoot 'CodexProxy.exe'
$productFiles = Import-PowerShellDataFile -LiteralPath (Join-Path $sourceRoot 'CodexProxy.files.psd1')
foreach ($relativePath in $productFiles.Files) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot $relativePath) -PathType Leaf)) { throw "安装包文件缺失：$relativePath，请重新解压完整安装包。" }
}

function Stop-CodexProxyTray {
    param([Parameter(Mandatory)][string]$ExpectedApplicationPath)
    $expected = [IO.Path]::GetFullPath($ExpectedApplicationPath)
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'CodexProxy.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and [IO.Path]::GetFullPath([string]$_.ExecutablePath).Equals($expected, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($running.Count -eq 0) { return }
    try {
        $event = [Threading.EventWaitHandle]::OpenExisting('Local\CodexProxy.Tray.Exit')
        try { $event.Set() | Out-Null } finally { $event.Dispose() }
    }
    catch {}
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $running = @(Get-CimInstance Win32_Process -Filter "Name = 'CodexProxy.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and [IO.Path]::GetFullPath([string]$_.ExecutablePath).Equals($expected, [StringComparison]::OrdinalIgnoreCase)
        })
    } while ($running.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($running.Count -gt 0) { throw 'Codex Proxy 仍在运行。请从右下角托盘退出状态监控后重试升级。' }
}

function Copy-ProductFile {
    param([Parameter(Mandatory)][string]$RelativePath)
    $source = Join-Path $sourceRoot $RelativePath
    $destination = Join-Path $installRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "缺少安装文件：$source" }
    if ([IO.Path]::GetFullPath($source) -eq [IO.Path]::GetFullPath($destination)) { return }
    $destinationDirectory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDirectory)) { New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null }
    $temporary = "$destination.installing-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $source -Destination $temporary
        Move-Item -LiteralPath $temporary -Destination $destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

if ($PSCmdlet.ShouldProcess($installRoot, $(if($Portable){'配置便携安装'}else{'安装或升级 Codex Proxy'}))) {
    Stop-CodexProxyTray -ExpectedApplicationPath $applicationPath
    if (-not (Test-Path -LiteralPath $buildScriptPath -PathType Leaf)) { throw "缺少应用构建脚本：$buildScriptPath" }
    $applicationNeedsBuild = -not (Test-Path -LiteralPath $builtApplicationPath -PathType Leaf)
    if (-not $applicationNeedsBuild) {
        try { $applicationNeedsBuild = (Get-Item -LiteralPath $builtApplicationPath).VersionInfo.FileVersionRaw -ne ($productVersion + '.0') } catch { $applicationNeedsBuild = $true }
    }
    if (-not $applicationNeedsBuild) {
        $builtAt = (Get-Item -LiteralPath $builtApplicationPath).LastWriteTimeUtc
        $applicationNeedsBuild = @($productFiles.Files | Where-Object { $_ -like 'src\*' -and (Get-Item -LiteralPath (Join-Path $sourceRoot $_)).LastWriteTimeUtc -gt $builtAt }).Count -gt 0
    }
    if ($applicationNeedsBuild) { & $buildScriptPath -OutputPath $builtApplicationPath }
    if (-not (Test-Path -LiteralPath $builtApplicationPath -PathType Leaf)) { throw "桌面应用构建结果不存在：$builtApplicationPath" }

    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    foreach ($relativePath in @($productFiles.Files) + @('bin\CodexProxy.exe')) {
        Copy-ProductFile -RelativePath $relativePath
    }
    Remove-CodexProxyRetiredFiles -InstallDirectory $installRoot
    if ([IO.Path]::GetFullPath($builtApplicationPath) -ne [IO.Path]::GetFullPath($applicationPath)) {
        $applicationTemporary = "$applicationPath.installing-$([guid]::NewGuid().ToString('N')).tmp"
        try {
            Copy-Item -LiteralPath $builtApplicationPath -Destination $applicationTemporary
            Move-Item -LiteralPath $applicationTemporary -Destination $applicationPath -Force
        }
        finally {
            if (Test-Path -LiteralPath $applicationTemporary -PathType Leaf) { Remove-Item -LiteralPath $applicationTemporary -Force -ErrorAction SilentlyContinue }
        }
    }

    $userConfigPath = Join-Path $installRoot 'CodexProxy.user.psd1'
    if (-not (Test-Path -LiteralPath $userConfigPath) -or $proxyPortWasSpecified) {
        $userConfigTemporary = "$userConfigPath.installing-$([guid]::NewGuid().ToString('N')).tmp"
        $userConfigText = if (Test-Path -LiteralPath $userConfigPath) { Get-Content -LiteralPath $userConfigPath -Raw } else { "@{`r`n}`r`n" }
        if ($userConfigText -match '(?im)^\s*ProxyPort\s*=\s*\d+\s*$') {
            $userConfigText = [regex]::Replace($userConfigText, '(?im)^(\s*ProxyPort\s*=\s*)\d+(\s*)$', [Text.RegularExpressions.MatchEvaluator]{ param($match) $match.Groups[1].Value + $ProxyPort + $match.Groups[2].Value })
        }
        else { $userConfigText = $userConfigText.Insert($userConfigText.LastIndexOf('}'), "    ProxyPort = $ProxyPort`r`n") }
        try {
            $userConfigText | Set-Content -LiteralPath $userConfigTemporary -Encoding UTF8
            Move-Item -LiteralPath $userConfigTemporary -Destination $userConfigPath -Force
        }
        finally { if (Test-Path -LiteralPath $userConfigTemporary) { Remove-Item -LiteralPath $userConfigTemporary -Force } }
    }

    $launcherPath = Join-Path $installRoot 'Start-CodexProxy.ps1'
    $iconPath = Join-Path $installRoot 'assets\codex-proxy.ico'
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktopPath $config.ShortcutName
    $startMenuDirectory = $null
    $uninstallRegistryPath = $null
    $legacyUpdateLauncherPath = Join-Path $installRoot 'Update-CodexProxy.ps1'
    $legacyUpdateShortcutPath = Join-Path $desktopPath 'Codex-Proxy 更新.lnk'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $previousStatePath = Join-Path $installRoot 'install-state.json'
    $previousState = if (Test-Path -LiteralPath $previousStatePath -PathType Leaf) { Get-Content -LiteralPath $previousStatePath -Raw | ConvertFrom-Json } else { $null }
    $backupPath = if ($previousState -and $previousState.PSObject.Properties.Name -contains 'ReplacedShortcut' -and $previousState.ReplacedShortcut) { [string]$previousState.ReplacedShortcut } else { $null }
    $legacyUpdateBackupPath = if ($previousState -and $previousState.PSObject.Properties.Name -contains 'ReplacedUpdateShortcut' -and $previousState.ReplacedUpdateShortcut) { [string]$previousState.ReplacedUpdateShortcut } else { $null }

    if (-not $NoDesktopShortcut -and (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
        $existingStatus = Test-CodexProxyAppShortcut -Path $shortcutPath -ApplicationPath $applicationPath
        $legacyLauncherStatus = Test-CodexProxyShortcut -Path $shortcutPath -LauncherPath $launcherPath
        $existingOwned = [bool]($existingStatus.Owned -or $legacyLauncherStatus.Owned)
        if (-not $existingStatus.Ready -and -not $existingOwned -and -not $ForceShortcutReplacement) {
            throw "桌面上存在同名但不属于 Codex Proxy 的快捷方式。若确定要替换，请重新运行并添加 -ForceShortcutReplacement：$shortcutPath"
        }
        if (-not $existingStatus.Ready -and -not $existingOwned) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = "$shortcutPath.before-codex-proxy-$stamp.bak"
            Copy-Item -LiteralPath $shortcutPath -Destination $backupPath
        }
    }

    if (Test-Path -LiteralPath $legacyUpdateShortcutPath -PathType Leaf) {
        $legacyUpdateStatus = Test-CodexProxyShortcut -Path $legacyUpdateShortcutPath -LauncherPath $legacyUpdateLauncherPath
        if ($legacyUpdateStatus.Owned) { Remove-Item -LiteralPath $legacyUpdateShortcutPath -Force }
    }
    if ($legacyUpdateBackupPath -and (Test-Path -LiteralPath $legacyUpdateBackupPath -PathType Leaf) -and -not (Test-Path -LiteralPath $legacyUpdateShortcutPath)) {
        $legacyBackupFullPath = [IO.Path]::GetFullPath($legacyUpdateBackupPath)
        $desktopFullPath = [IO.Path]::GetFullPath($desktopPath).TrimEnd('\') + '\'
        if ($legacyBackupFullPath.StartsWith($desktopFullPath, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($legacyBackupFullPath) -like 'Codex-Proxy 更新.lnk.before-codex-proxy-*.bak') {
            Move-Item -LiteralPath $legacyBackupFullPath -Destination $legacyUpdateShortcutPath
        }
    }
    if (Test-Path -LiteralPath $legacyUpdateLauncherPath -PathType Leaf) {
        Remove-Item -LiteralPath $legacyUpdateLauncherPath -Force
    }

    $shell = New-Object -ComObject WScript.Shell
    if (-not $NoDesktopShortcut) {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $applicationPath
        $shortcut.Arguments = ''
        $shortcut.WorkingDirectory = $installRoot
        $shortcut.IconLocation = "$iconPath,0"
        $shortcut.Description = "$($config.ShortcutDescription)（端口 $ProxyPort）"
        $shortcut.WindowStyle = 1
        $shortcut.Save()

        $verification = Test-CodexProxyAppShortcut -Path $shortcutPath -ApplicationPath $applicationPath
        if (-not $verification.Ready) { throw "快捷方式校验失败：$shortcutPath" }
    }

    if (-not $Portable) {
        $startMenuRoot = [Environment]::GetFolderPath('Programs')
        $startMenuDirectory = Join-Path $startMenuRoot 'Codex Proxy'
        $uninstallerPath = Join-Path $installRoot 'Uninstall-CodexProxy.ps1'
        if (-not $NoStartMenuShortcut) {
            New-Item -ItemType Directory -Path $startMenuDirectory -Force | Out-Null

            $startMenuAppPath = Join-Path $startMenuDirectory 'Codex Proxy.lnk'
            $startMenuApp = $shell.CreateShortcut($startMenuAppPath)
            $startMenuApp.TargetPath = $applicationPath
            $startMenuApp.Arguments = ''
            $startMenuApp.WorkingDirectory = $installRoot
            $startMenuApp.IconLocation = "$iconPath,0"
            $startMenuApp.Description = $config.ShortcutDescription
            $startMenuApp.Save()

            $startMenuUninstallPath = Join-Path $startMenuDirectory '卸载 Codex Proxy.lnk'
            $startMenuUninstall = $shell.CreateShortcut($startMenuUninstallPath)
            $startMenuUninstall.TargetPath = $powershellPath
            $startMenuUninstall.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $uninstallerPath
            $startMenuUninstall.WorkingDirectory = $installRoot
            $startMenuUninstall.IconLocation = "$iconPath,0"
            $startMenuUninstall.Description = '卸载 Codex Proxy'
            $startMenuUninstall.Save()
        }

        $uninstallRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexProxy'
        New-Item -Path $uninstallRegistryPath -Force | Out-Null
        $uninstallCommand = '"{0}" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "{1}" -Quiet' -f $powershellPath,$uninstallerPath
        $quietUninstallCommand = $uninstallCommand
        $estimatedSize = [int][Math]::Ceiling(((Get-ChildItem -LiteralPath $installRoot -File -Recurse | Measure-Object -Property Length -Sum).Sum) / 1KB)
        Set-ItemProperty -Path $uninstallRegistryPath -Name DisplayName -Value 'Codex Proxy'
        Set-ItemProperty -Path $uninstallRegistryPath -Name DisplayVersion -Value $productVersion
        Set-ItemProperty -Path $uninstallRegistryPath -Name Publisher -Value 'Codex Proxy Community'
        Set-ItemProperty -Path $uninstallRegistryPath -Name InstallLocation -Value $installRoot
        Set-ItemProperty -Path $uninstallRegistryPath -Name DisplayIcon -Value "$applicationPath,0"
        Set-ItemProperty -Path $uninstallRegistryPath -Name UninstallString -Value $uninstallCommand
        Set-ItemProperty -Path $uninstallRegistryPath -Name QuietUninstallString -Value $quietUninstallCommand
        Set-ItemProperty -Path $uninstallRegistryPath -Name InstallDate -Value (Get-Date -Format 'yyyyMMdd')
        Set-ItemProperty -Path $uninstallRegistryPath -Name EstimatedSize -Value $estimatedSize -Type DWord
        Set-ItemProperty -Path $uninstallRegistryPath -Name NoModify -Value 1 -Type DWord
        Set-ItemProperty -Path $uninstallRegistryPath -Name NoRepair -Value 1 -Type DWord
    }

    $statePath = Join-Path $installRoot 'install-state.json'
    $stateTemporary = "$statePath.installing-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [pscustomobject]@{
            SchemaVersion       = 4
            ProductVersion      = $productVersion
            InstallMode         = if ($Portable) { 'Portable' } elseif (-not $installRoot.Equals($baseConfig.InstallDirectory, [StringComparison]::OrdinalIgnoreCase)) { 'Custom' } else { 'LocalAppData' }
            InstallRoot         = $installRoot
            ApplicationPath     = $applicationPath
            LauncherPath        = $launcherPath
            ShortcutPath        = $shortcutPath
            StartMenuDirectory  = $startMenuDirectory
            UninstallRegistryPath = $uninstallRegistryPath
            ReplacedShortcut    = $backupPath
            ProxyPort           = $ProxyPort
            InstalledAtUtc      = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $stateTemporary -Encoding UTF8
        Move-Item -LiteralPath $stateTemporary -Destination $statePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $stateTemporary -PathType Leaf) { Remove-Item -LiteralPath $stateTemporary -Force -ErrorAction SilentlyContinue }
    }

    Write-Host "Codex Proxy $productVersion 已安装：$installRoot" -ForegroundColor Green
    if (-not $NoDesktopShortcut) { Write-Host "桌面快捷方式：$shortcutPath" }
    Write-Host "代理地址：http://127.0.0.1:$ProxyPort"
    Write-Host '未修改用户级、机器级或系统代理设置。'
    Write-Host "如需检查状态：powershell.exe -NoLogo -NoProfile -File `"$(Join-Path $installRoot 'Test-CodexProxy.ps1')`""
    if (-not $NoLaunch) { Start-Process -FilePath $applicationPath -WorkingDirectory $installRoot }
}
