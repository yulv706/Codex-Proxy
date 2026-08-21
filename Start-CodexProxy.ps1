[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$ProxyPort,
    [switch]$NoUI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $projectRoot 'CodexProxy.config.psd1'
$userConfigPath = Join-Path $projectRoot 'CodexProxy.user.psd1'
$fallbackLogPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexProxy\logs\launcher.log'
$config = $null
$launchLock = $null
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)

try {
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw '请使用 Windows PowerShell 5.1 启动 Codex Proxy。'
    }

    Import-Module -Name $modulePath -Force
    $configArguments = @{ Path=$configPath; UserPath=$userConfigPath }
    if ($PSBoundParameters.ContainsKey('ProxyPort')) { $configArguments.ProxyPortOverride = $ProxyPort }
    $config = Get-CodexProxyConfig @configArguments
    $launchLock = Enter-CodexProxyLaunchLock

    Write-CodexProxyLog -Path $config.LogFilePath -Message "请求通过 $($config.ProxyUrl) 启动。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
    $status = Get-CodexProxyStatus -Config $config
    Write-CodexProxyLog -Path $config.LogFilePath -Message $status.Proxy.Message -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
    if (-not $status.ReadyNow) {
        $exception = New-Object System.InvalidOperationException($status.BlockingMessage)
        $exception.Data['CodexProxyCode'] = $status.BlockingCode
        $exception.Data['CodexProxyRemediation'] = $status.Remediation
        throw $exception
    }

    $automaticUpdate = Invoke-CodexAutomaticUpdate -InstalledPackage $status.Package -Config $config
    if ($automaticUpdate.Updated) {
        Write-CodexProxyLog -Path $config.LogFilePath -Message "自动更新成功：$($status.Package.Version) -> $($automaticUpdate.InstalledVersion)。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
        $status = Get-CodexProxyStatus -Config $config
        if (-not $status.ReadyNow) {
            $exception = New-Object System.InvalidOperationException($status.BlockingMessage)
            $exception.Data['CodexProxyCode'] = $status.BlockingCode
            $exception.Data['CodexProxyRemediation'] = $status.Remediation
            throw $exception
        }
    }
    elseif ($automaticUpdate.Attempted) {
        Write-CodexProxyLog -Path $config.LogFilePath -Message "自动更新暂未完成：target=$($automaticUpdate.TargetVersion)；[$($automaticUpdate.Code)] $($automaticUpdate.Message)；继续启动当前版本。" -Level WARN -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
    }
    elseif ($automaticUpdate.Reason -eq 'Cooldown') {
        Write-CodexProxyLog -Path $config.LogFilePath -Message "自动更新处于冷却期：target=$($automaticUpdate.TargetVersion)；retryAfter=$($automaticUpdate.RetryAfterUtc.ToString('o'))；继续启动当前版本。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
    }

    Write-CodexProxyLog -Path $config.LogFilePath -Message "使用 Codex 包 $($status.Package.Version)。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
    $helperInfo = Sync-CodexHelpers -ApplicationInfo $status.ApplicationInfo -Config $config
    Write-CodexProxyLog -Path $config.LogFilePath -Message "helper 缓存已验证：$($helperInfo.CacheDirectory)；refreshed=$($helperInfo.Refreshed)；files=$($helperInfo.FileCount)。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null

    $innerScript = New-CodexProxyInnerScript -ExecutablePath $status.ApplicationInfo.ExecutablePath -CodexCliPath $helperInfo.CliPath -ProxyUrl $config.ProxyUrl
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($innerScript))
    Invoke-CommandInDesktopPackage `
        -PackageFamilyName $status.Package.PackageFamilyName `
        -AppId $config.AppId `
        -Command 'powershell.exe' `
        -Args "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedCommand" `
        -PreventBreakaway

    $startedProcesses = @(Wait-CodexPackageProcess -Package $status.Package -TimeoutSeconds $config.LaunchTimeoutSeconds)
    if ($startedProcesses.Count -eq 0) {
        $exception = New-Object System.InvalidOperationException("启动命令已执行，但 $($config.LaunchTimeoutSeconds) 秒内未检测到 Codex 进程。")
        $exception.Data['CodexProxyCode'] = 'CODEX_START_TIMEOUT'
        $exception.Data['CodexProxyRemediation'] = '请打开日志并运行 Test-CodexProxy.ps1；如果问题持续，请修复或重新安装官方 Codex。'
        throw $exception
    }
    $processIds = ($startedProcesses | ForEach-Object ProcessId) -join ','
    Write-CodexProxyLog -Path $config.LogFilePath -Message "Codex 启动成功；PID=$processIds。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
}
catch {
    $logPath = if ($config) { $config.LogFilePath } else { $fallbackLogPath }
    $info = if (Get-Command Get-CodexProxyExceptionInfo -ErrorAction SilentlyContinue) {
        Get-CodexProxyExceptionInfo -Exception $_.Exception
    }
    else {
        [pscustomobject]@{ Code='STARTUP_ERROR'; Message=$_.Exception.Message; Remediation='请重新安装或修复 Codex Proxy。' }
    }
    if (Get-Command Write-CodexProxyLog -ErrorAction SilentlyContinue) {
        Write-CodexProxyLog -Path $logPath -Message "[$($info.Code)] $($info.Message)；$($info.Remediation)" -Level ERROR -RunId $runId -MaxBytes $(if($config){$config.LogMaxBytes}else{1048576}) -Retention $(if($config){$config.LogRetention}else{3}) | Out-Null
    }
    else {
        try {
            $logDirectory = Split-Path -Parent $logPath
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
            Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [ERROR] [$($info.Code)] $($info.Message)" -Encoding UTF8
        }
        catch {}
    }
    if (-not $NoUI) {
        try { Show-CodexProxyError -Message $info.Message -Code $info.Code -Remediation $info.Remediation -LogPath $logPath } catch {}
    }
    else {
        [Console]::Error.WriteLine("[$($info.Code)] $($info.Message) $($info.Remediation)")
    }
    exit 1
}
finally {
    if ($launchLock) {
        try { $launchLock.ReleaseMutex() } catch {}
        $launchLock.Dispose()
    }
}
