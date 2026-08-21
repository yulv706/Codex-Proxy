[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 65535)][int]$ProxyPort = 7891,
    [switch]$Portable,
    [switch]$ForceShortcutReplacement
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$productVersion = '2.1.0'
$sourceRoot = $PSScriptRoot
$sourceModulePath = Join-Path $sourceRoot 'src\CodexProxy.Common.psm1'
$sourceConfigPath = Join-Path $sourceRoot 'CodexProxy.config.psd1'
Import-Module -Name $sourceModulePath -Force
$config = Get-CodexProxyConfig -Path $sourceConfigPath -ProxyPortOverride $ProxyPort
$installRoot = if ($Portable) { $sourceRoot } else { $config.InstallDirectory }

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
    New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    foreach ($relativePath in @(
        'Start-CodexProxy.ps1', 'Update-CodexProxy.ps1', 'Test-CodexProxy.ps1', 'Install-CodexProxy.ps1',
        'Uninstall-CodexProxy.ps1', 'CodexProxy.config.psd1', 'README.md',
        'src\CodexProxy.Common.psm1', 'assets\codex-official-transparent.ico'
    )) {
        Copy-ProductFile -RelativePath $relativePath
    }

    $userConfigPath = Join-Path $installRoot 'CodexProxy.user.psd1'
    $userConfigTemporary = "$userConfigPath.installing-$([guid]::NewGuid().ToString('N')).tmp"
    "@{`r`n    ProxyPort = $ProxyPort`r`n}`r`n" | Set-Content -LiteralPath $userConfigTemporary -Encoding UTF8
    Move-Item -LiteralPath $userConfigTemporary -Destination $userConfigPath -Force

    $launcherPath = Join-Path $installRoot 'Start-CodexProxy.ps1'
    $updateLauncherPath = Join-Path $installRoot 'Update-CodexProxy.ps1'
    $iconPath = Join-Path $installRoot 'assets\codex-official-transparent.ico'
    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktopPath $config.ShortcutName
    $updateShortcutPath = Join-Path $desktopPath $config.UpdateShortcutName
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = Get-CodexProxyShortcutArguments -LauncherPath $launcherPath
    $previousStatePath = Join-Path $installRoot 'install-state.json'
    $previousState = if (Test-Path -LiteralPath $previousStatePath -PathType Leaf) { Get-Content -LiteralPath $previousStatePath -Raw | ConvertFrom-Json } else { $null }
    $backupPath = if ($previousState -and $previousState.PSObject.Properties.Name -contains 'ReplacedShortcut' -and $previousState.ReplacedShortcut) { [string]$previousState.ReplacedShortcut } else { $null }
    $updateBackupPath = if ($previousState -and $previousState.PSObject.Properties.Name -contains 'ReplacedUpdateShortcut' -and $previousState.ReplacedUpdateShortcut) { [string]$previousState.ReplacedUpdateShortcut } else { $null }

    if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
        $existingStatus = Test-CodexProxyShortcut -Path $shortcutPath -LauncherPath $launcherPath
        if (-not $existingStatus.Ready -and -not $existingStatus.Owned -and -not $ForceShortcutReplacement) {
            throw "桌面上存在同名但不属于 Codex Proxy 的快捷方式。若确定要替换，请重新运行并添加 -ForceShortcutReplacement：$shortcutPath"
        }
        if (-not $existingStatus.Ready -and -not $existingStatus.Owned) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backupPath = "$shortcutPath.before-codex-proxy-$stamp.bak"
            Copy-Item -LiteralPath $shortcutPath -Destination $backupPath
        }
    }

    if (Test-Path -LiteralPath $updateShortcutPath -PathType Leaf) {
        $existingUpdateStatus = Test-CodexProxyShortcut -Path $updateShortcutPath -LauncherPath $updateLauncherPath
        if (-not $existingUpdateStatus.Ready -and -not $existingUpdateStatus.Owned -and -not $ForceShortcutReplacement) {
            throw "桌面上存在同名但不属于 Codex Proxy 的更新快捷方式。若确定要替换，请重新运行并添加 -ForceShortcutReplacement：$updateShortcutPath"
        }
        if (-not $existingUpdateStatus.Ready -and -not $existingUpdateStatus.Owned) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $updateBackupPath = "$updateShortcutPath.before-codex-proxy-$stamp.bak"
            Copy-Item -LiteralPath $updateShortcutPath -Destination $updateBackupPath
        }
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powershellPath
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
    $shortcut.IconLocation = "$iconPath,0"
    $shortcut.Description = "$($config.ShortcutDescription)（端口 $ProxyPort）"
    $shortcut.WindowStyle = 1
    $shortcut.Save()

    $updateShortcut = $shell.CreateShortcut($updateShortcutPath)
    $updateShortcut.TargetPath = $powershellPath
    $updateShortcut.Arguments = Get-CodexProxyShortcutArguments -LauncherPath $updateLauncherPath
    $updateShortcut.WorkingDirectory = [Environment]::GetFolderPath('UserProfile')
    $updateShortcut.IconLocation = "$iconPath,0"
    $updateShortcut.Description = "通过本地代理安全更新 OpenAI Codex（端口 $ProxyPort）"
    $updateShortcut.WindowStyle = 1
    $updateShortcut.Save()

    $verification = Test-CodexProxyShortcut -Path $shortcutPath -LauncherPath $launcherPath
    if (-not $verification.Ready) { throw "快捷方式校验失败：$shortcutPath" }
    $updateVerification = Test-CodexProxyShortcut -Path $updateShortcutPath -LauncherPath $updateLauncherPath
    if (-not $updateVerification.Ready) { throw "更新快捷方式校验失败：$updateShortcutPath" }

    $statePath = Join-Path $installRoot 'install-state.json'
    [pscustomobject]@{
        SchemaVersion       = 2
        ProductVersion      = $productVersion
        InstallMode         = if ($Portable) { 'Portable' } else { 'LocalAppData' }
        InstallRoot         = $installRoot
        LauncherPath        = $launcherPath
        UpdateLauncherPath  = $updateLauncherPath
        ShortcutPath        = $shortcutPath
        UpdateShortcutPath  = $updateShortcutPath
        ReplacedShortcut    = $backupPath
        ReplacedUpdateShortcut = $updateBackupPath
        ProxyPort           = $ProxyPort
        InstalledAtUtc      = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8

    Write-Host "Codex Proxy $productVersion 已安装：$installRoot" -ForegroundColor Green
    Write-Host "桌面快捷方式：$shortcutPath"
    Write-Host "桌面更新入口：$updateShortcutPath"
    Write-Host "代理地址：http://127.0.0.1:$ProxyPort"
    Write-Host '未修改用户级、机器级或系统代理设置。'
    Write-Host "如需检查状态：powershell.exe -NoLogo -NoProfile -File `"$(Join-Path $installRoot 'Test-CodexProxy.ps1')`""
}
