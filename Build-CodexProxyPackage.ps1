[CmdletBinding()]
param(
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'artifacts\CodexProxy-3.5.8' }
$out = [IO.Path]::GetFullPath($OutputDirectory)
if ([IO.Path]::GetFullPath($out).StartsWith(([IO.Path]::GetFullPath((Join-Path $root 'artifacts'))).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -eq $false) {
    throw '安装包输出目录必须位于项目 artifacts 目录内。'
}
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null
$bin = Join-Path $out 'bin'
& (Join-Path $root 'Build-CodexProxyApp.ps1') -OutputPath (Join-Path $bin 'CodexProxy.exe')
& (Join-Path $root 'Build-CodexProxyInstaller.ps1') -OutputPath (Join-Path $out 'CodexProxySetup.exe')
$files = @(
    'Start-CodexProxy.ps1','Test-CodexProxy.ps1','HistorySync.ps1','Install-CodexProxy.ps1','Detect-CodexProxyInstallation.ps1','Build-CodexProxyApp.ps1','Build-CodexProxyInstaller.ps1','Build-CodexProxyPackage.ps1',
    'Generate-CodexProxyIcon.ps1','Uninstall-CodexProxy.ps1','Repair-CodexHistory.ps1','CodexProxy.config.psd1','README.md',
    'src\CodexProxy.Common.psm1','src\CodexProxy.Installation.psm1','src\CodexProxy.App.cs','src\CodexProxy.Ui.cs','src\CodexProxy.MainWindow.cs','src\CodexProxy.Setup.cs',
    'assets\codex-proxy.ico','docs\history-sync-design.md'
)
foreach ($relative in $files) {
    $source = Join-Path $root $relative
    $destination = Join-Path $out $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "缺少安装包文件：$source" }
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $destination -Force
}
$manifest = Get-ChildItem -LiteralPath $out -File -Recurse | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{ Path=$_.FullName.Substring($out.Length).TrimStart('\').Replace('\','/'); Size=$_.Length; Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'package-manifest.json') -Encoding UTF8
$zip = $out.TrimEnd('\') + '.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -CompressionLevel Optimal
Write-Host "安装包目录：$out" -ForegroundColor Green
Write-Host "安装包压缩文件：$zip" -ForegroundColor Green
