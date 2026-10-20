# 尺寸临界扫描：设置窗口固定 (400,200)，逐级缩小高度/宽度，找可见性临界点
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class SizeScan {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$settings = [SizeScan]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
if ($settings -eq [IntPtr]::Zero) { Write-Output "FATAL: 设置窗口未找到"; exit 1 }

[void][SizeScan]::ShowWindow($settings, 5)
[void][SizeScan]::SetForegroundWindow($settings)
Start-Sleep -Seconds 1

function Test-At([int]$cw, [int]$ch, [string]$label) {
    [void][SizeScan]::SetWindowPos($settings, [IntPtr](-1), 400, 200, $cw, $ch, 0x10)
    Start-Sleep -Milliseconds 1500
    $r = New-Object SizeScan+RECT
    [void][SizeScan]::GetWindowRect($settings, [ref]$r)
    $rw = $r.Right - $r.Left; $rh = $r.Bottom - $r.Top
    $sc = New-Object System.Drawing.Bitmap($rw, $rh)
    $g = [System.Drawing.Graphics]::FromImage($sc)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($rw, $rh)))
    $g.Dispose()
    $pw = New-Object System.Drawing.Bitmap($rw, $rh)
    $g2 = [System.Drawing.Graphics]::FromImage($pw)
    $hdc = $g2.GetHdc()
    [void][SizeScan]::PrintWindow($settings, $hdc, 2)
    $g2.ReleaseHdc($hdc)
    $g2.Dispose()
    $sb = 0; $pb = 0; $n = 0
    for ($x = 0; $x -lt $rw; $x += 3) {
        for ($y = 0; $y -lt $rh; $y += 3) {
            $n++
            $ps = $sc.GetPixel($x, $y); $pp = $pw.GetPixel($x, $y)
            if (($ps.R + $ps.G + $ps.B) -gt 300) { $sb++ }
            if (($pp.R + $pp.G + $pp.B) -gt 300) { $pb++ }
        }
    }
    $sc.Dispose(); $pw.Dispose()
    # 可见性判定：屏幕亮占比 > PW 亮占比的 40% 视为可见
    $visRatio = if ($pb -gt 0) { [Math]::Round(100.0 * $sb / $pb) } else { -1 }
    $verdict = if ($visRatio -gt 40) { "可见" } else { "不可见" }
    Write-Output ("{0,-14} 实际{1}x{2} 屏幕亮={3,-5} PW亮={4,-5} 可见率={5}% {6}" -f $label, $rw, $rh, $sb, $pb, $visRatio, $verdict)
}

Write-Output "=== 高度扫描（宽 384 固定）==="
Test-At 384 527 "384x527"
Test-At 384 200 "384x200"
Test-At 384 100 "384x100"
Test-At 384 60 "384x60"
Test-At 384 44 "384x44"
Write-Output "=== 宽度扫描（高 44 固定）==="
Test-At 300 44 "300x44"
Test-At 250 44 "250x44"
Test-At 200 44 "200x44"
Test-At 175 44 "175x44"
Write-Output "=== 交叉验证 ==="
Test-At 175 100 "175x100"
Test-At 175 527 "175x527"
Test-At 500 44 "500x44"

# 恢复
[void][SizeScan]::SetWindowPos($settings, [IntPtr](-1), 656, 244, 384, 527, 0x10)
Write-Output "已恢复 384x527 @ (656,244)"