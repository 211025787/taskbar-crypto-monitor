# 同步启动应用后立即退出（避免 bash 后台转置连累子进程）
Start-Process "$env:LOCALAPPDATA\Taskbar Crypto Monitor\taskbar-crypto-monitor.exe"
"launched"