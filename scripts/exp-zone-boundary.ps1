# 关键实验：不透明胶囊移到屏幕中央测可见性 + 设置窗口顶边位置二分边界
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class ZoneTest {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$capsule = [ZoneTest]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
$settings = [ZoneTest]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
if ($capsule -eq [IntPtr]::Zero) { Write-Output "FATAL: 胶囊未找到"; exit 1 }

function Count-Red([int]$x, [int]$y, [int]$cw, [int]$ch) {
    $bmp = New-Object System.Drawing.Bitmap($cw, $ch)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($cw, $ch)))
    $g.Dispose()
    $red = 0
    for ($ix = 0; $ix -lt $cw; $ix += 2) {
        for ($iy = 0; $iy -lt $ch; $iy += 2) {
            $p = $bmp.GetPixel($ix, $iy)
            if ($p.R -gt 200 -and $p.G -lt 80 -and $p.B -lt 80) { $red++ }
        }
    }
    $bmp.Dispose()
    return $red
}
function Count-Bright([int]$x, [int]$y, [int]$cw, [int]$ch) {
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

# --- 1. 不透明胶囊移到屏幕中央 ---
$cr = New-Object ZoneTest+RECT
[void][ZoneTest]::GetWindowRect($capsule, [ref]$cr)
$cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
[void][ZoneTest]::SetWindowPos($capsule, [IntPtr](-1), 600, 400, 0, 0, 0x10 -bor 0x1)
Start-Sleep -Milliseconds 800
$red = Count-Red 600 400 $cw $ch
Write-Output ("不透明胶囊@(600,400) 红色采样: {0}" -f $red)
if ($red -gt 100) { Write-Output "  -> 中央可见！问题与底部位置相关" } else { Write-Output "  -> 中央也不可见，与位置无关" }
# 移回
[void][ZoneTest]::SetWindowPos($capsule, [IntPtr](-1), $cr.Left, $cr.Top, 0, 0, 0x10 -bor 0x1)

# --- 2. 设置窗口顶边位置边界二分 ---
if ($settings -ne [IntPtr]::Zero) {
    Write-Output "--- 设置窗口顶边扫描（捕获各位置顶部60px条带）---"
    foreach ($top in @(700, 780, 860, 920, 950)) {
        [void][ZoneTest]::SetWindowPos($settings, [IntPtr](-1), 300, $top, 0, 0, 0x10 -bor 0x1)
        Start-Sleep -Milliseconds 700
        $b = Count-Bright 300 $top 384 60
        Write-Output ("top={0}: 高亮采样={1} {2}" -f $top, $b, $(if ($b -gt 150) { "可见" } else { "不可见" }))
    }
    [void][ZoneTest]::SetWindowPos($settings, [IntPtr](-1), 656, 244, 0, 0, 0x10 -bor 0x1)
    Write-Output "设置窗口已移回原位"
}