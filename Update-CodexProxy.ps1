[CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
param(
    [ValidateRange(1, 65535)][int]$ProxyPort,
    [switch]$NoUI,
    [switch]$LaunchAfterUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$modulePath = Join-Path $projectRoot 'src\CodexProxy.Common.psm1'
$configPath = Join-Path $projectRoot 'CodexProxy.config.psd1'
$userConfigPath = Join-Path $projectRoot 'CodexProxy.user.psd1'
$launcherPath = Join-Path $projectRoot 'Start-CodexProxy.ps1'
$fallbackLogPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexProxy\logs\launcher.log'
$config = $null
$operationLock = $null
$temporaryDirectory = $null
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$result = $null
$exitCode = 0

try {
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw '请使用 Windows PowerShell 5.1 运行 Codex Proxy 更新模式。'
    }

    Import-Module -Name $modulePath -Force
    $configArguments = @{ Path=$configPath; UserPath=$userConfigPath }
    if ($PSBoundParameters.ContainsKey('ProxyPort')) { $configArguments.ProxyPortOverride = $ProxyPort }
    $config = Get-CodexProxyConfig @configArguments
    $operationLock = Enter-CodexProxyLaunchLock

    Write-CodexProxyLog -Path $config.LogFilePath -Message "请求通过 $($config.ProxyUrl) 运行更新模式。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
    $proxy = Test-CodexProxyEndpoint -Config $config
    if (-not $proxy.Ready) {
        $exception = New-Object System.InvalidOperationException($proxy.Message)
        $exception.Data['CodexProxyCode'] = $proxy.Code
        $exception.Data['CodexProxyRemediation'] = $proxy.Remediation
        throw $exception
    }

    $installedPackage = Get-CodexPackage -Config $config
    if (-not $installedPackage) {
        $exception = New-Object System.InvalidOperationException('未安装 OpenAI Codex Windows 应用。')
        $exception.Data['CodexProxyCode'] = 'CODEX_NOT_INSTALLED'
        $exception.Data['CodexProxyRemediation'] = '请先安装官方 ChatGPT/Codex Windows 应用。'
        throw $exception
    }
    $runningProcesses = @(Get-CodexPackageProcess -Package $installedPackage)
    if ($runningProcesses.Count -gt 0) {
        $exception = New-Object System.InvalidOperationException('Codex 当前仍在运行，更新模式不会强制结束任务。')
        $exception.Data['CodexProxyCode'] = 'UPDATE_CODEX_RUNNING'
        $exception.Data['CodexProxyRemediation'] = '请保存正在进行的任务，从系统托盘完全退出 Codex，然后重新双击“Codex-Proxy 更新”。'
        throw $exception
    }

    $updateUri = Get-CodexUpdateUri -Config $config -Architecture ([string]$installedPackage.Architecture)
    if (-not $PSCmdlet.ShouldProcess("OpenAI Codex $($installedPackage.Version)", '通过本地代理检查、下载并安装官方更新')) {
        $result = [pscustomobject]@{ Updated=$false; Skipped=$true; InstalledVersion=[version]$installedPackage.Version; CandidateVersion=$null; HelperCacheRefreshed=$false }
    }
    else {
        $reportedVersion = Get-CodexReportedUpdateVersion -Package $installedPackage
        $storeError = $null
        if ($reportedVersion -and $reportedVersion -gt [version]$installedPackage.Version) {
            Write-Host "Codex 已检测到 Store 版本 $reportedVersion，正在通过 winget Store 通道更新……" -ForegroundColor Cyan
            Write-CodexProxyLog -Path $config.LogFilePath -Message "桌面日志报告 Store 版本 $reportedVersion；优先使用 winget。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
            try {
                $updatedPackage = Invoke-CodexStoreUpdate -InstalledPackage $installedPackage -Config $config -ExpectedVersion $reportedVersion
                $applicationInfo = Get-CodexApplicationInfo -Package $updatedPackage -Config $config
                $helperInfo = Sync-CodexHelpers -ApplicationInfo $applicationInfo -Config $config
                $result = [pscustomobject]@{
                    Updated=$true; Skipped=$false; InstalledVersion=[version]$updatedPackage.Version
                    CandidateVersion=[version]$updatedPackage.Version; HelperCacheRefreshed=$helperInfo.Refreshed; Source='MicrosoftStore'
                }
                Write-CodexProxyLog -Path $config.LogFilePath -Message "Store 更新成功；version=$($updatedPackage.Version)；helper refreshed=$($helperInfo.Refreshed)。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
            }
            catch {
                $storeError = $_.Exception
                $storeInfo = Get-CodexProxyExceptionInfo -Exception $storeError
                Write-CodexProxyLog -Path $config.LogFilePath -Message "Store 通道失败，尝试官方稳定 MSIX：[$($storeInfo.Code)] $($storeInfo.Message)" -Level WARN -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
            }
        }

        if (-not $result) {
            $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
            $temporaryDirectory = Join-Path $temporaryBase ('CodexProxy\update-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
            $downloadPath = Join-Path $temporaryDirectory 'ChatGPT.msix'

            Write-Host "正在通过 $($config.ProxyUrl) 下载官方 $($installedPackage.Architecture) 稳定更新包……" -ForegroundColor Cyan
            Write-CodexProxyLog -Path $config.LogFilePath -Message "开始下载 $updateUri；installed=$($installedPackage.Version)。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
            $download = Save-CodexUpdatePackage -Uri $updateUri -DestinationPath $downloadPath -Config $config
            Write-CodexProxyLog -Path $config.LogFilePath -Message "更新包下载完成；bytes=$($download.Length)。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null

            Write-Host '正在验证数字签名、包身份、架构和版本……' -ForegroundColor Cyan
            $verified = Test-CodexUpdatePackage -Path $downloadPath -InstalledPackage $installedPackage -Config $config
            Write-CodexProxyLog -Path $config.LogFilePath -Message "更新包验证通过；candidate=$($verified.CandidateVersion)；sha256=$($verified.Sha256)。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null

            if (-not $verified.UpdateAvailable) {
                if ($storeError -and $reportedVersion -gt $verified.CandidateVersion) {
                    $storeInfo = Get-CodexProxyExceptionInfo -Exception $storeError
                    $exception = New-Object System.InvalidOperationException("Store 已分配 $reportedVersion，但 winget 更新失败；官方稳定 MSIX 仍为 $($verified.CandidateVersion)。$($storeInfo.Message)")
                    $exception.Data['CodexProxyCode'] = 'UPDATE_CHANNELS_UNAVAILABLE'
                    $exception.Data['CodexProxyRemediation'] = '请开启代理客户端的 TUN 模式后重试；稳定 MSIX 发布后，更新模式也会自动改用直链。'
                    throw $exception
                }
                $applicationInfo = Get-CodexApplicationInfo -Package $installedPackage -Config $config
                $helperInfo = Sync-CodexHelpers -ApplicationInfo $applicationInfo -Config $config
                $result = [pscustomobject]@{
                    Updated=$false; Skipped=$false; InstalledVersion=$verified.InstalledVersion
                    CandidateVersion=$verified.CandidateVersion; HelperCacheRefreshed=$helperInfo.Refreshed; Source='StableMsix'
                }
                Write-CodexProxyLog -Path $config.LogFilePath -Message "当前已是稳定 MSIX 最新版本 $($verified.InstalledVersion)；helper refreshed=$($helperInfo.Refreshed)。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
            }
            else {
                Write-Host "正在安装 Codex $($verified.CandidateVersion)……" -ForegroundColor Cyan
                Add-AppxPackage -Path $downloadPath -ErrorAction Stop

                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                $updatedPackage = $null
                do {
                    $updatedPackage = Get-CodexPackage -Config $config
                    if ($updatedPackage -and [version]$updatedPackage.Version -ge $verified.CandidateVersion) { break }
                    Start-Sleep -Milliseconds 500
                } while ([DateTime]::UtcNow -lt $deadline)
                if (-not $updatedPackage -or [version]$updatedPackage.Version -lt $verified.CandidateVersion) {
                    $exception = New-Object System.InvalidOperationException("安装命令已完成，但没有检测到目标版本 $($verified.CandidateVersion)。")
                    $exception.Data['CodexProxyCode'] = 'UPDATE_VERSION_NOT_APPLIED'
                    $exception.Data['CodexProxyRemediation'] = '请重启 Windows 后重新运行更新模式，并查看 launcher.log。'
                    throw $exception
                }

                $applicationInfo = Get-CodexApplicationInfo -Package $updatedPackage -Config $config
                $helperInfo = Sync-CodexHelpers -ApplicationInfo $applicationInfo -Config $config
                $result = [pscustomobject]@{
                    Updated=$true; Skipped=$false; InstalledVersion=[version]$updatedPackage.Version
                    CandidateVersion=$verified.CandidateVersion; HelperCacheRefreshed=$helperInfo.Refreshed; Source='StableMsix'
                }
                Write-CodexProxyLog -Path $config.LogFilePath -Message "MSIX 更新成功；version=$($updatedPackage.Version)；helper refreshed=$($helperInfo.Refreshed)。" -RunId $runId -MaxBytes $config.LogMaxBytes -Retention $config.LogRetention | Out-Null
            }
        }
    }

    if (-not $result.Skipped) {
        $message = if ($result.Updated) {
            "Codex 已更新到 $($result.InstalledVersion)，helper 缓存也已重新校验。"
        }
        else {
            "当前 Codex 已是最新官方版本 $($result.InstalledVersion)，helper 缓存已校验。"
        }
        Write-Host "[OK] $message" -ForegroundColor Green
        if (-not $NoUI) {
            Add-Type -AssemblyName PresentationFramework
            [System.Windows.MessageBox]::Show($message, 'Codex Proxy 更新完成', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        }
    }
}
catch {
    $exitCode = 1
    $logPath = if ($config) { $config.LogFilePath } else { $fallbackLogPath }
    $info = if (Get-Command Get-CodexProxyExceptionInfo -ErrorAction SilentlyContinue) {
        Get-CodexProxyExceptionInfo -Exception $_.Exception
    }
    else {
        [pscustomobject]@{ Code='UPDATE_ERROR'; Message=$_.Exception.Message; Remediation='请重新安装或修复 Codex Proxy。' }
    }
    if ($info.Code -eq 'UNEXPECTED_ERROR' -and -not $info.Remediation) {
        $info.Remediation = '请查看 launcher.log，并确认 Windows 的 AppX 部署服务可用。'
    }
    if (Get-Command Write-CodexProxyLog -ErrorAction SilentlyContinue) {
        Write-CodexProxyLog -Path $logPath -Message "[$($info.Code)] $($info.Message)；$($info.Remediation)" -Level ERROR -RunId $runId -MaxBytes $(if($config){$config.LogMaxBytes}else{1048576}) -Retention $(if($config){$config.LogRetention}else{3}) | Out-Null
    }
    if (-not $NoUI) {
        try { Show-CodexProxyError -Message $info.Message -Code $info.Code -Remediation $info.Remediation -LogPath $logPath -Title 'Codex Proxy 更新失败' } catch {}
    }
    else {
        [Console]::Error.WriteLine("[$($info.Code)] $($info.Message) $($info.Remediation)")
    }
}
finally {
    if ($temporaryDirectory -and (Test-Path -LiteralPath $temporaryDirectory -PathType Container)) {
        $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\CodexProxy\'
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryDirectory).TrimEnd('\') + '\'
        if ($resolvedTemporary.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($temporaryDirectory) -like 'update-*') {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($operationLock) {
        try { $operationLock.ReleaseMutex() } catch {}
        $operationLock.Dispose()
    }
}

if ($exitCode -eq 0 -and $LaunchAfterUpdate -and -not $result.Skipped) {
    $launchArguments = @{}
    if ($PSBoundParameters.ContainsKey('ProxyPort')) { $launchArguments.ProxyPort = $ProxyPort }
    if ($NoUI) { $launchArguments.NoUI = $true }
    & $launcherPath @launchArguments
    exit $LASTEXITCODE
}
exit $exitCode
