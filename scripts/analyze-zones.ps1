# 分区域像素分析：价格/涨跌幅区域是数字（大量像素）还是"—"占位（极少像素）
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class ZonePixels {
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

$capsule = [ZonePixels]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
$rect = New-Object ZonePixels+RECT
[void][ZonePixels]::GetWindowRect($capsule, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[void][ZonePixels]::PrintWindow($capsule, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()

# 全宽 357 逻辑布局估算（scale=1）：padding 12 | symbol≈50 | gap 10 | price≈90 | gap 10 | change≈55 | gap 10 | sparkline 80 | padding 12
$zones = @(
    @(12, 62, "合约名区"),
    @(72, 162, "价格区"),
    @(172, 227, "涨跌幅区"),
    @(237, 317, "趋势线区")
)
foreach ($z in $zones) {
    $count = 0
    for ($x = $z[0]; $x -lt [Math]::Min($z[1], $w); $x += 1) {
        for ($y = 0; $y -lt $h; $y += 1) {
            if ($bmp.GetPixel($x, $y).A -gt 30) { $count++ }
        }
    }
    Write-Output ("{0} (x {1}-{2}): 非透明像素 {3}" -f $z[2], $z[0], $z[1], $count)
}
$bmp.Dispose()