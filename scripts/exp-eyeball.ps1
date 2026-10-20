# 肉眼验证窗口：屏幕上同时显示大红窗(384x527)与小红窗(175x44)，保持 120 秒
Add-Type -AssemblyName System.Windows.Forms,System.Drawing

$big = New-Object System.Windows.Forms.Form
$big.BackColor = [System.Drawing.Color]::Red
$big.StartPosition = "Manual"
$big.FormBorderStyle = "None"
$big.TopMost = $true
$big.Size = New-Object System.Drawing.Size(384, 527)
$big.Location = New-Object System.Drawing.Point(150, 150)
$big.Text = "BIG"
$big.Show()

$small = New-Object System.Windows.Forms.Form
$small.BackColor = [System.Drawing.Color]::Red
$small.StartPosition = "Manual"
$small.FormBorderStyle = "None"
$small.TopMost = $true
$small.Size = New-Object System.Drawing.Size(175, 44)
$small.Location = New-Object System.Drawing.Point(600, 300)
$small.Text = "SMALL"
$small.Show()

$labelText = "大红窗(384x527)与小红窗(175x44)已显示。`n如果两个都看得见请选'都有'；`n只有大的请选'只有大红窗'；`n都没有请选'都看不到'。"
Write-Output "两窗口已显示，保持 120 秒..."

$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 200
}
Write-Output "时间到，关闭窗口"
$small.Close(); $small.Dispose()
$big.Close(); $big.Dispose()