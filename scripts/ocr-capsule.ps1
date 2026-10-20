# WinRT OCR 读取胶囊窗口文本：PrintWindow → 4x 放大 → Windows.Media.Ocr 识别
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class OcrCapsule {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

# WinRT 类型加载
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Media.Ocr.OcrEngine,Windows.Media.Ocr,ContentType=WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder,Windows.Graphics.Imaging,ContentType=WindowsRuntime] | Out-Null
[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime] | Out-Null
[Windows.Storage.Streams.RandomAccessStreamReference,Windows.Storage.Streams,ContentType=WindowsRuntime] | Out-Null

# IAsyncOperation → Task 适配
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

$capsule = [OcrCapsule]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
if ($capsule -eq [IntPtr]::Zero) { Write-Output "FATAL: 胶囊未找到"; exit 1 }
$rect = New-Object OcrCapsule+RECT
[void][OcrCapsule]::GetWindowRect($capsule, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top

# PrintWindow 抓取
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[void][OcrCapsule]::PrintWindow($capsule, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()

# 4 倍放大 + 黑底（胶囊文字为白色/浅色，透明背景需合成深色底才可 OCR）
$zw = $w * 4; $zh = $h * 4
$zoom = New-Object System.Drawing.Bitmap($zw, $zh)
$gz = [System.Drawing.Graphics]::FromImage($zoom)
$gz.Clear([System.Drawing.Color]::Black)
$gz.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$gz.DrawImage($bmp, 0, 0, $zw, $zh)
$gz.Dispose()
$path = "D:\ipyProject\ai-contract\docs\screenshots\ocr-input.png"
$zoom.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose(); $zoom.Dispose()

# OCR 识别
try {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $softBmp = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $engine) { Write-Output "OCR: 系统无可用识别语言"; exit 1 }
    $result = Await ($engine.RecognizeAsync($softBmp)) ([Windows.Media.Ocr.OcrResult])
    Write-Output ("OCR结果: [{0}]" -f $result.Text.Trim())
} catch {
    Write-Output "OCR 失败: $($_.Exception.Message)"
}