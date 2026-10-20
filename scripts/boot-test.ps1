# 连续三次受控启动测试：每次启动后等待 5 秒检查存活再杀掉
$results = @()
for ($i = 1; $i -le 3; $i++) {
    Start-Process "$env:LOCALAPPDATA\Taskbar Crypto Monitor\taskbar-crypto-monitor.exe"
    Start-Sleep -Seconds 5
    $alive = (Get-Process -Name taskbar-crypto-monitor -ErrorAction SilentlyContinue) -ne $null
    $results += "第 $i 次: 存活=$alive"
    Stop-Process -Name taskbar-crypto-monitor -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}
$results | Out-File "D:\ipyProject\ai-contract\.boot-test.txt" -Encoding utf8