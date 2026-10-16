[CmdletBinding()]
param(
    [string]$OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $root 'artifacts\CodexProxy-4.1.0' }
$out = [IO.Path]::GetFullPath($OutputDirectory)
if ([IO.Path]::GetFullPath($out).StartsWith(([IO.Path]::GetFullPath((Join-Path $root 'artifacts'))).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -eq $false) {
    throw '安装包输出目录必须位于项目 artifacts 目录内。'
}
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null
$bin = Join-Path $out 'bin'
& (Join-Path $root 'Build-CodexProxyApp.ps1') -OutputPath (Join-Path $bin 'CodexProxy.exe')
& (Join-Path $root 'Build-CodexProxyInstaller.ps1') -OutputPath (Join-Path $out 'CodexProxySetup.exe')
$files = (Import-PowerShellDataFile -LiteralPath (Join-Path $root 'CodexProxy.files.psd1')).Files
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
