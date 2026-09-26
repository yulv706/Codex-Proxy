[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'assets\codex-proxy.ico'),
    [string]$PreviewPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -eq 'Core') {
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-OutputPath', $OutputPath)
    if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) { $arguments += @('-PreviewPath', $PreviewPath) }
    & $windowsPowerShell $arguments
    if ($LASTEXITCODE -ne 0) { throw "Icon generation failed with exit code $LASTEXITCODE." }
    return
}

if (-not ('CodexProxyIconGenerator' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

public static class CodexProxyIconGenerator
{
    public static Bitmap Render(int size)
    {
        Bitmap bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Transparent);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            float inset = Math.Max(0.8f, size * 0.025f);
            RectangleF square = new RectangleF(inset, inset, size - inset * 2f, size - inset * 2f);
            using (GraphicsPath background = RoundRect(square, size * 0.225f))
            using (LinearGradientBrush gradient = new LinearGradientBrush(square, Color.FromArgb(49, 145, 255), Color.FromArgb(0, 82, 194), 48f))
            {
                graphics.FillPath(gradient, background);
                using (LinearGradientBrush sheen = new LinearGradientBrush(square, Color.FromArgb(60, Color.White), Color.FromArgb(0, Color.White), 90f))
                    graphics.FillPath(sheen, background);
            }

            float markInset = size * 0.245f;
            RectangleF arc = new RectangleF(markInset, size * 0.22f, size - markInset * 2f, size * 0.56f);
            using (Pen pen = new Pen(Color.White, Math.Max(1.7f, size * 0.09f)))
            {
                pen.StartCap = LineCap.Round;
                pen.EndCap = LineCap.Round;
                graphics.DrawArc(pen, arc, 47f, 266f);
            }
        }
        return bitmap;
    }

    public static void SaveIcon(string path)
    {
        int[] sizes = new int[] { 16, 20, 24, 32, 40, 48, 64, 128, 256 };
        MemoryStream[] images = new MemoryStream[sizes.Length];
        try
        {
            for (int index = 0; index < sizes.Length; index++)
            {
                images[index] = new MemoryStream();
                using (Bitmap bitmap = Render(sizes[index])) bitmap.Save(images[index], ImageFormat.Png);
            }

            using (FileStream stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            using (BinaryWriter writer = new BinaryWriter(stream))
            {
                writer.Write((ushort)0);
                writer.Write((ushort)1);
                writer.Write((ushort)sizes.Length);
                int offset = 6 + sizes.Length * 16;
                for (int index = 0; index < sizes.Length; index++)
                {
                    int size = sizes[index];
                    writer.Write((byte)(size == 256 ? 0 : size));
                    writer.Write((byte)(size == 256 ? 0 : size));
                    writer.Write((byte)0);
                    writer.Write((byte)0);
                    writer.Write((ushort)1);
                    writer.Write((ushort)32);
                    writer.Write((uint)images[index].Length);
                    writer.Write((uint)offset);
                    offset += (int)images[index].Length;
                }
                for (int index = 0; index < sizes.Length; index++) writer.Write(images[index].ToArray());
            }
        }
        finally
        {
            foreach (MemoryStream image in images) if (image != null) image.Dispose();
        }
    }

    private static GraphicsPath RoundRect(RectangleF bounds, float radius)
    {
        GraphicsPath path = new GraphicsPath();
        float diameter = radius * 2f;
        RectangleF arc = new RectangleF(bounds.X, bounds.Y, diameter, diameter);
        path.AddArc(arc, 180f, 90f);
        arc.X = bounds.Right - diameter;
        path.AddArc(arc, 270f, 90f);
        arc.Y = bounds.Bottom - diameter;
        path.AddArc(arc, 0f, 90f);
        arc.X = bounds.Left;
        path.AddArc(arc, 90f, 90f);
        path.CloseFigure();
        return path;
    }
}
'@ -ReferencedAssemblies 'System.Drawing.dll'
}

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
[CodexProxyIconGenerator]::SaveIcon($outputFullPath)

if (-not [string]::IsNullOrWhiteSpace($PreviewPath)) {
    $previewFullPath = [IO.Path]::GetFullPath($PreviewPath)
    $previewDirectory = Split-Path -Parent $previewFullPath
    if (-not (Test-Path -LiteralPath $previewDirectory -PathType Container)) { New-Item -ItemType Directory -Path $previewDirectory -Force | Out-Null }
    $preview = [CodexProxyIconGenerator]::Render(512)
    try { $preview.Save($previewFullPath, [Drawing.Imaging.ImageFormat]::Png) } finally { $preview.Dispose() }
}

Write-Host "Generated Codex Proxy icon: $outputFullPath" -ForegroundColor Green
