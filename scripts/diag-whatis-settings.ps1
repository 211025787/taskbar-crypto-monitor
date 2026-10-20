# 抓取设置窗口当前状态：PrintWindow 渲染内容 vs 屏幕实际内容 对照
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WhatIs {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$settings = [WhatIs]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
if ($settings -eq [IntPtr]::Zero) { Write-Output "FATAL: 设置窗口未找到"; exit 1 }
$rect = New-Object WhatIs+RECT
[void][WhatIs]::GetWindowRect($settings, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
$vis = [WhatIs]::IsWindowVisible($settings)
Write-Output ("设置窗口 rect=({0},{1}) {2}x{3} visible={4}" -f $rect.Left, $rect.Top, $w, $h, $vis)

# PrintWindow：WebView 渲染内容
$pw = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($pw)
$hdc = $g.GetHdc()
$ok = [WhatIs]::PrintWindow($settings, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()
$pw.Save("D:\ipyProject\ai-contract\docs\screenshots\whatis-printwindow.png", [System.Drawing.Imaging.ImageFormat]::Png)

# 屏幕捕获
$sc = New-Object System.Drawing.Bitmap($w, $h)
$g2 = [System.Drawing.Graphics]::FromImage($sc)
$g2.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
$g2.Dispose()
$sc.Save("D:\ipyProject\ai-contract\docs\screenshots\whatis-screen.png", [System.Drawing.Imaging.ImageFormat]::Png)

# 两图的亮度分布对照
foreach ($pair in @(@($pw, "PrintWindow"), @($sc, "屏幕"))) {
    $bmp = $pair[0]
    $bright = 0; $dark = 0; $n = 0
    for ($x = 0; $x -lt $w; $x += 5) {
        for ($y = 0; $y -lt $h; $y += 5) {
            $p = $bmp.GetPixel($x, $y)
            $n++
            if (($p.R + $p.G + $p.B) -gt 300) { $bright++ } elseif (($p.R + $p.G + $p.B) -lt 90) { $dark++ }
        }
    }
    Write-Output ("{0}: 亮={1} 暗={2} / {3}" -f $pair[1], $bright, $dark, $n)
}
# 中心像素值对照
$cpw = $pw.GetPixel([int]($w/2), [int]($h/2))
$csc = $sc.GetPixel([int]($w/2), [int]($h/2))
Write-Output ("中心像素 PrintWindow=({0},{1},{2}) 屏幕=({3},{4},{5})" -f $cpw.R, $cpw.G, $cpw.B, $csc.R, $csc.G, $csc.B)
$pw.Dispose(); $sc.Dispose()