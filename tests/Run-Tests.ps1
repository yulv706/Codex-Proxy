[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$failed = $false

Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1','.psd1') } | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $failed = $true
        Write-Host "FAIL syntax: $($_.FullName)" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "  $($_.Message)" }
    }
}

foreach ($testFile in Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter 'Test-*.ps1' | Sort-Object Name) {
    Write-Host "RUN: $($testFile.Name)" -ForegroundColor Cyan
    & powershell.exe -NoLogo -NoProfile -File $testFile.FullName
    if ($LASTEXITCODE -ne 0) {
        $failed = $true
        Write-Host "FAIL: $($testFile.Name) (exit $LASTEXITCODE)" -ForegroundColor Red
    }
}

if ($failed) { throw 'One or more Codex Proxy tests failed.' }
Write-Host 'PASS: all Codex Proxy tests.' -ForegroundColor Green
