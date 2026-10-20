# 决定性实验：弹出设置窗口 + 截取任务栏条带，分析任务栏按钮图标的真实颜色
# 方法论说明：CopyFromScreen 对 <384x200 的小窗口失效（MPO 假象），但任务栏条带宽 1707（虚拟坐标）
# 远超宽度临界，属于可捕获区域；高度仅 32px 是否可捕获即本实验要验证的点。
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class IconProbe2 {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
$out = @()

# 1. 找到设置窗口并显示
$target = (Get-Process -Name taskbar-crypto-monitor -ErrorAction SilentlyContinue).Id
if (-not $target) { "应用未运行" | Out-File "D:\ipyProject\ai-contract\.taskbar-shot.txt"; exit }
$settingsHwnd = [IntPtr]::Zero
$cb = {
    param($h, $l)
    $wpid = 0
    [IconProbe2]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
    if ($wpid -eq $target) {
        $sb = New-Object System.Text.StringBuilder 256
        [IconProbe2]::GetWindowTextW($h, $sb, 256) | Out-Null
        if ($sb.ToString() -like "*设置*") { $script:settingsHwnd = $h }
    }
    return $true
}
[IconProbe2]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
if ($settingsHwnd -eq [IntPtr]::Zero) {
    "未找到设置窗口" | Out-File "D:\ipyProject\ai-contract\.taskbar-shot.txt"
    exit
}
[IconProbe2]::ShowWindow($settingsHwnd, 5) | Out-Null  # SW_SHOW
Start-Sleep -Seconds 2

# 2. 截取整个任务栏条带（虚拟坐标：屏幕底部 32px 高）
$vw = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$vh = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
$taskbarH = 34
$bmp = New-Object System.Drawing.Bitmap $vw, $taskbarH
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, $vh - $taskbarH, 0, 0, (New-Object System.Drawing.Size $vw, $taskbarH))
$g.Dispose()
$bmp.Save("D:\ipyProject\ai-contract\docs\screenshots\taskbar-strip.png")

# 3. 统计条带内颜色分布（任务栏背景浅灰 vs 深色主题 vs 图标色块）
$dark = 0; $blue = 0; $green = 0; $total = 0
for ($x = 0; $x -lt $vw; $x += 2) {
    for ($y = 0; $y -lt $taskbarH; $y += 2) {
        $p = $bmp.GetPixel($x, $y)
        $total++
        $sum = $p.R + $p.G + $p.B
        if ($sum -lt 90) { $dark++ }
        if ($p.B -gt $p.R + 25 -and $p.B -gt 60) { $blue++ }
        if ($p.G -gt $p.B + 25 -and $p.G -gt 120) { $green++ }
    }
}
$out += "条带 ${vw}x${taskbarH} 采样 $total：暗色 $dark 蓝色 $blue 绿色 $green"
# 4. 列出暗色像素的水平分布区间（定位黑色图标在任务栏的位置）
$ranges = @()
$inRange = $false; $start = 0
for ($x = 0; $x -lt $vw; $x += 1) {
    $colDark = 0
    for ($y = 4; $y -lt $taskbarH - 4; $y += 2) {
        $p = $bmp.GetPixel($x, $y)
        if (($p.R + $p.G + $p.B) -lt 90) { $colDark++ }
    }
    if ($colDark -ge 3 -and -not $inRange) { $inRange = $true; $start = $x }
    if (($colDark -lt 3) -and $inRange) { $inRange = $false; $ranges += "$start..$($x-1)" }
}
if ($inRange) { $ranges += "$start..$($vw-1)" }
$out += "暗色竖直区间: " + ($ranges -join "  ")
$out | Out-File "D:\ipyProject\ai-contract\.taskbar-shot.txt" -Encoding utf8