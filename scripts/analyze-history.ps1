# 历史截图像素分析：判断原型阶段（16:41）胶囊是否真的在屏幕上可见
Add-Type -AssemblyName System.Drawing

function Analyze-Image([string]$path, [string]$label) {
    if (-not (Test-Path $path)) { Write-Output "${label}: 文件不存在"; return }
    $a = [System.Drawing.Image]::FromFile($path)
    Write-Output ("{0}: {1}x{2}" -f $label, $a.Width, $a.Height)
    $redCount = 0; $bright = 0; $total = 0
    for ($x = 0; $x -lt $a.Width; $x += 2) {
        for ($y = 0; $y -lt $a.Height; $y += 2) {
            $p = $a.GetPixel($x, $y)
            $total++
            if ($p.R -gt 200 -and $p.G -lt 80 -and $p.B -lt 80) { $redCount++ }
            if (($p.R + $p.G + $p.B) -gt 300) { $bright++ }
        }
    }
    $a.Dispose()
    Write-Output ("  红色像素={0} 高亮像素={1} 总采样={2}" -f $redCount, $bright, $total)
}

# 16:41 原型阶段差分两张
Analyze-Image "D:\ipyProject\ai-contract\docs\screenshots\diff-with-app.png" "16:41 diff-with-app"
Analyze-Image "D:\ipyProject\ai-contract\docs\screenshots\diff-without-app.png" "16:41 diff-without-app"

# 18:33 迭代2 差分两张
Analyze-Image "D:\ipyProject\ai-contract\docs\screenshots\diff-alive.png" "18:33 diff-alive"
Analyze-Image "D:\ipyProject\ai-contract\docs\screenshots\diff-dead.png" "18:33 diff-dead"

# 原型任务栏区域截图
Analyze-Image "D:\ipyProject\ai-contract\docs\screenshots\prototype-taskbar-area-v2.png" "16:28 prototype-taskbar-area-v2"

# 两阶段 diff 对比对（16:41 是否有真实差异）
$a1 = [System.Drawing.Image]::FromFile("D:\ipyProject\ai-contract\docs\screenshots\diff-with-app.png")
$b1 = [System.Drawing.Image]::FromFile("D:\ipyProject\ai-contract\docs\screenshots\diff-without-app.png")
if ($a1.Width -eq $b1.Width -and $a1.Height -eq $b1.Height) {
    $diffCount = 0; $minX = 99999; $maxX = -1
    for ($x = 0; $x -lt $a1.Width; $x++) {
        for ($y = 0; $y -lt $a1.Height; $y++) {
            $pa = $a1.GetPixel($x, $y); $pb = $b1.GetPixel($x, $y)
            $d = [Math]::Abs($pa.R - $pb.R) + [Math]::Abs($pa.G - $pb.G) + [Math]::Abs($pa.B - $pb.B)
            if ($d -gt 24) { $diffCount++; if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x } }
        }
    }
    Write-Output ("16:41 两张差分对比: 差异像素={0} X范围={1}..{2}" -f $diffCount, $minX, $maxX)
} else {
    Write-Output ("16:41 两张尺寸不同: {0}x{1} vs {2}x{3}（无法逐像素对比）" -f $a1.Width, $a1.Height, $b1.Width, $b1.Height)
}
$a1.Dispose(); $b1.Dispose()