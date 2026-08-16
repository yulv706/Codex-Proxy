[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $projectRoot 'CodexProxy.config.psd1'
$launcherPath = Join-Path $projectRoot 'Start-CodexProxy.ps1'

Import-Module -Name $modulePath -Force
$config = Get-CodexProxyConfig -Path $configPath
$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath $config.ShortcutName

if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
    Write-Host "Shortcut is already absent: $shortcutPath"
    return
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
if ($shortcut.Arguments.IndexOf($launcherPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'The desktop shortcut does not belong to this project, so it was not removed.'
}

Remove-Item -LiteralPath $shortcutPath -Force
Write-Host "Codex Proxy shortcut removed: $shortcutPath"
Write-Host 'The project, Codex application, proxy client, and helper cache were not removed.'
