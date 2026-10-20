# WinForms 对照（线性版）：红色窗口各尺寸测屏幕可见性
Add-Type -AssemblyName System.Windows.Forms,System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.BackColor = [System.Drawing.Color]::Red
$form.StartPosition = "Manual"
$form.FormBorderStyle = "None"
$form.TopMost = $true
$form.Size = New-Object System.Drawing.Size(384, 527)
$form.Location = New-Object System.Drawing.Point(400, 200)
$form.Show()
$form.Activate()
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 1000

function Test-Form($f, [int]$cw, [int]$ch, [string]$label) {
    $f.Size = New-Object System.Drawing.Size($cw, $ch)
    $f.Location = New-Object System.Drawing.Point(400, 200)
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 1200
    [System.Windows.Forms.Application]::DoEvents()
    $r = $f.Bounds
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
    Write-Output ("WinForms {0,-12} 实际{1}x{2} 屏幕红采样={3,-6} {4}" -f $label, $r.Width, $r.Height, $red, $verdict)
}

Test-Form $form 384 527 "384x527"
Test-Form $form 384 100 "384x100"
Test-Form $form 300 44 "300x44"
Test-Form $form 175 44 "175x44"
Test-Form $form 175 100 "175x100"

$form.Close()
$form.Dispose()
Write-Output "WinForms 实验完成"