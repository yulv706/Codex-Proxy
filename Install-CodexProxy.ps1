[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $projectRoot 'CodexProxy.config.psd1'
$launcherPath = Join-Path $projectRoot 'Start-CodexProxy.ps1'
$iconPath = Join-Path $projectRoot 'assets\codex-official-transparent.ico'

Import-Module -Name $modulePath -Force
$config = Get-CodexProxyConfig -Path $configPath

foreach ($requiredPath in @($launcherPath, $iconPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required project file was not found: $requiredPath"
    }
}

$desktopPath = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopPath $config.ShortcutName
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoLogo -NoProfile -File "{0}"' -f $launcherPath

if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
    $shell = New-Object -ComObject WScript.Shell
    $existing = $shell.CreateShortcut($shortcutPath)
    if ($existing.Arguments -ne $arguments -or $existing.TargetPath -ne $powershellPath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = "$shortcutPath.before-project-$stamp.bak"
        Copy-Item -LiteralPath $shortcutPath -Destination $backupPath
        Write-Host "Existing shortcut backed up to: $backupPath"
    }
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $env:USERPROFILE
$shortcut.IconLocation = "$iconPath,0"
$shortcut.Description = $config.ShortcutDescription
$shortcut.WindowStyle = 1
$shortcut.Save()

$verified = $shell.CreateShortcut($shortcutPath)
if ($verified.TargetPath -ne $powershellPath -or $verified.Arguments -ne $arguments) {
    throw "Shortcut verification failed: $shortcutPath"
}

Write-Host "Codex Proxy shortcut installed: $shortcutPath"
Write-Host 'No user-level or machine-level proxy environment variables were changed.'
