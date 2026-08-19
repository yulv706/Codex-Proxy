[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [switch]$Portable,
    [switch]$KeepInstalledFiles,
    [switch]$PurgeCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invocationRoot = $PSScriptRoot
$modulePath = Join-Path $invocationRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $invocationRoot 'CodexProxy.config.psd1'
Import-Module -Name $modulePath -Force
$config = Get-CodexProxyConfig -Path $configPath -UserPath (Join-Path $invocationRoot 'CodexProxy.user.psd1')
$installRoot = if ($Portable) { $invocationRoot } else { $config.InstallDirectory }
$statePath = Join-Path $installRoot 'install-state.json'
$state = if (Test-Path -LiteralPath $statePath -PathType Leaf) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
$launcherPath = Join-Path $installRoot 'Start-CodexProxy.ps1'
$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath $config.ShortcutName
if ($state) {
    if ([IO.Path]::GetFullPath([string]$state.InstallRoot).TrimEnd('\') -ne [IO.Path]::GetFullPath($installRoot).TrimEnd('\')) { throw '安装状态中的安装目录与当前目标不一致，已拒绝卸载。' }
    if ([IO.Path]::GetFullPath([string]$state.LauncherPath) -ne [IO.Path]::GetFullPath($launcherPath)) { throw '安装状态中的启动器路径无效，已拒绝卸载。' }
    if ([IO.Path]::GetFullPath([string]$state.ShortcutPath) -ne [IO.Path]::GetFullPath($shortcutPath)) { throw '安装状态中的快捷方式路径无效，已拒绝卸载。' }
}

if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
    $shortcutStatus = Test-CodexProxyShortcut -Path $shortcutPath -LauncherPath $launcherPath
    if (-not $shortcutStatus.Ready) {
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
    $expected = [IO.Path]::GetFullPath($config.InstallDirectory).TrimEnd('\')
    $actual = [IO.Path]::GetFullPath($installRoot).TrimEnd('\')
    if ($actual -ne $expected) { throw "拒绝删除非预期安装目录：$actual" }
    if ($PSCmdlet.ShouldProcess($actual, '递归删除 Codex Proxy 稳定安装目录')) {
        Remove-Item -LiteralPath $actual -Recurse -Force
        Write-Host "已删除安装目录：$actual"
    }
}

Write-Host '未卸载官方 Codex，也未修改系统代理。' -ForegroundColor Green
