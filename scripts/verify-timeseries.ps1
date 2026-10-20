# 时间序列抓图：连续 5 张（每 3 秒），相邻比对差异 + 检查 ws 状态点
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class TimeSeries {
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

$capsule = [TimeSeries]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
$rect = New-Object TimeSeries+RECT
[void][TimeSeries]::GetWindowRect($capsule, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top

function Capture([IntPtr]$hwnd, [int]$cw, [int]$ch) {
    $bmp = New-Object System.Drawing.Bitmap($cw, $ch)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][TimeSeries]::PrintWindow($hwnd, $hdc, 2)
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    return $bmp
}

$frames = @()
for ($i = 0; $i -lt 5; $i++) {
    $frames += ,(Capture $capsule $w $h)
    if ($i -lt 4) { Start-Sleep -Seconds 3 }
}

for ($i = 1; $i -lt 5; $i++) {
    $diff = 0
    for ($x = 0; $x -lt $w; $x += 2) {
        for ($y = 0; $y -lt $h; $y += 2) {
            $pa = $frames[$i - 1].GetPixel($x, $y); $pb = $frames[$i].GetPixel($x, $y)
            if ([Math]::Abs($pa.R - $pb.R) + [Math]::Abs($pa.G - $pb.G) + [Math]::Abs($pa.B - $pb.B) -gt 24) { $diff++ }
        }
    }
    Write-Output ("帧{0}->帧{1} 差异像素: {2}" -f ($i - 1 + 1), ($i + 1), $diff)
}

# 检查状态点区域（sparkline 之后 x 317-340）：寻找 6px 圆点（灰色或红色）
$dotPx = 0
for ($x = 315; $x -lt [Math]::Min(345, $w); $x += 1) {
    for ($y = 0; $y -lt $h; $y += 1) {
        $p = $frames[4].GetPixel($x, $y)
        if ($p.A -gt 40) { $dotPx++ }
    }
}
Write-Output ("状态点区域(x315-345)像素: {0}（>30 表示存在连接中/重连指示点）" -f $dotPx)

$frames[4].Save("D:\ipyProject\ai-contract\docs\screenshots\live-frame5.png", [System.Drawing.Imaging.ImageFormat]::Png)
foreach ($f in $frames) { $f.Dispose() }