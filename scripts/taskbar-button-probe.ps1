# 用 UI Automation 在 Shell_TrayWnd 子树内定位设置窗口按钮矩形，从条带截图抠出图标区域分析颜色
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$out = @()
$vw = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$vh = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
$taskbarH = 34

# 1. 截整条任务栏
$bmp = New-Object System.Drawing.Bitmap $vw, $taskbarH
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, $vh - $taskbarH, 0, 0, (New-Object System.Drawing.Size $vw, $taskbarH))
$g.Dispose()

# 2. UIA：先定位任务栏宿主（Shell_TrayWnd），再在其子树内找按钮（避免匹配到设置窗口本体）
$root = [System.Windows.Automation.AutomationElement]::RootElement
$tbCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, "Shell_TrayWnd")
$taskbar = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $tbCond)
if (-not $taskbar) {
    "未找到 Shell_TrayWnd" | Out-File "D:\ipyProject\ai-contract\.taskbar-btn.txt" -Encoding utf8
    exit
}
$nameCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, "设置 - Taskbar Crypto Monitor")
$btn = $taskbar.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCond)

if ($btn) {
    $r = $btn.Current.BoundingRectangle
    $out += "任务栏按钮矩形: X=$([math]::Round($r.X)) Y=$([math]::Round($r.Y)) W=$([math]::Round($r.Width)) H=$([math]::Round($r.Height))"
    $bx = [math]::Round($r.X); $bw = [math]::Round($r.Width)
    # 按钮可能很宽（带标签）；图标固定在按钮左侧 24x24 区域
    if ($bw -gt 0 -and $bx -ge 0 -and ($bx + $bw) -le $vw) {
        $icon = New-Object System.Drawing.Bitmap ([math]::Min($bw, 80)), $taskbarH
        $ig = [System.Drawing.Graphics]::FromImage($icon)
        $cropW = [math]::Min($bw, 80)
        $ig.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0, 0, $cropW, $taskbarH), (New-Object System.Drawing.Rectangle $bx, 0, $cropW, $taskbarH), [System.Drawing.GraphicsUnit]::Pixel)
        $ig.Dispose()
        $icon.Save("D:\ipyProject\ai-contract\docs\screenshots\taskbar-button.png")
        # 图标区：按钮左侧中心 20x24
        $dark = 0; $blue = 0; $green = 0; $light = 0; $total = 0
        for ($x = 2; $x -lt [math]::Min($cropW - 2, 22); $x++) {
            for ($y = 4; $y -lt [math]::Min($taskbarH - 4, 30); $y++) {
                $p = $icon.GetPixel($x, $y)
                $total++
                $sum = $p.R + $p.G + $p.B
                if ($sum -lt 100) { $dark++ }
                if ($p.B -gt $p.R + 25 -and $p.B -gt 60) { $blue++ }
                if ($p.G -gt $p.B + 25 -and $p.G -gt 110) { $green++ }
                if ($sum -gt 500) { $light++ }
            }
        }
        $out += "按钮图标区采样 $total：暗 $dark 蓝 $blue 绿 $green 亮 $light"
        $detail = @()
        for ($y = 6; $y -lt 28; $y += 3) {
            $p = $icon.GetPixel(12, $y)
            $detail += "(12,$y)=($($p.R),$($p.G),$($p.B))"
        }
        $out += "图标中心列颜色: " + ($detail -join " ")
    }
} else {
    $out += "Shell_TrayWnd 子树内未找到按钮（设置窗口可能已隐藏）"
}
$out | Out-File "D:\ipyProject\ai-contract\.taskbar-btn.txt" -Encoding utf8