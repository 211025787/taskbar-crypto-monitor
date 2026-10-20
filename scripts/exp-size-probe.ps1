# C4 深挖：缩小设置窗口到 175x44，用真实 rect 双测（屏幕 + PrintWindow）
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class SmallProbe {
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

$settings = [SmallProbe]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
if ($settings -eq [IntPtr]::Zero) { Write-Output "FATAL: 设置窗口未找到"; exit 1 }

[void][SmallProbe]::ShowWindow($settings, 5)
[void][SmallProbe]::SetForegroundWindow($settings)
Start-Sleep -Seconds 1

function Get-Rect([IntPtr]$h) {
    $r = New-Object SmallProbe+RECT
    [void][SmallProbe]::GetWindowRect($h, [ref]$r)
    return $r
}
function Test-Window([IntPtr]$h, [string]$label, [int]$waitMs) {
    Start-Sleep -Milliseconds $waitMs
    $r = Get-Rect $h
    $w = $r.Right - $r.Left; $hgt = $r.Bottom - $r.Top
    # 屏幕捕获（按真实 rect）
    $sc = New-Object System.Drawing.Bitmap($w, $hgt)
    $g = [System.Drawing.Graphics]::FromImage($sc)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $hgt)))
    $g.Dispose()
    # PrintWindow
    $pw = New-Object System.Drawing.Bitmap($w, $hgt)
    $g2 = [System.Drawing.Graphics]::FromImage($pw)
    $hdc = $g2.GetHdc()
    [void][SmallProbe]::PrintWindow($h, $hdc, 2)
    $g2.ReleaseHdc($hdc)
    $g2.Dispose()
    $sb = 0; $pb = 0
    for ($x = 0; $x -lt $w; $x += 3) {
        for ($y = 0; $y -lt $hgt; $y += 3) {
            $ps = $sc.GetPixel($x, $y); $pp = $pw.GetPixel($x, $y)
            if (($ps.R + $ps.G + $ps.B) -gt 300) { $sb++ }
            if (($pp.R + $pp.G + $pp.B) -gt 300) { $pb++ }
        }
    }
    $sc.Dispose(); $pw.Dispose()
    Write-Output ("{0}: rect=({1},{2}) {3}x{4} 屏幕亮={5} PW亮={6}" -f $label, $r.Left, $r.Top, $w, $hgt, $sb, $pb)
    return $r
}

Test-Window $settings "基线" 800

# 缩小到 175x44（与胶囊一致），多时间点观测
[void][SmallProbe]::SetWindowPos($settings, [IntPtr](-1), 400, 200, 175, 44, 0x10)
Test-Window $settings "缩小后0.5s" 500
Test-Window $settings "缩小后2s" 1500
Test-Window $settings "缩小后5s" 3000

# 尝试触发重绘：最小化再还原
[void][SmallProbe]::ShowWindow($settings, 6)  # SW_MINIMIZE
Start-Sleep -Milliseconds 500
[void][SmallProbe]::ShowWindow($settings, 9)  # SW_RESTORE
Test-Window $settings "最小化还原后" 1500

# 逐步尺寸实验：找出可见性临界尺寸
foreach ($sz in @(@(384, 100), @(384, 60), @(384, 44), @(250, 44), @(175, 60), @(175, 44))) {
    [void][SmallProbe]::SetWindowPos($settings, [IntPtr](-1), 400, 200, $sz[0], $sz[1], 0x10)
    $r = Test-Window $settings ("尺寸{0}x{1}" -f $sz[0], $sz[1]) 1500
}

# 恢复
[void][SmallProbe]::SetWindowPos($settings, [IntPtr](-1), 656, 244, 384, 527, 0x10)
Write-Output "已恢复"
