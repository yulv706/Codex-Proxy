[CmdletBinding()]
param([string]$OutputPath, [switch]$IncludeTests)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $PSScriptRoot 'bin\CodexProxy.exe' }
Import-Module (Join-Path $PSScriptRoot 'src\CodexProxy.Build.psm1') -Force
$icon = Join-Path $PSScriptRoot 'assets\codex-proxy.ico'
if (-not (Test-Path -LiteralPath $icon)) { & (Join-Path $PSScriptRoot 'Generate-CodexProxyIcon.ps1') -OutputPath $icon }
$sources = @('src\CodexProxy.App.cs','src\CodexProxy.Runtime.cs','src\CodexProxy.Applications.cs','src\CodexProxy.ApplicationEditor.cs','src\CodexProxy.State.cs','src\CodexProxy.ViewModel.cs','src\CodexProxy.MainWindow.cs','src\CodexProxy.Ui.cs')
$entryPoint = 'CodexProxyDesktop.Program'
if ($IncludeTests) { $sources += @('tests\DesktopTests.cs','tests\MultiApplicationTests.cs'); $entryPoint = 'CodexProxyDesktop.Tests.Program' }
Invoke-CodexProxyCompilation -ProjectRoot $PSScriptRoot -OutputPath $OutputPath -Sources $sources -Resources @('src\Desktop\Colors.Light.xaml','src\Desktop\Colors.Dark.xaml','src\Desktop\Theme.xaml','src\Desktop\MainWindow.xaml','src\Desktop\ApplicationEditor.xaml','assets\codex-proxy.ico') -EntryPoint $entryPoint
