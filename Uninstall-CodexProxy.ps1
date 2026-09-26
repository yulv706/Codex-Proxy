[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [switch]$Portable,
    [switch]$KeepInstalledFiles,
    [switch]$PurgeCache,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invocationRoot = $PSScriptRoot
$modulePath = Join-Path $invocationRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $invocationRoot 'CodexProxy.config.psd1'
Import-Module -Name $modulePath -Force
$config = Get-CodexProxyConfig -Path $configPath -UserPath (Join-Path $invocationRoot 'CodexProxy.user.psd1')
$invocationStatePath = Join-Path $invocationRoot 'install-state.json'
$invocationState = if (Test-Path -LiteralPath $invocationStatePath -PathType Leaf) { Get-Content -LiteralPath $invocationStatePath -Raw | ConvertFrom-Json } else { $null }
$stateMatchesInvocation = [bool]($invocationState -and $invocationState.PSObject.Properties.Name -contains 'InstallRoot' -and [IO.Path]::GetFullPath([string]$invocationState.InstallRoot).TrimEnd('\').Equals([IO.Path]::GetFullPath($invocationRoot).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase))
$installRoot = if ($Portable -or $stateMatchesInvocation) { $invocationRoot } else { $config.InstallDirectory }
$statePath = Join-Path $installRoot 'install-state.json'
$state = if ($stateMatchesInvocation) { $invocationState } elseif (Test-Path -LiteralPath $statePath -PathType Leaf) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
$launcherPath = Join-Path $installRoot 'Start-CodexProxy.ps1'
$applicationPath = Join-Path $installRoot 'CodexProxy.exe'
$updateLauncherPath = Join-Path $installRoot 'Update-CodexProxy.ps1'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath $config.ShortcutName
$updateShortcutPath = Join-Path $desktopPath 'Codex-Proxy 更新.lnk'
if ($state) {
    if ([IO.Path]::GetFullPath([string]$state.InstallRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($installRoot).TrimEnd('\')) { throw '安装状态中的安装目录与当前目标不一致，已拒绝卸载。' }
    if ([IO.Path]::GetFullPath([string]$state.LauncherPath) -ne [IO.Path]::GetFullPath($launcherPath)) { throw '安装状态中的启动器路径无效，已拒绝卸载。' }
    if ($state.PSObject.Properties.Name -contains 'ApplicationPath' -and [IO.Path]::GetFullPath([string]$state.ApplicationPath) -ne [IO.Path]::GetFullPath($applicationPath)) { throw '安装状态中的桌面应用路径无效，已拒绝卸载。' }
    if ([IO.Path]::GetFullPath([string]$state.ShortcutPath) -ne [IO.Path]::GetFullPath($shortcutPath)) { throw '安装状态中的快捷方式路径无效，已拒绝卸载。' }
    if ($state.PSObject.Properties.Name -contains 'UpdateLauncherPath' -and [IO.Path]::GetFullPath([string]$state.UpdateLauncherPath) -ne [IO.Path]::GetFullPath($updateLauncherPath)) { throw '安装状态中的更新器路径无效，已拒绝卸载。' }
    if ($state.PSObject.Properties.Name -contains 'UpdateShortcutPath' -and [IO.Path]::GetFullPath([string]$state.UpdateShortcutPath) -ne [IO.Path]::GetFullPath($updateShortcutPath)) { throw '安装状态中的更新快捷方式路径无效，已拒绝卸载。' }
}

if (-not $Quiet -and -not $WhatIfPreference) {
    Add-Type -AssemblyName PresentationFramework
    $confirmation = [System.Windows.MessageBox]::Show(
        "确定要卸载 Codex Proxy 吗？`n`n官方 Codex、本地代理客户端和 helper 缓存不会被删除。",
        '卸载 Codex Proxy',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($confirmation -ne [System.Windows.MessageBoxResult]::Yes) {
        Write-Host '已取消卸载。'
        exit 0
    }
}
$ConfirmPreference = 'None'

try {
    $exitEvent = [Threading.EventWaitHandle]::OpenExisting('Local\CodexProxy.Tray.Exit')
    try { $exitEvent.Set() | Out-Null } finally { $exitEvent.Dispose() }
}
catch {}
$applicationFullPath = [IO.Path]::GetFullPath($applicationPath)
$deadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    $applicationProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'CodexProxy.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and [IO.Path]::GetFullPath([string]$_.ExecutablePath).Equals($applicationFullPath, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($applicationProcesses.Count -eq 0) { break }
    Start-Sleep -Milliseconds 250
} while ([DateTime]::UtcNow -lt $deadline)
if ($applicationProcesses.Count -gt 0) { throw 'Codex Proxy 状态监控仍在运行。请从右下角托盘退出后重试卸载。' }

if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
    $shortcutStatus = Test-CodexProxyAppShortcut -Path $shortcutPath -ApplicationPath $applicationPath
    $legacyShortcutStatus = Test-CodexProxyShortcut -Path $shortcutPath -LauncherPath $launcherPath
    if (-not $shortcutStatus.Ready -and -not $legacyShortcutStatus.Ready) {
        throw '桌面快捷方式与安装记录不匹配，因此没有删除。请先运行安装脚本修复，或手动确认快捷方式归属。'
    }
    if ($PSCmdlet.ShouldProcess($shortcutPath, '删除 Codex Proxy 桌面快捷方式')) {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Host "已删除桌面快捷方式：$shortcutPath"
    }
}
else {
    Write-Host "桌面快捷方式已经不存在：$shortcutPath"
}

if (-not $Portable) {
    $programsRoot = [IO.Path]::GetFullPath([Environment]::GetFolderPath('Programs')).TrimEnd('\') + '\'
    $startMenuDirectory = if ($state -and $state.PSObject.Properties.Name -contains 'StartMenuDirectory' -and $state.StartMenuDirectory) { [string]$state.StartMenuDirectory } else { Join-Path $programsRoot 'Codex Proxy' }
    $startMenuFullPath = [IO.Path]::GetFullPath($startMenuDirectory).TrimEnd('\')
    if (-not "$startMenuFullPath\".StartsWith($programsRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "拒绝删除非预期开始菜单目录：$startMenuFullPath" }
    if ((Test-Path -LiteralPath $startMenuFullPath -PathType Container) -and $PSCmdlet.ShouldProcess($startMenuFullPath, '删除 Codex Proxy 开始菜单快捷方式')) {
        Remove-Item -LiteralPath $startMenuFullPath -Recurse -Force
    }

    $uninstallRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CodexProxy'
    if ((Test-Path -LiteralPath $uninstallRegistryPath) -and $PSCmdlet.ShouldProcess($uninstallRegistryPath, '删除 Windows 已安装应用注册信息')) {
        Remove-Item -LiteralPath $uninstallRegistryPath -Recurse -Force
    }

    $runRegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $startupProperty = Get-ItemProperty -LiteralPath $runRegistryPath -Name CodexProxy -ErrorAction SilentlyContinue
    $startupCommand = if ($startupProperty) { [string]$startupProperty.CodexProxy } else { $null }
    if ($startupCommand -and $startupCommand -match [regex]::Escape($applicationPath) -and $PSCmdlet.ShouldProcess('CodexProxy', '删除登录时自动运行设置')) {
        Remove-ItemProperty -LiteralPath $runRegistryPath -Name CodexProxy -Force
    }
}

if (Test-Path -LiteralPath $updateShortcutPath -PathType Leaf) {
    $updateShortcutStatus = Test-CodexProxyShortcut -Path $updateShortcutPath -LauncherPath $updateLauncherPath
    if ($updateShortcutStatus.Owned -and $PSCmdlet.ShouldProcess($updateShortcutPath, '删除旧版 Codex Proxy 更新快捷方式')) {
        Remove-Item -LiteralPath $updateShortcutPath -Force
        Write-Host "已删除旧版桌面更新快捷方式：$updateShortcutPath"
    }
}

if ($state -and $state.ReplacedShortcut -and (Test-Path -LiteralPath ([string]$state.ReplacedShortcut) -PathType Leaf)) {
    $backupFullPath = [IO.Path]::GetFullPath([string]$state.ReplacedShortcut)
    $desktopFullPath = [IO.Path]::GetFullPath($desktopPath).TrimEnd('\') + '\'
    if (-not $backupFullPath.StartsWith($desktopFullPath, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($backupFullPath) -notlike "$($config.ShortcutName).before-codex-proxy-*.bak") {
        throw '安装状态中的快捷方式备份路径无效，已拒绝恢复。'
    }
    if ($PSCmdlet.ShouldProcess($shortcutPath, '恢复安装前备份的同名快捷方式')) {
        Move-Item -LiteralPath $backupFullPath -Destination $shortcutPath
        Write-Host "已恢复安装前的快捷方式：$shortcutPath"
    }
}

if ($state -and $state.PSObject.Properties.Name -contains 'ReplacedUpdateShortcut' -and $state.ReplacedUpdateShortcut -and (Test-Path -LiteralPath ([string]$state.ReplacedUpdateShortcut) -PathType Leaf)) {
    $updateBackupFullPath = [IO.Path]::GetFullPath([string]$state.ReplacedUpdateShortcut)
    $desktopFullPath = [IO.Path]::GetFullPath($desktopPath).TrimEnd('\') + '\'
    if (-not $updateBackupFullPath.StartsWith($desktopFullPath, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($updateBackupFullPath) -notlike 'Codex-Proxy 更新.lnk.before-codex-proxy-*.bak') {
        throw '安装状态中的更新快捷方式备份路径无效，已拒绝恢复。'
    }
    if ($PSCmdlet.ShouldProcess($updateShortcutPath, '恢复安装前备份的同名更新快捷方式')) {
        Move-Item -LiteralPath $updateBackupFullPath -Destination $updateShortcutPath
        Write-Host "已恢复安装前的更新快捷方式：$updateShortcutPath"
    }
}

if ($PurgeCache -and (Test-Path -LiteralPath $config.HelperCacheDirectory -PathType Container)) {
    $localAppData = [IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData')).TrimEnd('\') + '\'
    $cachePath = [IO.Path]::GetFullPath($config.HelperCacheDirectory)
    if (-not $cachePath.StartsWith($localAppData, [StringComparison]::OrdinalIgnoreCase)) { throw "拒绝删除非 LocalAppData 缓存目录：$cachePath" }
    if ($PSCmdlet.ShouldProcess($cachePath, '递归删除 Codex Proxy helper 缓存')) {
        Remove-Item -LiteralPath $cachePath -Recurse -Force
        Write-Host "已删除 helper 缓存：$cachePath"
    }
}

if ($Portable) {
    foreach ($fileName in @('CodexProxy.user.psd1','install-state.json')) {
        $path = Join-Path $installRoot $fileName
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and $PSCmdlet.ShouldProcess($path, '删除便携安装状态')) { Remove-Item -LiteralPath $path -Force }
    }
    Write-Host '便携项目文件已保留。'
}
elseif (-not $KeepInstalledFiles -and (Test-Path -LiteralPath $installRoot -PathType Container)) {
    $expected = if ($state -and $state.PSObject.Properties.Name -contains 'InstallRoot') { [IO.Path]::GetFullPath([string]$state.InstallRoot).TrimEnd('\') } else { [IO.Path]::GetFullPath($config.InstallDirectory).TrimEnd('\') }
    $actual = [IO.Path]::GetFullPath($installRoot).TrimEnd('\')
    if ($actual -ne $expected) { throw "拒绝删除非预期安装目录：$actual" }
    if ($PSCmdlet.ShouldProcess($actual, '递归删除 Codex Proxy 稳定安装目录')) {
        Remove-Item -LiteralPath $actual -Recurse -Force
        Write-Host "已删除安装目录：$actual"
    }
}

Write-Host '未卸载官方 Codex，也未修改系统代理。' -ForegroundColor Green
