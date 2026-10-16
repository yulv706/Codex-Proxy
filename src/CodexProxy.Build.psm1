Set-StrictMode -Version Latest

function Invoke-CodexProxyCompilation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string[]]$Sources,
        [Parameter(Mandatory)][string[]]$Resources,
        [string]$EntryPoint
    )
    $ErrorActionPreference = 'Stop'
    $compiler = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $compiler) { throw 'The .NET Framework C# compiler was not found.' }
    $frameworkRoot = Split-Path -Parent $compiler
    $outputFullPath = [IO.Path]::GetFullPath($OutputPath)
    $outputDirectory = Split-Path -Parent $outputFullPath
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    $temporaryDirectory = Join-Path $outputDirectory ('.desktop-build-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
    $temporary = Join-Path $temporaryDirectory ([IO.Path]::GetFileName($outputFullPath))
    try {
        $arguments = @('/nologo','/target:winexe','/platform:anycpu','/optimize+','/utf8output','/langversion:5',
            "/out:$temporary", ('/win32icon:' + (Join-Path $ProjectRoot 'assets\codex-proxy.ico')),
            ('/win32manifest:' + (Join-Path $ProjectRoot 'src\app.manifest')))
        foreach ($reference in @('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll','System.Web.Extensions.dll','System.Xaml.dll',
            'WPF\WindowsBase.dll','WPF\PresentationCore.dll','WPF\PresentationFramework.dll')) {
            $arguments += '/reference:' + (Join-Path $frameworkRoot $reference)
        }
        foreach ($resource in $Resources) {
            $path = Join-Path $ProjectRoot $resource
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing resource: $path" }
            $arguments += '/resource:' + $path + ',' + [IO.Path]::GetFileName($path)
        }
        if ($EntryPoint) { $arguments += '/main:' + $EntryPoint }
        foreach ($source in $Sources) {
            $path = Join-Path $ProjectRoot $source
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing source: $path" }
            $arguments += $path
        }
        & $compiler $arguments
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary -PathType Leaf)) { throw "Desktop compilation failed with exit code $LASTEXITCODE." }
        Move-Item -LiteralPath $temporary -Destination $outputFullPath -Force
        Write-Host "Built Windows desktop: $outputFullPath" -ForegroundColor Green
    }
    finally {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryDirectory)
        if (-not $resolvedTemporary.StartsWith($outputDirectory.TrimEnd('\') + '\.desktop-build-', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected compiler staging path.' }
        if (Test-Path -LiteralPath $resolvedTemporary) { Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force }
    }
}

Export-ModuleMember -Function Invoke-CodexProxyCompilation
