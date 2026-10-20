# 实时行情验证：两次 PrintWindow 间隔对比（价格跳动 => 像素差异）+ 涨跌颜色采样
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class LiveVerify {
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

$capsule = [LiveVerify]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
if ($capsule -eq [IntPtr]::Zero) { Write-Output "FATAL: 胶囊未找到"; exit 1 }
$rect = New-Object LiveVerify+RECT
[void][LiveVerify]::GetWindowRect($capsule, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
Write-Output ("胶囊 {0}x{1}" -f $w, $h)

function Capture([IntPtr]$hwnd, [int]$cw, [int]$ch) {
    $bmp = New-Object System.Drawing.Bitmap($cw, $ch)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [void][LiveVerify]::PrintWindow($hwnd, $hdc, 2)
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    return $bmp
}

$a = Capture $capsule $w $h
Start-Sleep -Seconds 6
$b = Capture $capsule $w $h

# 1) 间隔差异（实时刷新验证）
$diff = 0
for ($x = 0; $x -lt $w; $x += 2) {
    for ($y = 0; $y -lt $h; $y += 2) {
        $pa = $a.GetPixel($x, $y); $pb = $b.GetPixel($x, $y)
        if ([Math]::Abs($pa.R - $pb.R) + [Math]::Abs($pa.G - $pb.G) + [Math]::Abs($pa.B - $pb.B) -gt 24) { $diff++ }
    }
}
Write-Output ("两次抓图差异像素(6秒间隔): {0}" -f $diff)
if ($diff -gt 5) { Write-Output "REALTIME: PASS - 价格在实时刷新" } else { Write-Output "REALTIME: FAIL - 内容未变化" }

# 2) 涨跌颜色采样（右侧 1/4 区域：涨跌幅+趋势线，下跌应为红 #f87171）
$redPx = 0; $greenPx = 0
for ($x = [int]($w * 0.72); $x -lt $w; $x += 2) {
    for ($y = 0; $y -lt $h; $y += 2) {
        $p = $b.GetPixel($x, $y)
        if ($p.A -gt 40) {
            if ($p.R -gt 180 -and $p.G -lt 140 -and $p.B -lt 140) { $redPx++ }
            if ($p.G -gt 180 -and $p.R -lt 140 -and $p.B -lt 140) { $greenPx++ }
        }
    }
}
Write-Output ("右侧区域 红色像素={0} 绿色像素={1}" -f $redPx, $greenPx)

# 3) 内容存在性（有非透明像素）
$opaque = 0
for ($x = 0; $x -lt $w; $x += 2) {
    for ($y = 0; $y -lt $h; $y += 2) {
        if ($b.GetPixel($x, $y).A -gt 30) { $opaque++ }
    }
}
Write-Output ("非透明像素: {0}" -f $opaque)

$b.Save("D:\ipyProject\ai-contract\docs\screenshots\live-capsule.png", [System.Drawing.Imaging.ImageFormat]::Png)
$a.Dispose(); $b.Dispose()