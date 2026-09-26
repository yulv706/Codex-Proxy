[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-proxy-layout-test-" + [guid]::NewGuid().ToString('N'))
$compiler = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) { throw 'The .NET Framework C# compiler was not found.' }

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $previewPath = Join-Path $testRoot 'LayoutPreview.exe'
    $sources = @('src\CodexProxy.App.cs', 'src\CodexProxy.Ui.cs', 'src\CodexProxy.MainWindow.cs', 'tests\LayoutPreview.cs') | ForEach-Object { Join-Path $projectRoot $_ }
    & $compiler @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/utf8output', "/out:$previewPath", '/reference:System.dll', '/reference:System.Core.dll', '/reference:System.Drawing.dll', '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll', '/main:LayoutPreview.Program') $sources
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $previewPath -PathType Leaf)) { throw 'The visual layout fixture did not compile.' }
    $process = Start-Process -FilePath $previewPath -ArgumentList ('"' + $testRoot + '"') -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "The visual layout fixture failed with exit code $($process.ExitCode)." }
    foreach ($name in @('overview', 'settings', 'sessions', 'sync')) {
        foreach ($prefix in @('', 'compact-')) {
            $imagePath = Join-Path $testRoot ($prefix + $name + '.png')
            if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf) -or (Get-Item -LiteralPath $imagePath).Length -lt 1000) {
                throw "A rendered page is missing: $prefix$name"
            }
        }
    }
    Write-Host 'PASS: all four pages render at normal and compact sizes, text fits, and settings has no horizontal overflow.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
