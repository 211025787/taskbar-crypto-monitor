# 探针 C：对设置窗口逐项施加胶囊特征，二分定位破坏可见性的样式
# C1: 移除 WS_CAPTION（undecorated 化）  C2: +WS_EX_TOOLWINDOW  C3: +尺寸175x44
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class StyleProbe {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$settings = [StyleProbe]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
if ($settings -eq [IntPtr]::Zero) { Write-Output "FATAL: 设置窗口未找到"; exit 1 }

function Count-Bright([int]$x, [int]$y, [int]$cw, [int]$ch) {
    if ($cw -lt 4 -or $ch -lt 4) { return -1 }
    $bmp = New-Object System.Drawing.Bitmap($cw, $ch)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($cw, $ch)))
    $g.Dispose()
    $b = 0
    for ($ix = 0; $ix -lt $cw; $ix += 3) {
        for ($iy = 0; $iy -lt $ch; $iy += 3) {
            $p = $bmp.GetPixel($ix, $iy)
            if (($p.R + $p.G + $p.B) -gt 300) { $b++ }
        }
    }
    $bmp.Dispose()
    return $b
}

# 基线：原样式原位置（656,244 384x527）
$rect = New-Object StyleProbe+RECT
[void][StyleProbe]::GetWindowRect($settings, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
$baseStyle = [StyleProbe]::GetWindowLong($settings, -16)
$baseEx = [StyleProbe]::GetWindowLong($settings, -20)
Write-Output ("基线 style=0x{0:X8} ex=0x{1:X8} rect=({2},{3}) {4}x{5}" -f $baseStyle, $baseEx, $rect.Left, $rect.Top, $w, $h)
$base = Count-Bright $rect.Left $rect.Top $w $h
Write-Output ("基线高亮采样: {0}" -f $base)

# C1: 移除 WS_CAPTION(0x00C00000)，保留位置尺寸，SWP_FRAMECHANGED(0x20)
[void][StyleProbe]::SetWindowLong($settings, -16, $baseStyle -band (-bnot 0x00C00000))
[void][StyleProbe]::SetWindowPos($settings, [IntPtr]::Zero, 0, 0, 0, 0, 0x20 -bor 0x1 -bor 0x2 -bor 0x10)
Start-Sleep -Milliseconds 800
$r1 = New-Object StyleProbe+RECT
[void][StyleProbe]::GetWindowRect($settings, [ref]$r1)
$w1 = $r1.Right - $r1.Left; $h1 = $r1.Bottom - $r1.Top
$c1 = Count-Bright $r1.Left $r1.Top $w1 $h1
Write-Output ("C1(无WS_CAPTION): rect=({0},{1}) {2}x{3} 高亮={4} {5}" -f $r1.Left, $r1.Top, $w1, $h1, $c1, $(if ($c1 -gt 300) { "可见" } else { "不可见" }))

# C2: C1 + WS_EX_TOOLWINDOW(0x80)
[void][StyleProbe]::SetWindowLong($settings, -20, ([StyleProbe]::GetWindowLong($settings, -20)) -bor 0x80)
Start-Sleep -Milliseconds 800
$c2 = Count-Bright $r1.Left $r1.Top $w1 $h1
Write-Output ("C2(+TOOLWINDOW): 高亮={0} {1}" -f $c2, $(if ($c2 -gt 300) { "可见" } else { "不可见" }))

# C3: C2 + 缩小到 175x44
[void][StyleProbe]::SetWindowPos($settings, [IntPtr](-1), 500, 300, 175, 44, 0x10)
Start-Sleep -Milliseconds 800
$c3 = Count-Bright 500 300 175 44
Write-Output ("C3(+175x44): 高亮={0} {1}" -f $c3, $(if ($c3 -gt 100) { "可见" } else { "不可见" }))

# --- 恢复设置窗口全部原始状态 ---
[void][StyleProbe]::SetWindowLong($settings, -16, $baseStyle)
[void][StyleProbe]::SetWindowLong($settings, -20, $baseEx)
[void][StyleProbe]::SetWindowPos($settings, [IntPtr](-1), $rect.Left, $rect.Top, $w, $h, 0x20 -bor 0x10)
Write-Output "设置窗口已恢复原始样式与位置"