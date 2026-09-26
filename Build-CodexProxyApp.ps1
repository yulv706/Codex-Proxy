[CmdletBinding()]
param(
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $PSScriptRoot 'bin\CodexProxy.exe' }

$sourcePath = Join-Path $PSScriptRoot 'src\CodexProxy.App.cs'
$mainWindowSourcePath = Join-Path $PSScriptRoot 'src\CodexProxy.MainWindow.cs'
$uiSourcePath = Join-Path $PSScriptRoot 'src\CodexProxy.Ui.cs'
$iconPath = Join-Path $PSScriptRoot 'assets\codex-proxy.ico'
$iconGeneratorPath = Join-Path $PSScriptRoot 'Generate-CodexProxyIcon.ps1'
$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compilerPath = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

if (-not $compilerPath) { throw 'The .NET Framework C# compiler (csc.exe) was not found.' }
if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Application source file not found: $sourcePath" }
if (-not (Test-Path -LiteralPath $mainWindowSourcePath -PathType Leaf)) { throw "Application source file not found: $mainWindowSourcePath" }
if (-not (Test-Path -LiteralPath $uiSourcePath -PathType Leaf)) { throw "Application source file not found: $uiSourcePath" }
if (-not (Test-Path -LiteralPath $iconGeneratorPath -PathType Leaf)) { throw "Application icon generator not found: $iconGeneratorPath" }
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf) -or (Get-Item -LiteralPath $iconGeneratorPath).LastWriteTimeUtc -gt (Get-Item -LiteralPath $iconPath).LastWriteTimeUtc) {
    & $iconGeneratorPath -OutputPath $iconPath
}
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw "Application icon not found: $iconPath" }

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$temporaryPath = Join-Path $outputDirectory ('.CodexProxy.build-' + [guid]::NewGuid().ToString('N') + '.exe')

try {
    $arguments = @(
        '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/utf8output',
        "/win32icon:$iconPath", "/out:$temporaryPath",
        '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Drawing.dll',
        '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll',
        $sourcePath, $uiSourcePath, $mainWindowSourcePath
    )
    & $compilerPath $arguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
        throw "Codex Proxy application compilation failed with exit code $LASTEXITCODE."
    }
    Move-Item -LiteralPath $temporaryPath -Destination $outputFullPath -Force
    Write-Host "Built Windows application: $outputFullPath" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
}
