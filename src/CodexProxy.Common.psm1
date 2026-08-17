Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CodexProxyConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file was not found: $Path"
    }

    $data = Import-PowerShellDataFile -LiteralPath $Path
    foreach ($name in @(
        'ProxyHost',
        'ProxyPort',
        'PackageName',
        'AppId',
        'ShortcutName',
        'ShortcutDescription',
        'HelperCachePath'
    )) {
        if (-not $data.ContainsKey($name)) {
            throw "Required configuration key is missing: $name"
        }
    }

    $port = [int]$data.ProxyPort
    if ($port -lt 1 -or $port -gt 65535) {
        throw "ProxyPort must be between 1 and 65535: $port"
    }

    [pscustomobject]@{
        ProxyHost           = [string]$data.ProxyHost
        ProxyPort           = $port
        ProxyUrl            = "http://$($data.ProxyHost):$port"
        PackageName         = [string]$data.PackageName
        AppId               = [string]$data.AppId
        ShortcutName        = [string]$data.ShortcutName
        ShortcutDescription = [string]$data.ShortcutDescription
        HelperCachePath     = [string]$data.HelperCachePath
    }
}

function Write-CodexProxyLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Show-CodexProxyError {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        $Message,
        'Codex Proxy Launcher',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
}

function Get-CodexProxyListener {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    Get-NetTCPConnection -State Listen -LocalPort $Config.ProxyPort -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LocalAddress -in @('0.0.0.0', $Config.ProxyHost, '::', '::1')
        } |
        Select-Object -First 1
}

function Get-CodexPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config)

    Get-AppxPackage -Name $Config.PackageName |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Get-CodexPackageProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package)

    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $Package.InstallLocation,
                [StringComparison]::OrdinalIgnoreCase
            )
        }
}

function Get-CodexApplicationInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)]$Config
    )

    $manifestPath = Join-Path $Package.InstallLocation 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Codex package manifest was not found: $manifestPath"
    }

    [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw
    $application = $manifest.Package.Applications.Application |
        Where-Object { $_.Id -eq $Config.AppId } |
        Select-Object -First 1

    if (-not $application -or -not $application.Executable) {
        throw "App '$($Config.AppId)' was not found in: $manifestPath"
    }

    $relativeExecutable = ([string]$application.Executable).Replace('/', '\')
    $executablePath = Join-Path $Package.InstallLocation $relativeExecutable
    $resourcesPath = Join-Path $Package.InstallLocation 'app\resources'
    $helperFiles = [ordered]@{}
    Get-ChildItem -LiteralPath $resourcesPath -Filter 'codex*.exe' -File |
        Sort-Object Name |
        ForEach-Object { $helperFiles[$_.Name] = $_.FullName }

    $requiredHelpers = @(
        'codex.exe',
        'codex-windows-sandbox-setup.exe',
        'codex-command-runner.exe'
    )

    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        throw "Codex application executable was not found: $executablePath"
    }
    foreach ($name in $requiredHelpers) {
        if (-not $helperFiles.Contains($name)) {
            throw "Required Codex helper was not found: $(Join-Path $resourcesPath $name)"
        }
    }

    [pscustomobject]@{
        ExecutablePath = $executablePath
        ManifestPath   = $manifestPath
        CodexCli       = $helperFiles['codex.exe']
        SandboxSetup   = $helperFiles['codex-windows-sandbox-setup.exe']
        CommandRunner  = $helperFiles['codex-command-runner.exe']
        HelperFiles    = $helperFiles
    }
}

function Sync-CodexHelpers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ApplicationInfo,
        [Parameter(Mandatory)]$Config
    )

    $sourceFiles = $ApplicationInfo.HelperFiles
    if (-not $sourceFiles -or $sourceFiles.Count -eq 0) {
        throw 'No Codex helper executables were discovered.'
    }

    $sourceHashes = @{}
    foreach ($entry in $sourceFiles.GetEnumerator()) {
        $sourceHashes[$entry.Key] = (Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash
    }

    $cacheDirectory = Join-Path $env:LOCALAPPDATA $Config.HelperCachePath
    $filesToCopy = @()
    foreach ($entry in $sourceFiles.GetEnumerator()) {
        $candidate = Join-Path $cacheDirectory $entry.Key
        if (
            -not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
            (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne $sourceHashes[$entry.Key]
        ) {
            $filesToCopy += $entry
        }
    }

    $refreshed = $filesToCopy.Count -gt 0
    if ($refreshed) {
        New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
        foreach ($entry in $filesToCopy) {
            $destination = Join-Path $cacheDirectory $entry.Key
            Copy-Item -LiteralPath $entry.Value -Destination $destination -Force
            $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            if ($destinationHash -ne $sourceHashes[$entry.Key]) {
                throw "Codex helper cache verification failed: $destination"
            }
        }
    }

    [pscustomobject]@{
        CliPath        = Join-Path $cacheDirectory 'codex.exe'
        CacheDirectory = $cacheDirectory
        Refreshed      = $refreshed
    }
}

function New-CodexProxyInnerScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$CodexCliPath,
        [Parameter(Mandatory)][string]$ProxyUrl
    )

    $escapedExe = $ExecutablePath.Replace("'", "''")
    $escapedCodexCli = $CodexCliPath.Replace("'", "''")
    $escapedProxy = $ProxyUrl.Replace("'", "''")

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
`$env:NO_PROXY = 'localhost,127.0.0.1,::1'
`$env:no_proxy = 'localhost,127.0.0.1,::1'
`$env:NODE_USE_ENV_PROXY = '1'
`$env:CODEX_CLI_PATH = '$escapedCodexCli'

`$electronArgs = @(
    '--proxy-server=$escapedProxy'
    '--proxy-bypass-list=<local>'
)

Start-Process -FilePath '$escapedExe' -ArgumentList `$electronArgs
"@
}

Export-ModuleMember -Function @(
    'Get-CodexProxyConfig',
    'Write-CodexProxyLog',
    'Show-CodexProxyError',
    'Get-CodexProxyListener',
    'Get-CodexPackage',
    'Get-CodexPackageProcess',
    'Get-CodexApplicationInfo',
    'Sync-CodexHelpers',
    'New-CodexProxyInnerScript'
)
