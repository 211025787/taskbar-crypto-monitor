# 决定性验证：对比应用运行中与退出后的屏幕像素差分
# 差分区域 = 胶囊窗口在屏幕上的真实视觉贡献
Add-Type -AssemblyName System.Windows.Forms,System.Drawing

function Take-Shot([string]$path) {
    $bmp = New-Object System.Drawing.Bitmap(1707, 300)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    # 屏幕底部 300px（任务栏区域）
    $g.CopyFromScreen(0, 767, 0, 0, (New-Object System.Drawing.Size(1707, 300)))
    $g.Dispose()
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# 第一张：应用运行中
Take-Shot "D:\ipyProject\ai-contract\docs\screenshots\diff-with-app.png"
Write-Output "SHOT_A_DONE"

# 杀掉应用
Stop-Process -Name "taskbar-crypto-monitor" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Output "APP_KILLED"

# 第二张：应用退出后
Take-Shot "D:\ipyProject\ai-contract\docs\screenshots\diff-without-app.png"
Write-Output "SHOT_B_DONE"

# 像素差分：亮度差超过 8 视为胶囊贡献
$a = [System.Drawing.Image]::FromFile("D:\ipyProject\ai-contract\docs\screenshots\diff-with-app.png")
$b = [System.Drawing.Image]::FromFile("D:\ipyProject\ai-contract\docs\screenshots\diff-without-app.png")
$diffCount = 0
$diffBoundsMinX = 9999; $diffBoundsMaxX = -1
for ($x = 0; $x -lt 1707; $x += 1) {
    for ($y = 0; $y -lt 300; $y += 1) {
        $pa = $a.GetPixel($x, $y)
        $pb = $b.GetPixel($x, $y)
        $diff = [Math]::Abs($pa.R - $pb.R) + [Math]::Abs($pa.G - $pb.G) + [Math]::Abs($pa.B - $pb.B)
        if ($diff -gt 24) {
            $diffCount++
            if ($x -lt $diffBoundsMinX) { $diffBoundsMinX = $x }
            if ($x -gt $diffBoundsMaxX) { $diffBoundsMaxX = $x }
        }
    }
}
$a.Dispose()
$b.Dispose()
Write-Output "差分像素数: $diffCount (阈值: RGB分量和>24)"
Write-Output "差异X范围: $diffBoundsMinX .. $diffBoundsMaxX (胶囊预期 X=43..415)"
if ($diffCount -gt 500) { Write-Output "VERDICT: PASS - 胶囊在屏幕上有真实视觉贡献" } else { Write-Output "VERDICT: FAIL - 胶囊对屏幕像素无贡献" }