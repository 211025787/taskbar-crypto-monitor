# 最干净对照：WinForms 自建窗口（红色 GDI 渲染），不同尺寸测屏幕可见性
Add-Type -AssemblyName System.Windows.Forms,System.Drawing

# 创建红色 WinForms 窗口（TopLevel、无装饰缩小模仿胶囊，但有装饰版也测）
$form = New-Object System.Windows.Forms.Form
$form.BackColor = [System.Drawing.Color]::Red
$form.StartPosition = "Manual"

function Test-Form([System.Windows.Forms.Form]$f, [int]$cw, [int]$ch, [string]$label) {
    $f.Size = New-Object System.Drawing.Size($cw, $ch)
    $f.Location = New-Object System.Drawing.Point(400, 200)
    $f.Refresh()
    Start-Sleep -Milliseconds 1200
    $r = $f.Bounds
    Write-Output ("WinForms {0,-12} 实际rect=({1},{2}) {3}x{4}" -f $label, $r.X, $r.Y, $r.Width, $r.Height)
    $sc = New-Object System.Drawing.Bitmap($r.Width, $r.Height)
    $g = [System.Drawing.Graphics]::FromImage($sc)
    $g.CopyFromScreen($r.X, $r.Y, 0, 0, (New-Object System.Drawing.Size($r.Width, $r.Height)))
    $g.Dispose()
    $red = 0
    for ($x = 0; $x -lt $r.Width; $x += 2) {
        for ($y = 0; $y -lt $r.Height; $y += 2) {
            $p = $sc.GetPixel($x, $y)
            if ($p.R -gt 200 -and $p.G -lt 80 -and $p.B -lt 80) { $red++ }
        }
    }
    $sc.Dispose()
    $verdict = if ($red -gt 100) { "可见" } else { "不可见" }
    Write-Output ("  屏幕红色采样={0} {1}" -f $red, $verdict)
}

$form.Add_Shown({
    Test-Form $form 384 527 "384x527"
    Test-Form $form 384 100 "384x100"
    Test-Form $form 300 44 "300x44"
    Test-Form $form 175 44 "175x44"
    $form.Close()
})
[void]$form.Show()
$form.Dispose()
Write-Output "WinForms 实验完成"