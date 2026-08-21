Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-CodexProxyException {
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message, [string]$Remediation = '')
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['CodexProxyCode'] = $Code
    $exception.Data['CodexProxyRemediation'] = $Remediation
    $exception
}

function Get-CodexProxyExceptionInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Exception]$Exception)
    $code = if ($Exception.Data.Contains('CodexProxyCode')) { [string]$Exception.Data['CodexProxyCode'] } else { 'UNEXPECTED_ERROR' }
    $remediation = if ($Exception.Data.Contains('CodexProxyRemediation')) { [string]$Exception.Data['CodexProxyRemediation'] } else { '请运行 Test-CodexProxy.ps1 获取完整诊断信息。' }
    [pscustomobject]@{ Code=$code; Message=$Exception.Message; Remediation=$remediation }
}

function Get-MapValue {
    param([Parameter(Mandatory)]$Map, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($Map -is [System.Collections.IDictionary] -and $Map.Contains($Name)) { return $Map[$Name] }
    if ($Map.PSObject.Properties.Name -contains $Name) { return $Map.$Name }
    $Default
}

function Resolve-CodexProxyChildPath {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][string]$SettingName)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw (New-CodexProxyException -Code 'CONFIG_PATH_INVALID' -Message "$SettingName 必须是非空相对路径。" -Remediation '请恢复默认配置后重试。')
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    if (-not $candidate.StartsWith("$rootFull\", [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-CodexProxyException -Code 'CONFIG_PATH_ESCAPE' -Message "$SettingName 超出了允许目录：$RelativePath" -Remediation '请使用不包含 .. 的相对路径。')
    }
    $candidate
}

function Get-CodexProxyConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$UserPath, [int]$ProxyPortOverride)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-CodexProxyException -Code 'CONFIG_NOT_FOUND' -Message "找不到配置文件：$Path" -Remediation '请重新安装或修复 Codex Proxy。')
    }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    foreach ($name in @('SchemaVersion','ProxyHost','ProxyPort','ProxyProbeHost','ProxyProbePort','ProxyConnectTimeoutSeconds','LaunchTimeoutSeconds','PackageName','ExpectedPublisherId','AppId','ShortcutName','ShortcutDescription','InstallPath','HelperCachePath','LogPath','LogMaxBytes','LogRetention','RequireValidSignatures','UpdateStoreProductId','UpdateAttemptTimeoutSeconds','UpdateRetryCooldownMinutes','UpdateStatePath')) {
        if (-not $data.ContainsKey($name)) {
            throw (New-CodexProxyException -Code 'CONFIG_KEY_MISSING' -Message "配置缺少必需项：$name" -Remediation '请使用当前版本的 CodexProxy.config.psd1。')
        }
    }
    if ($UserPath -and (Test-Path -LiteralPath $UserPath -PathType Leaf)) {
        $userData = Import-PowerShellDataFile -LiteralPath $UserPath
        foreach ($name in @('ProxyHost','ProxyPort')) { if ($userData.ContainsKey($name)) { $data[$name] = $userData[$name] } }
    }
    if ($PSBoundParameters.ContainsKey('ProxyPortOverride')) { $data.ProxyPort = $ProxyPortOverride }

    $hostName = ([string]$data.ProxyHost).Trim()
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        throw (New-CodexProxyException -Code 'PROXY_HOST_INVALID' -Message 'ProxyHost 不能为空。' -Remediation '本地代理请使用 127.0.0.1 或 localhost。')
    }
    $parsedAddress = $null
    $isIpAddress = [Net.IPAddress]::TryParse($hostName, [ref]$parsedAddress)
    if (($isIpAddress -and -not [Net.IPAddress]::IsLoopback($parsedAddress)) -or (-not $isIpAddress -and $hostName -ne 'localhost')) {
        throw (New-CodexProxyException -Code 'PROXY_HOST_NOT_LOOPBACK' -Message "为避免意外暴露流量，ProxyHost 仅支持本机回环地址：$hostName" -Remediation '请将本地代理监听地址设为 127.0.0.1。')
    }
    $port = [int]$data.ProxyPort
    if ($port -lt 1 -or $port -gt 65535) {
        throw (New-CodexProxyException -Code 'PROXY_PORT_INVALID' -Message "代理端口必须在 1 到 65535 之间：$port" -Remediation '安装时使用 -ProxyPort 指定有效端口；未指定时默认为 7891。')
    }
    $probePort = [int]$data.ProxyProbePort
    if ($probePort -lt 1 -or $probePort -gt 65535) {
        throw (New-CodexProxyException -Code 'PROXY_PROBE_PORT_INVALID' -Message "代理探测端口无效：$probePort" -Remediation '请恢复默认配置。')
    }
    $shortcutName = [string]$data.ShortcutName
    if ([IO.Path]::GetFileName($shortcutName) -ne $shortcutName -or -not $shortcutName.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-CodexProxyException -Code 'SHORTCUT_NAME_INVALID' -Message "ShortcutName 必须是不含目录的 .lnk 文件名：$shortcutName" -Remediation '请恢复默认快捷方式名称。')
    }
    $storeProductId = ([string]$data.UpdateStoreProductId).Trim().ToUpperInvariant()
    if ($storeProductId -notmatch '^[A-Z0-9]{12}$') {
        throw (New-CodexProxyException -Code 'UPDATE_STORE_ID_INVALID' -Message "UpdateStoreProductId 格式无效：$storeProductId" -Remediation '请恢复默认 Microsoft Store 产品 ID。')
    }
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $installDirectory = Resolve-CodexProxyChildPath -Root $localAppData -RelativePath ([string]$data.InstallPath) -SettingName 'InstallPath'
    $helperCacheDirectory = Resolve-CodexProxyChildPath -Root $localAppData -RelativePath ([string]$data.HelperCachePath) -SettingName 'HelperCachePath'
    $logFilePath = Resolve-CodexProxyChildPath -Root $localAppData -RelativePath ([string]$data.LogPath) -SettingName 'LogPath'
    $updateStateFilePath = Resolve-CodexProxyChildPath -Root $localAppData -RelativePath ([string]$data.UpdateStatePath) -SettingName 'UpdateStatePath'
    $uriBuilder = New-Object UriBuilder('http', $hostName, $port)
    [pscustomobject]@{
        SchemaVersion=[int]$data.SchemaVersion; ProxyHost=$hostName; ProxyPort=$port; ProxyUrl=$uriBuilder.Uri.AbsoluteUri.TrimEnd('/')
        ProxyProbeHost=[string]$data.ProxyProbeHost; ProxyProbePort=$probePort
        ProxyConnectTimeoutSeconds=[Math]::Max(1,[int]$data.ProxyConnectTimeoutSeconds); LaunchTimeoutSeconds=[Math]::Max(1,[int]$data.LaunchTimeoutSeconds)
        PackageName=[string]$data.PackageName; ExpectedPublisherId=[string]$data.ExpectedPublisherId; AppId=[string]$data.AppId
        ShortcutName=$shortcutName; ShortcutDescription=[string]$data.ShortcutDescription; InstallDirectory=$installDirectory
        HelperCacheDirectory=$helperCacheDirectory; LogFilePath=$logFilePath; LogMaxBytes=[Math]::Max(65536,[long]$data.LogMaxBytes)
        LogRetention=[Math]::Max(1,[int]$data.LogRetention); RequireValidSignatures=[bool]$data.RequireValidSignatures
        UpdateStoreProductId=$storeProductId; UpdateAttemptTimeoutSeconds=[Math]::Max(30,[int]$data.UpdateAttemptTimeoutSeconds)
        UpdateRetryCooldownMinutes=[Math]::Max(5,[int]$data.UpdateRetryCooldownMinutes); UpdateStateFilePath=$updateStateFilePath
        UserConfigPath=if ($UserPath) { $UserPath } else { $null }
    }
}

function Write-CodexProxyLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Message, [ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO', [long]$MaxBytes=1048576, [int]$Retention=3, [string]$RunId='')
    try {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        if ((Test-Path -LiteralPath $Path -PathType Leaf) -and (Get-Item -LiteralPath $Path).Length -ge $MaxBytes) {
            for ($index=$Retention-1; $index -ge 1; $index--) {
                $source="$Path.$index"; $destination="$Path.$($index+1)"
                if (Test-Path -LiteralPath $source -PathType Leaf) { Move-Item -LiteralPath $source -Destination $destination -Force }
            }
            Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
        }
        $runPart = if ($RunId) { " [$RunId]" } else { '' }
        Add-Content -LiteralPath $Path -Value ('{0} [{1}]{2} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'),$Level,$runPart,$Message) -Encoding UTF8
        return $true
    } catch { return $false }
}

function Show-CodexProxyError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message, [string]$Code='UNEXPECTED_ERROR', [string]$Remediation='请运行诊断工具获取更多信息。', [string]$LogPath, [string]$Title='Codex Proxy 启动失败')
    Add-Type -AssemblyName PresentationFramework
    $logHint = if ($LogPath) { "`n`n日志：$LogPath`n`n是否打开日志所在文件夹？" } else { '' }
    $buttons = if ($LogPath) { [System.Windows.MessageBoxButton]::YesNo } else { [System.Windows.MessageBoxButton]::OK }
    $result = [System.Windows.MessageBox]::Show("[$Code] $Message`n`n处理建议：$Remediation$logHint",$Title,$buttons,[System.Windows.MessageBoxImage]::Error)
    if ($LogPath -and $result -eq [System.Windows.MessageBoxResult]::Yes) {
        $folder=Split-Path -Parent $LogPath
        if (Test-Path -LiteralPath $folder -PathType Container) { Start-Process -FilePath 'explorer.exe' -ArgumentList @($folder) }
    }
}

function Get-CodexProxyListener {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    Get-NetTCPConnection -State Listen -LocalPort $Config.ProxyPort -ErrorAction SilentlyContinue | Where-Object {
        if ($_.LocalAddress -in @('0.0.0.0','::')) { return $true }
        $address=$null
        if ([Net.IPAddress]::TryParse($_.LocalAddress,[ref]$address)) {
            if ($Config.ProxyHost -eq 'localhost') { return [Net.IPAddress]::IsLoopback($address) }
            return $_.LocalAddress -eq $Config.ProxyHost
        }
        $false
    } | Select-Object -First 1
}

function Test-CodexProxyEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $listener=Get-CodexProxyListener -Config $Config
    if (-not $listener) {
        return [pscustomobject]@{Ready=$false;Listener=$null;ProcessName=$null;StatusLine=$null;Code='PROXY_NOT_LISTENING';Message="本地代理 $($Config.ProxyHost):$($Config.ProxyPort) 未监听。";Remediation='请启动代理客户端，或使用 -ProxyPort 指定正确端口；未指定时默认为 7891。'}
    }
    $listenerProcess=Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    $processName=if($listenerProcess){$listenerProcess.ProcessName}else{'unknown'}
    $client=New-Object Net.Sockets.TcpClient
    try {
        $asyncResult=$client.BeginConnect($Config.ProxyHost,$Config.ProxyPort,$null,$null)
        if(-not $asyncResult.AsyncWaitHandle.WaitOne($Config.ProxyConnectTimeoutSeconds*1000)){throw '连接代理端口超时。'}
        $client.EndConnect($asyncResult)
        $asyncResult.AsyncWaitHandle.Close()
        $stream=$client.GetStream(); $stream.ReadTimeout=$Config.ProxyConnectTimeoutSeconds*1000
        $request="CONNECT $($Config.ProxyProbeHost):$($Config.ProxyProbePort) HTTP/1.1`r`nHost: $($Config.ProxyProbeHost):$($Config.ProxyProbePort)`r`nProxy-Connection: Keep-Alive`r`n`r`n"
        $requestBytes=[Text.Encoding]::ASCII.GetBytes($request); $stream.Write($requestBytes,0,$requestBytes.Length)
        $buffer=New-Object byte[] 4096; $read=$stream.Read($buffer,0,$buffer.Length)
        if($read -le 0){throw '代理没有返回 HTTP 响应。'}
        $statusLine=(([Text.Encoding]::ASCII.GetString($buffer,0,$read) -split "`r?`n")[0]).Trim()
        if($statusLine -notmatch '^HTTP/\d(?:\.\d)?\s+2\d\d\b'){
            $code=if($statusLine -match '\s407\s'){'PROXY_AUTH_REQUIRED'}else{'PROXY_CONNECT_REJECTED'}
            $remediation=if($code -eq 'PROXY_AUTH_REQUIRED'){'当前版本暂不支持需要认证的本地代理，请改用无认证的 loopback 监听端口。'}else{'请检查代理节点、规则和 Mixed/HTTP 端口配置。'}
            return [pscustomobject]@{Ready=$false;Listener=$listener;ProcessName=$processName;StatusLine=$statusLine;Code=$code;Message="代理拒绝 CONNECT 探测：$statusLine";Remediation=$remediation}
        }
        [pscustomobject]@{Ready=$true;Listener=$listener;ProcessName=$processName;StatusLine=$statusLine;Code='PROXY_READY';Message="代理可用（$processName，$statusLine）。";Remediation=''}
    } catch {
        [pscustomobject]@{Ready=$false;Listener=$listener;ProcessName=$processName;StatusLine=$null;Code='PROXY_PROBE_FAILED';Message="代理健康检查失败：$($_.Exception.Message)";Remediation='请检查代理节点、规则和 Mixed/HTTP 端口配置。'}
    } finally { $client.Dispose() }
}

function Get-CodexPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $packages=@(Get-AppxPackage -Name $Config.PackageName -ErrorAction SilentlyContinue)
    if($packages.Count -eq 0){return $null}
    $trusted=@($packages|Where-Object{$_.PublisherId -eq $Config.ExpectedPublisherId -and $_.Status.ToString() -eq 'Ok' -and $_.SignatureKind.ToString() -eq 'Store'})
    if($trusted.Count -eq 0){throw(New-CodexProxyException -Code 'CODEX_PACKAGE_UNTRUSTED' -Message '检测到 Codex 包，但发布者、签名来源或包状态不符合预期。' -Remediation '请从官方 Microsoft Store 重新安装 OpenAI Codex。')}
    $trusted|Sort-Object Version -Descending|Select-Object -First 1
}

function Get-CodexPackageProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package)
    $installRoot=([IO.Path]::GetFullPath([string]$Package.InstallLocation)).TrimEnd('\')+'\'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.ExecutablePath -and ([IO.Path]::GetFullPath([string]$_.ExecutablePath)).StartsWith($installRoot,[StringComparison]::OrdinalIgnoreCase)}
}

function Get-CodexReportedUpdateVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package, [string]$LogRoot)
    if (-not $LogRoot) {
        $packageFamilyName = [string](Get-MapValue -Map $Package -Name 'PackageFamilyName' -Default '')
        if ([string]::IsNullOrWhiteSpace($packageFamilyName)) { return $null }
        $LogRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "Packages\$packageFamilyName\LocalCache\Local"
    }
    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) { return $null }
    $versions = New-Object Collections.Generic.List[version]
    $files = @(Get-ChildItem -LiteralPath $LogRoot -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 20)
    foreach ($file in $files) {
        foreach ($match in @(Select-String -LiteralPath $file.FullName -Pattern 'manifestBuildVersion=(\d+\.\d+\.\d+\.\d+)' -AllMatches -ErrorAction SilentlyContinue)) {
            foreach ($capture in $match.Matches) {
                $parsed = $null
                if ([version]::TryParse($capture.Groups[1].Value, [ref]$parsed)) { $versions.Add($parsed) }
            }
        }
    }
    if ($versions.Count -eq 0) { return $null }
    $versions | Sort-Object -Descending | Select-Object -First 1
}

function Invoke-CodexStoreUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$InstalledPackage, [Parameter(Mandatory)]$Config)
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw (New-CodexProxyException -Code 'UPDATE_WINGET_MISSING' -Message '检测到 Store 已分配新版本，但系统找不到 winget.exe。' -Remediation '请从 Microsoft Store 安装或修复“应用安装程序”，然后重试。')
    }
    $architecture = ([string](Get-MapValue -Map $InstalledPackage -Name 'Architecture' -Default '')).ToLowerInvariant()
    if ($architecture -notin @('x64','arm64')) {
        throw (New-CodexProxyException -Code 'UPDATE_ARCHITECTURE_UNSUPPORTED' -Message "winget 更新不支持此架构：$architecture" -Remediation '请使用 Microsoft Store 完成更新。')
    }
    $environmentNames = @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy')
    $previous = @{}
    foreach ($name in $environmentNames) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process'); [Environment]::SetEnvironmentVariable($name, $Config.ProxyUrl, 'Process') }
    $stdoutPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-proxy-winget-' + [guid]::NewGuid().ToString('N') + '.stdout.log')
    $stderrPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-proxy-winget-' + [guid]::NewGuid().ToString('N') + '.stderr.log')
    try {
        $arguments = @('install','--id',$Config.UpdateStoreProductId,'--source','msstore','--architecture',$architecture,'--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
        $process = Start-Process -FilePath $winget.Source -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if (-not $process.WaitForExit($Config.UpdateAttemptTimeoutSeconds * 1000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw (New-CodexProxyException -Code 'UPDATE_STORE_TIMEOUT' -Message "winget Store 更新超过 $($Config.UpdateAttemptTimeoutSeconds) 秒，已停止等待。" -Remediation '启动器会继续打开当前版本并稍后自动重试。')
        }
        $output = @()
        if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { $output += @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue) }
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { $output += @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue) }
        $wingetExitCode = $process.ExitCode
        if ($wingetExitCode -ne 0) {
            $detail = ($output | Select-Object -Last 12) -join ' | '
            throw (New-CodexProxyException -Code 'UPDATE_STORE_FAILED' -Message "winget Store 更新失败（退出码 $wingetExitCode）：$detail" -Remediation '启动器会继续打开当前版本并稍后自动重试；必要时请开启代理客户端的 TUN 模式。')
        }
    }
    finally {
        foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
        foreach ($path in @($stdoutPath,$stderrPath)) { if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } }
    }
    $installedVersion = [version]([string](Get-MapValue -Map $InstalledPackage -Name 'Version' -Default '0.0.0.0'))
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $updatedPackage = $null
    do {
        $updatedPackage = Get-CodexPackage -Config $Config
        if ($updatedPackage -and [version]$updatedPackage.Version -gt $installedVersion) { return $updatedPackage }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw (New-CodexProxyException -Code 'UPDATE_STORE_NOT_APPLIED' -Message 'winget 已完成，但 Codex 包版本没有变化。' -Remediation '启动器会继续打开当前版本并稍后自动重试；必要时请开启代理客户端的 TUN 模式。')
}

function Read-CodexUpdateState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Write-CodexUpdateState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = "$Path.writing-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-CodexAutoUpdateDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][version]$InstalledVersion,
        [AllowNull()][version]$ReportedVersion,
        $State,
        [Parameter(Mandatory)][int]$RetryCooldownMinutes,
        [datetime]$NowUtc = [DateTime]::UtcNow
    )
    if (-not $ReportedVersion -or $ReportedVersion -le $InstalledVersion) {
        return [pscustomobject]@{ShouldAttempt=$false;Reason='NoUpdate';RetryAfterUtc=$null}
    }
    if ($State) {
        $stateTarget = [string](Get-MapValue -Map $State -Name 'TargetVersion' -Default '')
        $stateOutcome = [string](Get-MapValue -Map $State -Name 'Outcome' -Default '')
        $lastAttemptText = [string](Get-MapValue -Map $State -Name 'LastAttemptUtc' -Default '')
        $lastAttemptUtc = [datetime]::MinValue
        if ($stateTarget -eq $ReportedVersion.ToString() -and $stateOutcome -eq 'Failed' -and [datetime]::TryParse($lastAttemptText, [ref]$lastAttemptUtc)) {
            $retryAfterUtc = $lastAttemptUtc.ToUniversalTime().AddMinutes([Math]::Max(5, $RetryCooldownMinutes))
            if ($retryAfterUtc -gt $NowUtc.ToUniversalTime()) {
                return [pscustomobject]@{ShouldAttempt=$false;Reason='Cooldown';RetryAfterUtc=$retryAfterUtc}
            }
        }
    }
    [pscustomobject]@{ShouldAttempt=$true;Reason='UpdateAvailable';RetryAfterUtc=$null}
}

function Invoke-CodexAutomaticUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$InstalledPackage, [Parameter(Mandatory)]$Config)
    $installedVersion = [version]([string](Get-MapValue -Map $InstalledPackage -Name 'Version' -Default '0.0.0.0'))
    $reportedVersion = Get-CodexReportedUpdateVersion -Package $InstalledPackage
    $state = Read-CodexUpdateState -Path $Config.UpdateStateFilePath
    $decision = Get-CodexAutoUpdateDecision -InstalledVersion $installedVersion -ReportedVersion $reportedVersion -State $state -RetryCooldownMinutes $Config.UpdateRetryCooldownMinutes
    if (-not $decision.ShouldAttempt) {
        return [pscustomobject]@{
            Attempted=$false; Updated=$false; Reason=$decision.Reason; Package=$InstalledPackage
            InstalledVersion=$installedVersion; TargetVersion=$reportedVersion; RetryAfterUtc=$decision.RetryAfterUtc; Code=$null; Message=$null
        }
    }
    try {
        $updatedPackage = Invoke-CodexStoreUpdate -InstalledPackage $InstalledPackage -Config $Config
        try {
            Write-CodexUpdateState -Path $Config.UpdateStateFilePath -State ([pscustomobject]@{
                SchemaVersion=1; TargetVersion=$reportedVersion.ToString(); InstalledVersion=[string]$updatedPackage.Version
                Outcome='Succeeded'; LastAttemptUtc=[DateTime]::UtcNow.ToString('o'); ErrorCode=$null; ErrorMessage=$null
            })
        } catch {}
        return [pscustomobject]@{
            Attempted=$true; Updated=$true; Reason='Updated'; Package=$updatedPackage
            InstalledVersion=[version]$updatedPackage.Version; TargetVersion=$reportedVersion; RetryAfterUtc=$null; Code=$null; Message=$null
        }
    }
    catch {
        $info = Get-CodexProxyExceptionInfo -Exception $_.Exception
        $message = if ($info.Message.Length -gt 2000) { $info.Message.Substring(0, 2000) } else { $info.Message }
        $attemptedAtUtc = [DateTime]::UtcNow
        try {
            Write-CodexUpdateState -Path $Config.UpdateStateFilePath -State ([pscustomobject]@{
                SchemaVersion=1; TargetVersion=$reportedVersion.ToString(); InstalledVersion=$installedVersion.ToString()
                Outcome='Failed'; LastAttemptUtc=$attemptedAtUtc.ToString('o'); ErrorCode=$info.Code; ErrorMessage=$message
            })
        } catch {}
        return [pscustomobject]@{
            Attempted=$true; Updated=$false; Reason='Failed'; Package=$InstalledPackage
            InstalledVersion=$installedVersion; TargetVersion=$reportedVersion
            RetryAfterUtc=$attemptedAtUtc.AddMinutes($Config.UpdateRetryCooldownMinutes); Code=$info.Code; Message=$message
        }
    }
}

function Get-CodexApplicationInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package,[Parameter(Mandatory)]$Config)
    $installRoot=([IO.Path]::GetFullPath([string]$Package.InstallLocation)).TrimEnd('\')
    $manifestPath=Join-Path $installRoot 'AppxManifest.xml'
    if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){throw(New-CodexProxyException -Code 'CODEX_MANIFEST_MISSING' -Message "找不到 Codex 包清单：$manifestPath" -Remediation '请修复或重新安装官方 Codex。')}
    [xml]$manifest=Get-Content -LiteralPath $manifestPath -Raw
    $application=$manifest.Package.Applications.Application|Where-Object{$_.Id -eq $Config.AppId}|Select-Object -First 1
    if(-not $application -or -not $application.Executable){throw(New-CodexProxyException -Code 'CODEX_APP_NOT_FOUND' -Message "包清单中不存在应用 '$($Config.AppId)'。" -Remediation '当前 Codex 版本可能不兼容，请更新 Codex Proxy。')}
    $relativeExecutable=([string]$application.Executable).Replace('/','\')
    $executablePath=[IO.Path]::GetFullPath((Join-Path $installRoot $relativeExecutable))
    if(-not $executablePath.StartsWith("$installRoot\",[StringComparison]::OrdinalIgnoreCase)){throw(New-CodexProxyException -Code 'CODEX_MANIFEST_PATH_INVALID' -Message 'Codex 清单中的可执行文件路径超出了安装目录。' -Remediation '请重新安装官方 Codex。')}
    if(-not(Test-Path -LiteralPath $executablePath -PathType Leaf)){throw(New-CodexProxyException -Code 'CODEX_EXECUTABLE_MISSING' -Message "找不到 Codex 主程序：$executablePath" -Remediation '请修复或重新安装官方 Codex。')}
    $resourcesPath=Join-Path $installRoot 'app\resources'
    if(-not(Test-Path -LiteralPath $resourcesPath -PathType Container)){throw(New-CodexProxyException -Code 'CODEX_RESOURCES_MISSING' -Message "找不到 Codex 资源目录：$resourcesPath" -Remediation '请修复或重新安装官方 Codex。')}
    $helperFiles=[ordered]@{}
    Get-ChildItem -LiteralPath $resourcesPath -Filter 'codex*.exe' -File|Sort-Object Name|ForEach-Object{$helperFiles[$_.Name]=$_.FullName}
    foreach($name in @('codex.exe','codex-windows-sandbox-setup.exe','codex-command-runner.exe','codex-code-mode-host.exe')){
        if(-not $helperFiles.Contains($name)){throw(New-CodexProxyException -Code 'CODEX_HELPER_MISSING' -Message "缺少必需的 Codex helper：$name" -Remediation '请更新或修复官方 Codex，然后重新启动。')}
    }
    if([bool](Get-MapValue -Map $Config -Name 'RequireValidSignatures' -Default $false)){
        foreach($path in @($executablePath)+@($helperFiles.Values)){
            if((Get-AuthenticodeSignature -LiteralPath $path).Status -ne [System.Management.Automation.SignatureStatus]::Valid){throw(New-CodexProxyException -Code 'CODEX_SIGNATURE_INVALID' -Message "Codex 文件签名无效：$path" -Remediation '请从官方 Microsoft Store 重新安装 Codex。')}
        }
    }
    [pscustomobject]@{ExecutablePath=$executablePath;ManifestPath=$manifestPath;ResourcesPath=$resourcesPath;HelperFiles=$helperFiles;PackageVersion=[string](Get-MapValue -Map $Package -Name 'Version' -Default 'unknown');PackageFamilyName=[string](Get-MapValue -Map $Package -Name 'PackageFamilyName' -Default 'unknown')}
}

function Test-CodexHelperCacheInternal {
    param([Parameter(Mandatory)][string]$CacheDirectory,[Parameter(Mandatory)]$SourceHashes)
    if(-not(Test-Path -LiteralPath $CacheDirectory -PathType Container)){return $false}
    $cachedNames=@(Get-ChildItem -LiteralPath $CacheDirectory -Filter 'codex*.exe' -File|ForEach-Object Name|Sort-Object)
    $sourceNames=@($SourceHashes.Keys|Sort-Object)
    if(($cachedNames -join '|') -ne ($sourceNames -join '|')){return $false}
    foreach($name in $sourceNames){$candidate=Join-Path $CacheDirectory $name;if(-not(Test-Path -LiteralPath $candidate -PathType Leaf)){return $false};if((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne $SourceHashes[$name]){return $false}}
    $true
}

function Sync-CodexHelpers {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ApplicationInfo,[Parameter(Mandatory)]$Config)
    $sourceFiles=$ApplicationInfo.HelperFiles
    if(-not $sourceFiles -or $sourceFiles.Count -eq 0){throw(New-CodexProxyException -Code 'CODEX_HELPERS_EMPTY' -Message '没有发现任何 Codex helper。' -Remediation '请修复或更新官方 Codex。')}
    $sourceHashes=@{}
    foreach($entry in $sourceFiles.GetEnumerator()){
        if([IO.Path]::GetFileName([string]$entry.Key) -ne [string]$entry.Key -or [string]$entry.Key -notmatch '^codex.*\.exe$'){throw(New-CodexProxyException -Code 'CODEX_HELPER_NAME_INVALID' -Message "helper 文件名不安全：$($entry.Key)" -Remediation '请修复或重新安装官方 Codex。')}
        $sourceHashes[$entry.Key]=(Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash
    }
    $cacheDirectory=if($Config.PSObject.Properties.Name -contains 'HelperCacheDirectory'){[string]$Config.HelperCacheDirectory}else{Join-Path $env:LOCALAPPDATA ([string]$Config.HelperCachePath)}
    if(Test-CodexHelperCacheInternal -CacheDirectory $cacheDirectory -SourceHashes $sourceHashes){return [pscustomobject]@{CliPath=Join-Path $cacheDirectory 'codex.exe';CacheDirectory=$cacheDirectory;Refreshed=$false;FileCount=$sourceHashes.Count}}
    $mutex=New-Object Threading.Mutex($false,'Local\CodexProxy.HelperCache');$lockTaken=$false;$stagingDirectory=$null;$backupDirectory=$null
    try{
        $lockTaken=$mutex.WaitOne(30000)
        if(-not $lockTaken){throw(New-CodexProxyException -Code 'HELPER_CACHE_BUSY' -Message '等待 helper 缓存更新锁超时。' -Remediation '请等待其他启动操作完成后重试。')}
        if(Test-CodexHelperCacheInternal -CacheDirectory $cacheDirectory -SourceHashes $sourceHashes){return [pscustomobject]@{CliPath=Join-Path $cacheDirectory 'codex.exe';CacheDirectory=$cacheDirectory;Refreshed=$false;FileCount=$sourceHashes.Count}}
        $parent=Split-Path -Parent $cacheDirectory;New-Item -ItemType Directory -Path $parent -Force|Out-Null
        $stagingDirectory=Join-Path $parent ('.codex-proxy-staging-'+[guid]::NewGuid().ToString('N'));$backupDirectory=Join-Path $parent ('.codex-proxy-backup-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stagingDirectory -Force|Out-Null
        foreach($entry in $sourceFiles.GetEnumerator()){$destination=Join-Path $stagingDirectory $entry.Key;Copy-Item -LiteralPath $entry.Value -Destination $destination;if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $sourceHashes[$entry.Key]){throw(New-CodexProxyException -Code 'HELPER_CACHE_VERIFY_FAILED' -Message "helper 缓存校验失败：$($entry.Key)" -Remediation '请检查磁盘空间和安全软件后重试。')}}
        [pscustomobject]@{SchemaVersion=1;PackageVersion=[string](Get-MapValue -Map $ApplicationInfo -Name 'PackageVersion' -Default 'unknown');PackageFamilyName=[string](Get-MapValue -Map $ApplicationInfo -Name 'PackageFamilyName' -Default 'unknown');CreatedAtUtc=[DateTime]::UtcNow.ToString('o');Files=$sourceHashes}|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $stagingDirectory 'cache-manifest.json') -Encoding UTF8
        if(Test-Path -LiteralPath $cacheDirectory -PathType Container){Move-Item -LiteralPath $cacheDirectory -Destination $backupDirectory}
        try{Move-Item -LiteralPath $stagingDirectory -Destination $cacheDirectory;$stagingDirectory=$null}catch{if((Test-Path -LiteralPath $backupDirectory -PathType Container)-and -not(Test-Path -LiteralPath $cacheDirectory)){Move-Item -LiteralPath $backupDirectory -Destination $cacheDirectory;$backupDirectory=$null};throw}
        if(-not(Test-CodexHelperCacheInternal -CacheDirectory $cacheDirectory -SourceHashes $sourceHashes)){
            $failedDirectory=Join-Path $parent ('.codex-proxy-failed-'+[guid]::NewGuid().ToString('N'))
            if(Test-Path -LiteralPath $cacheDirectory -PathType Container){Move-Item -LiteralPath $cacheDirectory -Destination $failedDirectory}
            if($backupDirectory -and (Test-Path -LiteralPath $backupDirectory -PathType Container)){Move-Item -LiteralPath $backupDirectory -Destination $cacheDirectory;$backupDirectory=$null}
            if(Test-Path -LiteralPath $failedDirectory -PathType Container){Remove-Item -LiteralPath $failedDirectory -Recurse -Force -ErrorAction SilentlyContinue}
            throw(New-CodexProxyException -Code 'HELPER_CACHE_PUBLISH_FAILED' -Message '原子发布后的 helper 缓存校验失败，已恢复上一版本。' -Remediation '请重试；如果持续失败，请清理 helper 缓存。')
        }
        if($backupDirectory -and (Test-Path -LiteralPath $backupDirectory -PathType Container)){Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue;$backupDirectory=$null}
        [pscustomobject]@{CliPath=Join-Path $cacheDirectory 'codex.exe';CacheDirectory=$cacheDirectory;Refreshed=$true;FileCount=$sourceHashes.Count}
    }finally{if($stagingDirectory -and (Test-Path -LiteralPath $stagingDirectory -PathType Container)){Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue};if($lockTaken){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

function New-CodexProxyInnerScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExecutablePath,[Parameter(Mandatory)][string]$CodexCliPath,[Parameter(Mandatory)][string]$ProxyUrl)
    $escapedExe=$ExecutablePath.Replace("'","''");$escapedCodexCli=$CodexCliPath.Replace("'","''");$escapedProxy=$ProxyUrl.Replace("'","''")
    @"
`$ErrorActionPreference = 'Stop'
`$env:HTTP_PROXY = '$escapedProxy'
`$env:HTTPS_PROXY = '$escapedProxy'
`$env:ALL_PROXY = '$escapedProxy'
`$env:http_proxy = '$escapedProxy'
`$env:https_proxy = '$escapedProxy'
`$env:all_proxy = '$escapedProxy'
`$env:WS_PROXY = '$escapedProxy'
`$env:WSS_PROXY = '$escapedProxy'
`$mergedNoProxy = (((@(`$env:NO_PROXY, `$env:no_proxy, 'localhost,127.0.0.1,::1') -join ',') -split ',') | ForEach-Object { `$_.Trim() } | Where-Object { `$_ } | Select-Object -Unique) -join ','
`$env:NO_PROXY = `$mergedNoProxy
`$env:no_proxy = `$mergedNoProxy
`$env:NODE_USE_ENV_PROXY = '1'
`$env:CODEX_CLI_PATH = '$escapedCodexCli'
`$electronArgs = @('--proxy-server=$escapedProxy','--proxy-bypass-list=<local>')
Start-Process -FilePath '$escapedExe' -ArgumentList `$electronArgs
"@
}

function Get-CodexProxyStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)
    $proxy=Test-CodexProxyEndpoint -Config $Config;$package=$null;$applicationInfo=$null;$packageError=$null
    try{$package=Get-CodexPackage -Config $Config;if($package){$applicationInfo=Get-CodexApplicationInfo -Package $package -Config $Config}}catch{$packageError=Get-CodexProxyExceptionInfo -Exception $_.Exception}
    $runningProcesses=@();if($package){$runningProcesses=@(Get-CodexPackageProcess -Package $package)};$invokeCommand=Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue
    $readyAfterExit=[bool]($proxy.Ready -and $package -and $applicationInfo -and $invokeCommand -and -not $packageError);$readyNow=[bool]($readyAfterExit -and $runningProcesses.Count -eq 0)
    $blockingCode=$null;$blockingMessage=$null;$remediation=$null
    if(-not $proxy.Ready){$blockingCode=$proxy.Code;$blockingMessage=$proxy.Message;$remediation=$proxy.Remediation}
    elseif($packageError){$blockingCode=$packageError.Code;$blockingMessage=$packageError.Message;$remediation=$packageError.Remediation}
    elseif(-not $package){$blockingCode='CODEX_NOT_INSTALLED';$blockingMessage='未安装 OpenAI Codex Windows 应用。';$remediation='请先从官方 Microsoft Store 安装 Codex。'}
    elseif(-not $invokeCommand){$blockingCode='APPX_COMMAND_MISSING';$blockingMessage='系统缺少 Invoke-CommandInDesktopPackage。';$remediation='请使用 Windows PowerShell 5.1，并修复 Windows Appx 模块。'}
    elseif($runningProcesses.Count -gt 0){$blockingCode='CODEX_ALREADY_RUNNING';$blockingMessage='Codex 当前正在运行。';$remediation='请保存正在进行的任务，从系统托盘完全退出 Codex 后重试。'}
    [pscustomobject]@{Proxy=$proxy;Package=$package;ApplicationInfo=$applicationInfo;PackageError=$packageError;RunningProcesses=$runningProcesses;InvokeCommandAvailable=[bool]$invokeCommand;ReadyNow=$readyNow;ReadyAfterCodexExit=$readyAfterExit;BlockingCode=$blockingCode;BlockingMessage=$blockingMessage;Remediation=$remediation}
}

function Get-CodexProxyShortcutArguments {[CmdletBinding()]param([Parameter(Mandatory)][string]$LauncherPath) '-NoLogo -NoProfile -File "{0}"' -f $LauncherPath}

function Test-CodexProxyShortcut {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$LauncherPath)
    $powershellPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$expectedArguments=Get-CodexProxyShortcutArguments -LauncherPath $LauncherPath
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return [pscustomobject]@{Ready=$false;Exists=$false;Owned=$false;TargetPath=$null;Arguments=$null;Code='SHORTCUT_MISSING'}}
    $shell=New-Object -ComObject WScript.Shell;$shortcut=$shell.CreateShortcut($Path);$targetMatches=$shortcut.TargetPath -eq $powershellPath;$argumentsMatch=$shortcut.Arguments -eq $expectedArguments
    $scriptName = [IO.Path]::GetFileName($LauncherPath)
    [pscustomobject]@{Ready=[bool]($targetMatches -and $argumentsMatch);Exists=$true;Owned=[bool]($targetMatches -and $shortcut.Arguments -match [regex]::Escape($scriptName));TargetPath=$shortcut.TargetPath;Arguments=$shortcut.Arguments;Code=if($targetMatches -and $argumentsMatch){'SHORTCUT_READY'}else{'SHORTCUT_MISMATCH'}}
}

function Enter-CodexProxyLaunchLock {
    [CmdletBinding()]param()
    $mutex=New-Object Threading.Mutex($false,'Local\CodexProxy.Launch')
    if(-not $mutex.WaitOne(0)){$mutex.Dispose();throw(New-CodexProxyException -Code 'LAUNCH_ALREADY_IN_PROGRESS' -Message '另一个 Codex Proxy 启动操作正在进行。' -Remediation '请等待几秒，不要连续双击快捷方式。')}
    $mutex
}

function Wait-CodexPackageProcess {
    [CmdletBinding()]param([Parameter(Mandatory)]$Package,[int]$TimeoutSeconds=15)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do{$processes=@(Get-CodexPackageProcess -Package $Package);if($processes.Count -gt 0){return $processes};Start-Sleep -Milliseconds 300}while([DateTime]::UtcNow -lt $deadline)
    @()
}

Export-ModuleMember -Function @('Get-CodexProxyConfig','Get-CodexProxyExceptionInfo','Write-CodexProxyLog','Show-CodexProxyError','Get-CodexProxyListener','Test-CodexProxyEndpoint','Get-CodexPackage','Get-CodexPackageProcess','Get-CodexReportedUpdateVersion','Invoke-CodexStoreUpdate','Read-CodexUpdateState','Write-CodexUpdateState','Get-CodexAutoUpdateDecision','Invoke-CodexAutomaticUpdate','Get-CodexApplicationInfo','Sync-CodexHelpers','New-CodexProxyInnerScript','Get-CodexProxyStatus','Get-CodexProxyShortcutArguments','Test-CodexProxyShortcut','Enter-CodexProxyLaunchLock','Wait-CodexPackageProcess')
