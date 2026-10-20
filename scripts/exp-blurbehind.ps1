# 决定性实验：运行时禁用/重启用胶囊窗口的 DWM blur-behind，观察屏幕可见性变化
# tao 的透明方案 = DwmEnableBlurBehindWindow(空区域)；若该技巧在本机异常导致全透明，
# 禁用后窗口应恢复不透明合成（红色诊断背景应立即出现在屏幕上）
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class BlurTest {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("dwmapi.dll")]
    public static extern int DwmEnableBlurBehindWindow(IntPtr hwnd, ref DWM_BLURBEHIND pBlurBehind);

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public struct DWM_BLURBEHIND {
        public uint dwFlags;      // DWM_BB_ENABLE = 0x1
        public int fEnable;       // BOOL
        public IntPtr hRgnBlur;   // HRGN
        public int fTransitionOnMaximized; // BOOL
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$capsule = [BlurTest]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
if ($capsule -eq [IntPtr]::Zero) { Write-Output "FATAL: 胶囊窗口未找到"; exit 1 }

$rect = New-Object BlurTest+RECT
[void][BlurTest]::GetWindowRect($capsule, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
Write-Output ("胶囊 RECT=({0},{1})-({2},{3})" -f $rect.Left, $rect.Top, $rect.Right, $rect.Bottom)

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

$before = Count-Red $rect.Left $rect.Top $w $h
Write-Output "禁用前屏幕红色采样: $before"

# 禁用 blur-behind（DWM_BB_ENABLE=0x1, fEnable=0）
$bb = New-Object BlurTest+DWM_BLURBEHIND
$bb.dwFlags = 0x1
$bb.fEnable = 0
$bb.hRgnBlur = [IntPtr]::Zero
$bb.fTransitionOnMaximized = 0
$hr = [BlurTest]::DwmEnableBlurBehindWindow($capsule, [ref]$bb)
Write-Output ("DwmEnableBlurBehindWindow(disable) hr=0x{0:X8}" -f $hr)

Start-Sleep -Milliseconds 800
$after = Count-Red $rect.Left $rect.Top $w $h
Write-Output "禁用后屏幕红色采样: $after"
if ($after -gt 100) {
    Write-Output "VERDICT: 现形！blur-behind 空区域技巧是全透明的元凶"
} else {
    Write-Output "VERDICT: 仍不可见，blur-behind 非唯一因素"
    # 恢复 blur-behind 启用状态（保持环境一致）
    $bb2 = New-Object BlurTest+DWM_BLURBEHIND
    $bb2.dwFlags = 0x1
    $bb2.fEnable = 1
    $hr2 = [BlurTest]::DwmEnableBlurBehindWindow($capsule, [ref]$bb2)
    Write-Output ("恢复 blur-behind hr=0x{0:X8}" -f $hr2)
}