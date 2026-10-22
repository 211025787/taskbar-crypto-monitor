# MPO 对照测试还原：提权删除 OverlayTestMode 并重启 Explorer
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts/mpo-test-off.ps1
# 会弹 UAC 提权窗口（请点"是"）
Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
    "-NoProfile",
    "-Command",
    "Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode' -ErrorAction SilentlyContinue; Stop-Process -Name explorer -Force"
)
Start-Sleep -Seconds 6
$value = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\Dwm" -Name "OverlayTestMode" -ErrorAction SilentlyContinue
if ($null -eq $value) {
    Write-Output "MPO-OFF: OverlayTestMode 已删除（MPO 恢复默认启用）"
} else {
    Write-Output "MPO-RESTORE-FAIL: 注册表项仍存在"
}