[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $projectRoot 'CodexProxy.config.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "codex-proxy-config-test-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Import-Module -Name $modulePath -Force

    $defaultConfig = Get-CodexProxyConfig -Path $configPath
    if ($defaultConfig.ProxyPort -ne 7891) { throw 'The default proxy port must remain 7891.' }

    $userPath = Join-Path $testRoot 'CodexProxy.user.psd1'
    Set-Content -LiteralPath $userPath -Encoding UTF8 -Value "@{`r`n    ProxyPort = 8123`r`n}"
    $userConfig = Get-CodexProxyConfig -Path $configPath -UserPath $userPath
    if ($userConfig.ProxyPort -ne 8123) { throw 'The user proxy port override was ignored.' }

    $commandConfig = Get-CodexProxyConfig -Path $configPath -UserPath $userPath -ProxyPortOverride 9001
    if ($commandConfig.ProxyPort -ne 9001) { throw 'The command-line proxy port must win over user configuration.' }

    Set-Content -LiteralPath $userPath -Encoding UTF8 -Value "@{`r`n    ProxyPort = 70000`r`n}"
    try {
        Get-CodexProxyConfig -Path $configPath -UserPath $userPath | Out-Null
        throw 'An invalid user proxy port should fail validation.'
    }
    catch {
        if ($_.Exception.Message -eq 'An invalid user proxy port should fail validation.') { throw }
        if ($_.Exception.Data['CodexProxyCode'] -ne 'PROXY_PORT_INVALID') { throw "Unexpected invalid-port error: $($_.Exception.Message)" }
    }

    $badConfigPath = Join-Path $testRoot 'Bad.config.psd1'
    $badConfigText = (Get-Content -LiteralPath $configPath -Raw).Replace("HelperCachePath            = 'OpenAI\Codex\bin\codex-proxy-current'", "HelperCachePath            = '..\escape'")
    Set-Content -LiteralPath $badConfigPath -Encoding UTF8 -Value $badConfigText
    try {
        Get-CodexProxyConfig -Path $badConfigPath | Out-Null
        throw 'A cache path escape should fail validation.'
    }
    catch {
        if ($_.Exception.Message -eq 'A cache path escape should fail validation.') { throw }
        if ($_.Exception.Data['CodexProxyCode'] -ne 'CONFIG_PATH_ESCAPE') { throw "Unexpected path-validation error: $($_.Exception.Message)" }
    }

    $innerScript = New-CodexProxyInnerScript -ExecutablePath 'C:\Program Files\Codex\Codex.exe' -CodexCliPath 'C:\Cache Path\codex.exe' -ProxyUrl 'http://127.0.0.1:9001'
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseInput($innerScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -ne 0) { throw "The generated launch script is invalid: $($parseErrors.Message -join '; ')" }
    if ($innerScript -notmatch 'mergedNoProxy' -or $innerScript -notmatch '127\.0\.0\.1:9001') { throw 'The launch script does not merge NO_PROXY or apply the requested proxy port.' }

    $firstLock = Enter-CodexProxyLaunchLock
    $lockJob = $null
    try {
        $lockJob = Start-Job -ArgumentList $modulePath -ScriptBlock {
            param($ImportedModulePath)
            Import-Module -Name $ImportedModulePath -Force
            try {
                $lock = Enter-CodexProxyLaunchLock
                try { 'LOCK_ACQUIRED' } finally { $lock.ReleaseMutex(); $lock.Dispose() }
            }
            catch {
                [string]$_.Exception.Data['CodexProxyCode']
            }
        }
        Wait-Job -Job $lockJob -Timeout 10 | Out-Null
        $lockResult = @(Receive-Job -Job $lockJob)
        if ($lockResult -notcontains 'LAUNCH_ALREADY_IN_PROGRESS') { throw "A concurrent process was not rejected: $($lockResult -join ',')" }
    }
    finally {
        if ($lockJob) { Remove-Job -Job $lockJob -Force -ErrorAction SilentlyContinue }
        $firstLock.ReleaseMutex()
        $firstLock.Dispose()
    }

    $unusedListener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $unusedListener.Start()
    $unusedPort = ([Net.IPEndPoint]$unusedListener.LocalEndpoint).Port
    $unusedListener.Stop()
    $probeConfig = [pscustomobject]@{ ProxyHost='127.0.0.1'; ProxyPort=$unusedPort; ProxyProbeHost='api.openai.com'; ProxyProbePort=443; ProxyConnectTimeoutSeconds=1 }
    $probe = Test-CodexProxyEndpoint -Config $probeConfig
    if ($probe.Ready -or $probe.Code -ne 'PROXY_NOT_LISTENING') { throw 'A closed local port should be classified as PROXY_NOT_LISTENING.' }

    $logPath = Join-Path $testRoot 'logs\launcher.log'
    Write-CodexProxyLog -Path $logPath -Message ('x' * 256) -MaxBytes 64 -Retention 2 | Out-Null
    Write-CodexProxyLog -Path $logPath -Message 'rotate' -MaxBytes 64 -Retention 2 | Out-Null
    if (-not (Test-Path -LiteralPath "$logPath.1" -PathType Leaf)) { throw 'Log rotation did not preserve the previous log.' }

    $shortcutArgs = Get-CodexProxyShortcutArguments -LauncherPath 'C:\Path With Spaces\Start-CodexProxy.ps1'
    if ($shortcutArgs -ne '-NoLogo -NoProfile -File "C:\Path With Spaces\Start-CodexProxy.ps1"') { throw 'Shortcut arguments are not quoted deterministically.' }

    Write-Host 'PASS: configuration precedence, validation, script generation, locking, health classification, and log rotation.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
