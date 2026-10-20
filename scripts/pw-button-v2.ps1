# UIA 遍历任务栏按钮（含胶囊窗口按钮）→ PrintWindow 同坐标系抠图 → 颜色统计
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PW2 {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
$out = @()
$th = [PW2]::FindWindowW("Shell_TrayWnd", $null)
if ($th -eq [IntPtr]::Zero) { $out += "未找到 Shell_TrayWnd"; $out | Out-File "D:\ipyProject\ai-contract\.pw-btn2.txt" -Encoding utf8; exit }
$rect = New-Object PW2+RECT
[PW2]::GetWindowRect($th, [ref]$rect) | Out-Null
$w = $rect.R - $rect.L; $h = $rect.B - $rect.T
$out += "任务栏 PrintWindow 尺寸: ${w}x${h}"
# PrintWindow 抓任务栏（与 GetWindowRect/UIA 同为虚拟坐标系）
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
[PW2]::PrintWindow($th, $hdc, 2) | Out-Null
$g.ReleaseHdc($hdc)
$g.Dispose()
$bmp.Save("D:\ipyProject\ai-contract\docs\screenshots\pw-taskbar.png")

# UIA 遍历 Shell_TrayWnd 子树内的按钮
$root = [System.Windows.Automation.AutomationElement]::RootElement
$tbCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, "Shell_TrayWnd")
$taskbar = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $tbCond)
if (-not $taskbar) { $out += "UIA 未找到 Shell_TrayWnd"; $out | Out-File "D:\ipyProject\ai-contract\.pw-btn2.txt" -Encoding utf8; exit }
$btnCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
$buttons = $taskbar.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnCond)
$out += "UIA 按钮总数: $($buttons.Count)"
$idx = 0
foreach ($b in $buttons) {
    $name = $b.Current.Name
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "(无名)" }
    if ($name -notmatch "Taskbar|Crypto|设置") { continue }
    $r = $b.Current.BoundingRectangle
    $bx = [math]::Round($r.X); $by = [math]::Round($r.Y); $bw = [math]::Round($r.Width); $bh = [math]::Round($r.Height)
    $out += "[$idx] '$name' X=$bx Y=$by W=$bw H=$bh"
    # UIA 返回物理坐标，PrintWindow 为虚拟坐标（DPI unaware 1707 宽），除以 1.5 换算
    $rx = [int](($bx - $rect.L * 1.5) / 1.5); $ry = [int](($by - $rect.T * 1.5) / 1.5)
    $rw = [int]($bw / 1.5); $rh = [int]($bh / 1.5)
    if ($rw -gt 0 -and $rw -le $w -and $rx -ge 0 -and ($rx + $rw) -le $w -and $rh -gt 0 -and $rh -le $h) {
        $crop = New-Object System.Drawing.Bitmap $rw, $rh
        $cg = [System.Drawing.Graphics]::FromImage($crop)
        $cg.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0, 0, $rw, $rh), (New-Object System.Drawing.Rectangle $rx, $ry, $rw, $rh), [System.Drawing.GraphicsUnit]::Pixel)
        $cg.Dispose()
        $crop.Save("D:\ipyProject\ai-contract\docs\screenshots\pw-btn-$idx.png")
        # 图标在按钮左侧（Win11 按钮内图标居中，取左半区域统计）
        $statW = [math]::Min($rw, 28)
        $dark = 0; $blue = 0; $green = 0; $light = 0; $total = 0
        for ($x = 0; $x -lt $statW; $x += 1) {
            for ($y = 0; $y -lt $rh; $y += 1) {
                $p = $crop.GetPixel($x, $y)
                $total++
                $sum = $p.R + $p.G + $p.B
                if ($sum -lt 100) { $dark++ }
                if ($p.B -gt $p.R + 25 -and $p.B -gt 60) { $blue++ }
                if ($p.G -gt $p.B + 25 -and $p.G -gt 110) { $green++ }
                if ($sum -gt 500) { $light++ }
            }
        }
        $out += "[$idx] 按钮区采样 $total：暗 $dark 蓝 $blue 绿 $green 亮 $light"
        $detail = @()
        $cx = [math]::Min($statW - 1, 10)
        for ($y = 0; $y -lt $rh; $y += 3) {
            $p = $crop.GetPixel($cx, $y)
            $detail += "($cx,$y)=($($p.R),$($p.G),$($p.B))"
        }
        $out += "[$idx] 中心列颜色: " + ($detail -join " ")
    } else {
        $out += "[$idx] 矩形越界 rx=$rx ry=$ry"
    }
    $idx++
}
$out | Out-File "D:\ipyProject\ai-contract\.pw-btn2.txt" -Encoding utf8