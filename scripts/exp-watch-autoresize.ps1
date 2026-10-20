# 监视设置窗口"自动全屏化"：缩小后高频轮询 rect+style，捕捉变化瞬间
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class WatchSize {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$settings = [WatchSize]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
if ($settings -eq [IntPtr]::Zero) { Write-Output "FATAL: 设置窗口未找到"; exit 1 }

[void][WatchSize]::ShowWindow($settings, 5)
[void][WatchSize]::SetForegroundWindow($settings)
Start-Sleep -Seconds 1

# 缩小到 175x44
[void][WatchSize]::SetWindowPos($settings, [IntPtr](-1), 400, 200, 175, 44, 0x10)

Write-Output "开始监视（每 150ms 轮询，共 12 秒）..."
$lastL = 400; $lastT = 200; $lastW = 175; $lastH = 44
$changed = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt 12000) {
    $r = New-Object WatchSize+RECT
    [void][WatchSize]::GetWindowRect($settings, [ref]$r)
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -ne $lastW -or $h -ne $lastH -or $r.Left -ne $lastL -or $r.Top -ne $lastT) {
        $style = [WatchSize]::GetWindowLong($settings, -16)
        $maxi = ($style -band 0x01000000) -ne 0
        Write-Output ("[{0}ms] rect=({1},{2}) {3}x{4} style=0x{5:X8} WS_MAXIMIZE={6}" -f $sw.ElapsedMilliseconds, $r.Left, $r.Top, $w, $h, $style, $maxi)
        $lastL = $r.Left; $lastT = $r.Top; $lastW = $w; $lastH = $h
        $changed = $true
    }
    Start-Sleep -Milliseconds 150
}
if (-not $changed) { Write-Output "12 秒内窗口尺寸未变化（未复现自动全屏化）" }

# 同时检查最终状态的可见性
$r2 = New-Object WatchSize+RECT
[void][WatchSize]::GetWindowRect($settings, [ref]$r2)
$w2 = $r2.Right - $r2.Left; $h2 = $r2.Bottom - $r2.Top
$sc = New-Object System.Drawing.Bitmap($w2, $h2)
$g = [System.Drawing.Graphics]::FromImage($sc)
$g.CopyFromScreen($r2.Left, $r2.Top, 0, 0, (New-Object System.Drawing.Size($w2, $h2)))
$g.Dispose()
$b = 0
for ($x = 0; $x -lt $w2; $x += 5) {
    for ($y = 0; $y -lt $h2; $y += 5) {
        $p = $sc.GetPixel($x, $y)
        if (($p.R + $p.G + $p.B) -gt 300) { $b++ }
    }
}
$sc.Dispose()
Write-Output ("最终状态: {0}x{1} 屏幕亮采样={2}" -f $w2, $h2, $b)

# 恢复
[void][WatchSize]::SetWindowPos($settings, [IntPtr](-1), 656, 244, 384, 527, 0x10)
Write-Output "已恢复 384x527"