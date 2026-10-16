[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $projectRoot 'artifacts\desktop-4.1.0-preview'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$fixture = Join-Path $outputDirectory 'DesktopTests.exe'
& (Join-Path $projectRoot 'Build-CodexProxyApp.ps1') -OutputPath $fixture -IncludeTests
$process = Start-Process -WindowStyle Hidden -FilePath $fixture -ArgumentList ('"' + $outputDirectory + '"') -PassThru
try {
    if (-not $process.WaitForExit(60000)) { Stop-Process -Id $process.Id -Force; throw 'Desktop fixtures timed out.' }
    if ($process.ExitCode -ne 0) { throw (Get-Content -LiteralPath (Join-Path $outputDirectory 'error.txt') -Raw) }
    Get-Content -LiteralPath (Join-Path $outputDirectory 'result.txt')
}
finally { $process.Dispose() }
