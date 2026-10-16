[CmdletBinding()]
param([string]$OutputPath, [switch]$IncludeTests)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $PSScriptRoot 'bin\CodexProxySetup.exe' }
Import-Module (Join-Path $PSScriptRoot 'src\CodexProxy.Build.psm1') -Force
$sources = @('src\CodexProxy.Setup.cs','src\CodexProxy.Runtime.cs','src\CodexProxy.Applications.cs','src\CodexProxy.State.cs','src\CodexProxy.Ui.cs')
$entryPoint = 'CodexProxySetup.Program'
if ($IncludeTests) { $sources += 'tests\SetupTests.cs'; $entryPoint = 'CodexProxySetup.Tests.Program' }
Invoke-CodexProxyCompilation -ProjectRoot $PSScriptRoot -OutputPath $OutputPath -Sources $sources -Resources @('src\Desktop\Colors.Light.xaml','src\Desktop\Colors.Dark.xaml','src\Desktop\Theme.xaml','src\Desktop\SetupWindow.xaml','assets\codex-proxy.ico') -EntryPoint $entryPoint
