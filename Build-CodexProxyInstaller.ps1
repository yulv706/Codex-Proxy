[CmdletBinding()]
param([string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $PSScriptRoot 'bin\CodexProxySetup.exe' }
$source = Join-Path $PSScriptRoot 'src\CodexProxy.Setup.cs'
$icon = Join-Path $PSScriptRoot 'assets\codex-proxy.ico'
$compiler = @((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),(Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) { throw 'The .NET Framework C# compiler (csc.exe) was not found.' }
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Setup source file not found: $source" }
$out = [IO.Path]::GetFullPath($OutputPath); $dir = Split-Path -Parent $out; New-Item -ItemType Directory -Path $dir -Force | Out-Null
$temp = Join-Path $dir ('.CodexProxySetup.build-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    $args = @('/nologo','/target:winexe','/platform:anycpu','/optimize+','/utf8output',"/win32icon:$icon","/out:$temp",'/reference:System.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Core.dll','/reference:System.Web.Extensions.dll',$source)
    & $compiler $args
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temp -PathType Leaf)) { throw "Setup compilation failed with exit code $LASTEXITCODE." }
    Move-Item -LiteralPath $temp -Destination $out -Force
    Write-Host "Built setup wizard: $out" -ForegroundColor Green
}
finally { if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
