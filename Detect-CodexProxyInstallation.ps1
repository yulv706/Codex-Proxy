[CmdletBinding()]
param([switch]$AsJson)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src\CodexProxy.Installation.psm1'
Import-Module -Name $modulePath -Force
$result = Resolve-CodexProxyInstallation
if ($AsJson) {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $result | ConvertTo-Json -Depth 5 -Compress
}
else {
    $result
}
