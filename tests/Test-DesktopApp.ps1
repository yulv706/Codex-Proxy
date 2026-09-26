[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $projectRoot 'Build-CodexProxyApp.ps1'
$iconPath = Join-Path $projectRoot 'assets\codex-proxy.ico'
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-proxy-desktop-test-$([guid]::NewGuid().ToString('N'))"
$applicationPath = Join-Path $testRoot 'CodexProxy.exe'
$instanceSuffix = [guid]::NewGuid().ToString('N')
$process = $null

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    & $buildScript -OutputPath $applicationPath
    if (-not (Test-Path -LiteralPath $applicationPath -PathType Leaf)) { throw 'The desktop application was not built.' }
    if ((Get-Item -LiteralPath $applicationPath).VersionInfo.FileVersion -ne '3.5.8.0') { throw 'The desktop application file version is incorrect.' }
    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw 'The custom application icon was not generated.' }
    $iconBytes = [IO.File]::ReadAllBytes($iconPath)
    if ($iconBytes.Length -lt 4096 -or [BitConverter]::ToUInt16($iconBytes, 4) -lt 8) { throw 'The application icon does not contain the expected multi-size artwork.' }

    $uiSelfTest = Start-Process -FilePath $applicationPath -ArgumentList '--self-test-ui' -WorkingDirectory $testRoot -PassThru -Wait
    if ($uiSelfTest.ExitCode -ne 0) { throw 'The single-window navigation and embedded history UI self-test failed.' }
    $uiSelfTest.Dispose()

    $cleanupSelfTest = Start-Process -FilePath $applicationPath -ArgumentList @('--self-test-process-cleanup',"--instance-suffix=cleanup-$instanceSuffix") -WorkingDirectory $testRoot -PassThru
    if (-not $cleanupSelfTest.WaitForExit(7000)) {
        Stop-Process -Id $cleanupSelfTest.Id -Force -ErrorAction SilentlyContinue
        throw 'The runtime bridge did not cancel its outstanding PowerShell child process.'
    }
    if ($cleanupSelfTest.ExitCode -ne 0) { throw 'The runtime bridge process cleanup self-test failed.' }
    $cleanupSelfTest.Dispose()

    $shadowModuleRoot = Join-Path $testRoot 'polluted-powershell-modules'
    $shadowUtilityRoot = Join-Path $shadowModuleRoot 'Microsoft.PowerShell.Utility'
    New-Item -ItemType Directory -Path $shadowUtilityRoot -Force | Out-Null
    "@{ ModuleVersion='99.0.0'; RootModule='Missing.PowerShell7.dll'; PowerShellVersion='7.0' }" | Set-Content -LiteralPath (Join-Path $shadowUtilityRoot 'Microsoft.PowerShell.Utility.psd1') -Encoding UTF8
    $savedModulePath = $env:PSModulePath
    try {
        $env:PSModulePath = $shadowModuleRoot + [IO.Path]::PathSeparator + $savedModulePath
        $powerShellSelfTest = Start-Process -FilePath $applicationPath -ArgumentList '--self-test-powershell' -WorkingDirectory $testRoot -PassThru -Wait
        if ($powerShellSelfTest.ExitCode -ne 0) { throw 'The desktop bridge inherited an incompatible PowerShell module path.' }
        $powerShellSelfTest.Dispose()
    }
    finally {
        $env:PSModulePath = $savedModulePath
    }

    Import-Module -Name $modulePath -Force
    $shortcutPath = Join-Path $testRoot 'Codex Proxy.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $applicationPath
    $shortcut.Arguments = ''
    $shortcut.WorkingDirectory = $testRoot
    $shortcut.Save()
    $shortcutStatus = Test-CodexProxyAppShortcut -Path $shortcutPath -ApplicationPath $applicationPath
    if (-not $shortcutStatus.Ready -or -not $shortcutStatus.Owned) { throw 'The desktop application shortcut was not recognized.' }

    $process = Start-Process -FilePath $applicationPath -ArgumentList @('--background',"--instance-suffix=$instanceSuffix") -WorkingDirectory $testRoot -PassThru
    Start-Sleep -Seconds 2
    $process.Refresh()
    if ($process.HasExited) { throw 'The tray application exited instead of remaining in the background.' }

    $exitEvent = [Threading.EventWaitHandle]::OpenExisting("Local\CodexProxy.Tray.Exit.$instanceSuffix")
    try { $exitEvent.Set() | Out-Null } finally { $exitEvent.Dispose() }
    if (-not $process.WaitForExit(5000)) { throw 'The tray application did not respond to the graceful exit event.' }

    Write-Host 'PASS: native desktop build, application shortcut, background tray lifetime, and graceful shutdown.' -ForegroundColor Green
}
finally {
    if ($process) {
        $process.Refresh()
        if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $testRoot -PathType Container) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
