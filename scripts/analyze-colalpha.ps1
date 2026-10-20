# 逐列 alpha 分布：看清胶囊实际渲染布局与内容边界
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class ColAlpha {
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

$capsule = [ColAlpha]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
$rect = New-Object ColAlpha+RECT
[void][ColAlpha]::GetWindowRect($capsule, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
Write-Output ("窗口 {0}x{1} 逐列非透明像素数（每列 0..{2}）：" -f $w, $h, $h)

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[void][ColAlpha]::PrintWindow($capsule, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()

# 按 8 列一组输出，便于阅读
for ($x0 = 0; $x0 -lt $w; $x0 += 8) {
    $line = ""
    for ($x = $x0; $x -lt [Math]::Min($x0 + 8, $w); $x++) {
        $c = 0
        for ($y = 0; $y -lt $h; $y++) {
            if ($bmp.GetPixel($x, $y).A -gt 30) { $c++ }
        }
        $line += ("{0,3} " -f $c)
    }
    Write-Output ("x{0,3}: {1}" -f $x0, $line)
}
$bmp.Dispose()