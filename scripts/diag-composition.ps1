# 综合诊断：胶囊窗口 EXSTYLE + 屏幕区域捕获 + PrintWindow 对比
# 目的：确认 DWM 合成问题当前状态（诊断用红色背景应出现在屏幕胶囊区域）
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class CapsuleDiag {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$capsule = [CapsuleDiag]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
if ($capsule -eq [IntPtr]::Zero) {
    Write-Output "FATAL: 胶囊窗口未找到"
    exit 1
}

$rect = New-Object CapsuleDiag+RECT
[void][CapsuleDiag]::GetWindowRect($capsule, [ref]$rect)
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
$exStyle = [CapsuleDiag]::GetWindowLong($capsule, -20)
$visible = [CapsuleDiag]::IsWindowVisible($capsule)
Write-Output ("HWND={0} RECT=({1},{2})-({3},{4}) {5}x{6}" -f $capsule, $rect.Left, $rect.Top, $rect.Right, $rect.Bottom, $w, $h)
Write-Output ("EXSTYLE=0x{0:X8} visible={1}" -f $exStyle, $visible)
Write-Output ("  WS_EX_TOPMOST(0x8)={0}" -f (($exStyle -band 0x8) -ne 0))
Write-Output ("  WS_EX_TRANSPARENT(0x20)={0}" -f (($exStyle -band 0x20) -ne 0))
Write-Output ("  WS_EX_TOOLWINDOW(0x80)={0}" -f (($exStyle -band 0x80) -ne 0))
Write-Output ("  WS_EX_WINDOWEDGE(0x100)={0}" -f (($exStyle -band 0x100) -ne 0))
Write-Output ("  WS_EX_APPWINDOW(0x40000)={0}" -f (($exStyle -band 0x40000) -ne 0))
Write-Output ("  WS_EX_LAYERED(0x80000)={0}" -f (($exStyle -band 0x80000) -ne 0))
Write-Output ("  WS_EX_NOREDIRECTIONBITMAP(0x200000)={0}" -f (($exStyle -band 0x200000) -ne 0))
Write-Output ("  未知位0x100000={0}" -f (($exStyle -band 0x100000) -ne 0))
Write-Output ("  WS_EX_NOACTIVATE(0x8000000)={0}" -f (($exStyle -band 0x8000000) -ne 0))

# --- 屏幕捕获（Capsule 区域，DPI-unaware 虚拟化坐标）---
try {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    $bmp.Save("D:\ipyProject\ai-contract\docs\screenshots\diag-screen-region.png", [System.Drawing.Imaging.ImageFormat]::Png)
    # 统计红色像素（诊断背景 rgb(255,0,0)）
    $redCount = 0; $nonDark = 0
    for ($x = 0; $x -lt $w; $x += 2) {
        for ($y = 0; $y -lt $h; $y += 2) {
            $p = $bmp.GetPixel($x, $y)
            if ($p.R -gt 200 -and $p.G -lt 80 -and $p.B -lt 80) { $redCount++ }
            if (($p.R + $p.G + $p.B) -gt 90) { $nonDark++ }
        }
    }
    $bmp.Dispose()
    Write-Output ("屏幕区域捕获成功: 红色像素(采样)={0} 非暗像素={1}" -f $redCount, $nonDark)
    if ($redCount -gt 100) { Write-Output "SCREEN_VERDICT: PASS - 诊断红色出现在屏幕上，DWM 合成正常" }
    else { Write-Output "SCREEN_VERDICT: FAIL - 屏幕上无胶囊内容（DWM 合成仍失败）" }
} catch {
    Write-Output "屏幕捕获异常: $($_.Exception.Message)"
}

# --- PrintWindow 对照 ---
$bmp2 = New-Object System.Drawing.Bitmap($w, $h)
$g2 = [System.Drawing.Graphics]::FromImage($bmp2)
$hdc = $g2.GetHdc()
$ok = [CapsuleDiag]::PrintWindow($capsule, $hdc, 2)
$g2.ReleaseHdc($hdc)
$g2.Dispose()
$redCount2 = 0
for ($x = 0; $x -lt $w; $x += 2) {
    for ($y = 0; $y -lt $h; $y += 2) {
        $p = $bmp2.GetPixel($x, $y)
        if ($p.R -gt 200 -and $p.G -lt 80 -and $p.B -lt 80) { $redCount2++ }
    }
}
$bmp2.Dispose()
Write-Output ("PrintWindow(PW_RENDERFULLCONTENT)={0}: 红色像素(采样)={1}" -f $ok, $redCount2)