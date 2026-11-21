# Builds windows/runner/resources/app_icon.ico from the shared PNG icon.
# Usage: pwsh -NoProfile -File scripts/make_windows_icon.ps1
param(
  [string]$Source = "assets/icon/app_icon_1024.png",
  [string]$Output = "windows/runner/resources/app_icon.ico"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$images = [System.Collections.Generic.List[byte[]]]::new()

$sourceImage = [System.Drawing.Image]::FromFile((Resolve-Path $Source))
try {
  foreach ($size in $sizes) {
    $bitmap = [System.Drawing.Bitmap]::new($size, $size)
    try {
      $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.InterpolationMode =
          [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode =
          [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode =
          [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($sourceImage, 0, 0, $size, $size)
      } finally {
        $graphics.Dispose()
      }
      $stream = [System.IO.MemoryStream]::new()
      try {
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $images.Add($stream.ToArray())
      } finally {
        $stream.Dispose()
      }
    } finally {
      $bitmap.Dispose()
    }
  }
} finally {
  $sourceImage.Dispose()
}

$outputStream = [System.IO.MemoryStream]::new()
$writer = [System.IO.BinaryWriter]::new($outputStream)
try {
  $writer.Write([UInt16]0)          # reserved
  $writer.Write([UInt16]1)          # icon
  $writer.Write([UInt16]$images.Count)

  $offset = 6 + 16 * $images.Count
  for ($i = 0; $i -lt $images.Count; $i++) {
    $size = $sizes[$i]
    $data = $images[$i]
    $dimension = if ($size -ge 256) { 0 } else { $size }
    $writer.Write([Byte]$dimension)
    $writer.Write([Byte]$dimension)
    $writer.Write([Byte]0)          # palette
    $writer.Write([Byte]0)          # reserved
    $writer.Write([UInt16]1)        # planes
    $writer.Write([UInt16]32)       # bits per pixel
    $writer.Write([UInt32]$data.Length)
    $writer.Write([UInt32]$offset)
    $offset += $data.Length
  }

  foreach ($data in $images) {
    $writer.Write($data)
  }
  $writer.Flush()
  [System.IO.File]::WriteAllBytes((Join-Path (Get-Location) $Output),
    $outputStream.ToArray())
} finally {
  $writer.Dispose()
  $outputStream.Dispose()
}

Write-Host "Wrote $Output ($($images.Count) sizes)"
