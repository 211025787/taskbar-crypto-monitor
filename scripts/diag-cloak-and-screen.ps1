# 判定性诊断：CopyFromScreen 环境健康度 + DWM cloaked 状态
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class CloakDiag {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int val, int size);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

# --- 检查 1：CopyFromScreen 对非胶囊区域（任务栏中部 + 屏幕中心）---
function Test-Region([int]$x, [int]$y, [int]$w, [int]$h, [string]$label) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    $sum = 0; $maxSum = 0; $samples = @()
    for ($ix = 0; $ix -lt $w; $ix += 4) {
        for ($iy = 0; $iy -lt $h; $iy += 4) {
            $p = $bmp.GetPixel($ix, $iy)
            $s = $p.R + $p.G + $p.B
            $sum += $s
            if ($s -gt $maxSum) { $maxSum = $s }
        }
    }
    # 采样几个具体像素值
    $c = $bmp.GetPixel([int]($w/2), [int]($h/2))
    $bmp.Dispose()
    Write-Output ("{0}: 中心和=({1},{2},{3}) 最大亮度和={4}" -f $label, $c.R, $c.G, $c.B, $maxSum)
    if ($maxSum -le 30) { Write-Output "  -> 全黑，CopyFromScreen 环境异常" }
    else { Write-Output "  -> 有真实内容，CopyFromScreen 正常" }
}

Test-Region 300 1021 200 44 "任务栏中部(无胶囊区域)"
Test-Region 700 500 100 100 "屏幕中心"

# --- 检查 2：DWM cloaked 状态 ---
$capsule = [CloakDiag]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
if ($capsule -ne [IntPtr]::Zero) {
    $cloaked = 0
    $hr = [CloakDiag]::DwmGetWindowAttribute($capsule, 14, [ref]$cloaked, 4)
    Write-Output ("DWMWA_CLOAKED hr=0x{0:X} value={1}" -f $hr, $cloaked)
    if ($cloaked -band 1) { Write-Output "  -> DWM_CLOAKED_APP（应用被 cloak，如虚拟桌面/挂起）" }
    if ($cloaked -band 2) { Write-Output "  -> DWM_CLOAKED_SHELL（Shell cloak）" }
    if ($cloaked -band 4) { Write-Output "  -> DWM_CLOAKED_INHERITED（继承 cloak）" }
    if ($cloaked -eq 0 -and $hr -eq 0) { Write-Output "  -> 未 cloak" }
} else {
    Write-Output "胶囊窗口未找到"
}