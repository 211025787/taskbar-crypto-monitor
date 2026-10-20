# 修正探针：裁剪捕获区域避免越界伪影 + 正确的 Z 序列表 + 任务栏区域命中测试
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class ProbeB {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetDesktopWindow();

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int max);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT pt);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }
}
'@

$settings = [ProbeB]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
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

# 控制组：屏幕中部 (500,300)
[void][ProbeB]::SetWindowPos($settings, [IntPtr](-1), 500, 300, 0, 0, 0x10 -bor 0x1)
Start-Sleep -Milliseconds 600
$c1 = Count-Bright 500 300 384 400
Write-Output ("控制组(500,300) 顶部400px 高亮采样: {0}" -f $c1)

# 任务栏区域组：移到 (300,950)，仅捕获屏幕内 950..1066（高 116px）
[void][ProbeB]::SetWindowPos($settings, [IntPtr](-1), 300, 950, 0, 0, 0x10 -bor 0x1)
Start-Sleep -Milliseconds 600
$c2 = Count-Bright 300 950 384 116
Write-Output ("任务栏区组(300,950) 屏内116px 高亮采样: {0}" -f $c2)

if ($c2 -gt 300) { Write-Output "PROBE_B_VERDICT: PASS - 任务栏区域可以正常显示窗口（前次 0 为越界伪影）" }
else { Write-Output "PROBE_B_VERDICT: FAIL - 任务栏区域确实无法显示窗口内容" }

# --- 正确的 Z 序列表 ---
Write-Output "--- Z 序顶部窗口 ---"
$desktop = [ProbeB]::GetDesktopWindow()
$cur = [ProbeB]::GetWindow($desktop, 5)  # GW_CHILD：Z 序最高
$i = 0
while ($cur -ne [IntPtr]::Zero -and $i -lt 15) {
    $sb = New-Object System.Text.StringBuilder 256
    [void][ProbeB]::GetClassNameW($cur, $sb, 256)
    $ex = [ProbeB]::GetWindowLong($cur, -20)
    $r = New-Object ProbeB+RECT
    [void][ProbeB]::GetWindowRect($cur, [ref]$r)
    Write-Output ("{0}: class={1} ex=0x{2:X8} rect=({3},{4})-({5},{6})" -f $i, $sb.ToString(), $ex, $r.Left, $r.Top, $r.Right, $r.Bottom)
    $cur = [ProbeB]::GetWindow($cur, 2)  # GW_HWNDNEXT
    $i++
}

# --- 命中测试 ---
$pts = @(@(400, 500, "桌面中部"), @(400, 1035, "任务栏区"), @(600, 422, "原中央实验点"))
foreach ($p in $pts) {
    $pt = New-Object ProbeB+POINT
    $pt.X = $p[0]; $pt.Y = $p[1]
    $hit = [ProbeB]::WindowFromPoint($pt)
    $sb = New-Object System.Text.StringBuilder 256
    [void][ProbeB]::GetClassNameW($hit, $sb, 256)
    Write-Output ("WindowFromPoint({0} {1},{2}) -> {3}" -f $p[2], $p[0], $p[1], $sb.ToString())
}

# 恢复设置窗口到原始位置
[void][ProbeB]::SetWindowPos($settings, [IntPtr](-1), 656, 244, 0, 0, 0x10 -bor 0x1)
Write-Output "设置窗口已移回原位"