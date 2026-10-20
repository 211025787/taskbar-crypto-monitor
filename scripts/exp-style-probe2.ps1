# 重做样式探针（修正版）：先 ShowWindow 建立可见基线，再逐项施加胶囊特征
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class StyleProbe2 {
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

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$settings = [StyleProbe2]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
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

# 显示设置窗口
[void][StyleProbe2]::ShowWindow($settings, 5)
[void][StyleProbe2]::SetForegroundWindow($settings)
Start-Sleep -Seconds 2

$rect = New-Object StyleProbe2+RECT
[void][StyleProbe2]::GetWindowRect($settings, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
$baseStyle = [StyleProbe2]::GetWindowLong($settings, -16)
$baseEx = [StyleProbe2]::GetWindowLong($settings, -20)
Write-Output ("显示后 style=0x{0:X8} ex=0x{1:X8} rect=({2},{3}) {4}x{5}" -f $baseStyle, $baseEx, $rect.Left, $rect.Top, $w, $h)

# 统一放到 (400,200) 固定位置测（排除位置因素）
[void][StyleProbe2]::SetWindowPos($settings, [IntPtr](-1), 400, 200, 0, 0, 0x10 -bor 0x1)
Start-Sleep -Milliseconds 800
$base = Count-Bright 400 200 $w $h
Write-Output ("基线(400,200): 高亮={0} {1}" -f $base, $(if ($base -gt 300) { "可见" } else { "不可见-实验无效" }))

if ($base -gt 300) {
    # C1: 移除 WS_CAPTION + WS_THICKFRAME？胶囊是 undecorated：先只移除 WS_CAPTION(0x00C00000)
    [void][StyleProbe2]::SetWindowLong($settings, -16, $baseStyle -band (-bnot 0x00C00000))
    [void][StyleProbe2]::SetWindowPos($settings, [IntPtr](-1), 0, 0, 0, 0, 0x20 -bor 0x1 -bor 0x2 -bor 0x10)
    Start-Sleep -Milliseconds 800
    $r1 = New-Object StyleProbe2+RECT
    [void][StyleProbe2]::GetWindowRect($settings, [ref]$r1)
    $w1 = $r1.Right - $r1.Left; $h1 = $r1.Bottom - $r1.Top
    $c1 = Count-Bright $r1.Left $r1.Top $w1 $h1
    Write-Output ("C1(无WS_CAPTION): {0}x{1} 高亮={2} {3}" -f $w1, $h1, $c1, $(if ($c1 -gt 300) { "可见" } else { "不可见" }))

    # C2: + WS_EX_TOOLWINDOW(0x80)
    [void][StyleProbe2]::SetWindowLong($settings, -20, ([StyleProbe2]::GetWindowLong($settings, -20)) -bor 0x80)
    Start-Sleep -Milliseconds 800
    $c2 = Count-Bright $r1.Left $r1.Top $w1 $h1
    Write-Output ("C2(+TOOLWINDOW): 高亮={0} {1}" -f $c2, $(if ($c2 -gt 300) { "可见" } else { "不可见" }))

    # C3: + WS_EX_NOACTIVATE(0x08000000)
    [void][StyleProbe2]::SetWindowLong($settings, -20, ([StyleProbe2]::GetWindowLong($settings, -20)) -bor 0x08000000)
    Start-Sleep -Milliseconds 800
    $c3 = Count-Bright $r1.Left $r1.Top $w1 $h1
    Write-Output ("C3(+NOACTIVATE): 高亮={0} {1}" -f $c3, $(if ($c3 -gt 300) { "可见" } else { "不可见" }))

    # C4: + 缩小到 175x44
    [void][StyleProbe2]::SetWindowPos($settings, [IntPtr](-1), 400, 200, 175, 44, 0x10)
    Start-Sleep -Milliseconds 1200
    $c4 = Count-Bright 400 200 175 44
    Write-Output ("C4(+175x44): 高亮={0} {1}" -f $c4, $(if ($c4 -gt 100) { "可见" } else { "不可见" }))

    # C5: 移到任务栏区域 (100,1021) 175x44
    [void][StyleProbe2]::SetWindowPos($settings, [IntPtr](-1), 100, 1021, 175, 44, 0x10)
    Start-Sleep -Milliseconds 1200
    $c5 = Count-Bright 100 1021 175 44
    Write-Output ("C5(任务栏区域): 高亮={0} {1}" -f $c5, $(if ($c5 -gt 100) { "可见" } else { "不可见" }))
}

# 恢复原始样式
[void][StyleProbe2]::SetWindowLong($settings, -16, $baseStyle)
[void][StyleProbe2]::SetWindowLong($settings, -20, $baseEx)
[void][StyleProbe2]::SetWindowPos($settings, [IntPtr](-1), 656, 244, $w, $h, 0x20 -bor 0x10)
Write-Output "设置窗口已恢复"