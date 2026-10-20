# 探针：把设置窗口变成 TOPMOST+NOACTIVATE 并移到任务栏区域，观察是否保持屏幕可见
# 若保持可见 → 排除 Z 序/前台因素，锁定 transparent 为唯一嫌疑
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class ProbeA {
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

$settings = [ProbeA]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
if ($settings -eq [IntPtr]::Zero) { Write-Output "FATAL: 设置窗口未找到"; exit 1 }

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

$rect = New-Object ProbeA+RECT
[void][ProbeA]::GetWindowRect($settings, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top

$before = Count-Bright $rect.Left $rect.Top $w $h
Write-Output ("基线（当前位置可见内容采样）: {0}" -f $before)

# 探针 A：TOPMOST + NOACTIVATE
[void][ProbeA]::SetWindowPos($settings, [IntPtr](-1), 0, 0, 0, 0, 0x10 -bor 0x2 -bor 0x1)  # NOACTIVATE|NOMOVE|NOSIZE
$ex = [ProbeA]::GetWindowLong($settings, -20)
[void][ProbeA]::SetWindowLong($settings, -20, $ex -bor 0x08000000)  # WS_EX_NOACTIVATE
Start-Sleep -Milliseconds 600
$afterA = Count-Bright $rect.Left $rect.Top $w $h
Write-Output ("TOPMOST+NOACTIVATE 后: {0}" -f $afterA)

# 探针 B：移动到任务栏区域（底部，与胶囊同排）
[void][ProbeA]::SetWindowPos($settings, [IntPtr](-1), 300, 980, $w, $h, 0x10)
Start-Sleep -Milliseconds 600
$afterB = Count-Bright 300 980 $w $h
Write-Output ("移到任务栏区域后: {0}" -f $afterB)

if ($afterA -gt 500 -and $afterB -gt 500) {
    Write-Output "PROBE_VERDICT: PASS - TOPMOST/NOACTIVATE/任务栏区域均不影响可见性，transparent 是唯一剩余嫌疑"
} else {
    Write-Output "PROBE_VERDICT: FAIL - Z 序或任务栏区域即足以破坏可见性"
    # 恢复位置
    [void][ProbeA]::SetWindowPos($settings, [IntPtr](-1), $rect.Left, $rect.Top, 0, 0, 0x10 -bor 0x1)
}