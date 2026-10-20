# PrintWindow 抓取 Shell_TrayWnd 任务栏窗口内容（PW_RENDERFULLCONTENT=2），抠出按钮图标区域分析颜色
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PW {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
$th = [IntPtr]::Zero
$th = [PW]::FindWindowW("Shell_TrayWnd", $null)
if ($th -eq [IntPtr]::Zero) { "未找到 Shell_TrayWnd" | Out-File "D:\ipyProject\ai-contract\.pw-taskbar.txt"; exit }
$rect = New-Object PW+RECT
[PW]::GetWindowRect($th, [ref]$rect) | Out-Null
"w=$($rect.R - $rect.L) h=$($rect.B - $rect.T)" | Out-File "D:\ipyProject\ai-contract\.pw-taskbar.txt" -Append
$w = $rect.R - $rect.L; $h = $rect.B - $rect.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[PW]::PrintWindow($th, $hdc, 2) | Out-Null
$g.ReleaseHdc($hdc)
$g.Dispose()
$bmp.Save("D:\ipyProject\ai-contract\docs\screenshots\pw-taskbar.png")
# 统计整条颜色
$dark = 0; $blue = 0; $green = 0; $total = 0
for ($x = 0; $x -lt $w; $x += 3) {
    for ($y = 0; $y -lt $h; $y += 3) {
        $p = $bmp.GetPixel($x, $y)
        $total++
        $sum = $p.R + $p.G + $p.B
        if ($sum -lt 90) { $dark++ }
        if ($p.B -gt $p.R + 25 -and $p.B -gt 60) { $blue++ }
        if ($p.G -gt $p.B + 25 -and $p.G -gt 110) { $green++ }
    }
}
"采样 $total 暗 $dark 蓝 $blue 绿 $green" | Out-File "D:\ipyProject\ai-contract\.pw-taskbar.txt" -Append
# 按物理坐标抠按钮：UIA 虚拟 X=1757 W=66 → 物理 = 虚拟*1.5
$bx = [int](1757 * 1.5); $bw = [int](66 * 1.5)
if (($bx + $bw) -le $w) {
    $icon = New-Object System.Drawing.Bitmap $bw, $h
    $ig = [System.Drawing.Graphics]::FromImage($icon)
    $ig.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0, 0, $bw, $h), (New-Object System.Drawing.Rectangle $bx, 0, $bw, $h), [System.Drawing.GraphicsUnit]::Pixel)
    $ig.Dispose()
    $icon.Save("D:\ipyProject\ai-contract\docs\screenshots\pw-button.png")
    $dark2 = 0; $blue2 = 0; $total2 = 0
    for ($x = 4; $x -lt $bw - 4; $x += 2) {
        for ($y = 4; $y -lt ($h - 4); $y += 2) {
            $p = $icon.GetPixel($x, $y)
            $total2++
            $sum = $p.R + $p.G + $p.B
            if ($sum -lt 90) { $dark2++ }
            if ($p.B -gt $p.R + 25 -and $p.B -gt 60) { $blue2++ }
        }
    }
    "按钮区采样 $total2 暗 $dark2 蓝 $blue2" | Out-File "D:\ipyProject\ai-contract\.pw-taskbar.txt" -Append
}