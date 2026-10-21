# 带WebView2远程调试端口重启 release exe（同步脚本，避免bash后台转置截断命令）
param(
    [int]$Port = 9333
)
Get-Process taskbar-crypto-monitor -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port"
Start-Process "D:\ipyProject\ai-contract\src-tauri\target\release\taskbar-crypto-monitor.exe"
Start-Sleep -Seconds 8
$proc = Get-Process taskbar-crypto-monitor -ErrorAction SilentlyContinue
Write-Output ("restarted pid={0} debugPort={1}" -f $proc.Id, $Port)