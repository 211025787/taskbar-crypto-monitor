# MPO 禁用对照测试第一步：提权写入 OverlayTestMode=5 并重启 Explorer
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts/mpo-test-on.ps1
# 会弹 UAC 提权窗口（请点"是"）：写 HKLM\SOFTWARE\Microsoft\Windows\Dwm\OverlayTestMode=5 后重启 Explorer
Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
    "-NoProfile",
    "-Command",
    "New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode' -Value 5 -PropertyType DWord -Force | Out-Null; Stop-Process -Name explorer -Force"
)
Start-Sleep -Seconds 6
$value = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\Dwm" -Name "OverlayTestMode" -ErrorAction SilentlyContinue
if ($value.OverlayTestMode -eq 5) {
    Write-Output "MPO-ON: OverlayTestMode=5 生效（MPO 独立平面已禁用，走 DWM 合成）"
} else {
    Write-Output "MPO-FAIL: 注册表写入未生效"
}