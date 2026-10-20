# 启动应用并以文件落盘方式捕获退出码与输出（供 bash 会话读取）
$exe = "$env:LOCALAPPDATA\Taskbar Crypto Monitor\taskbar-crypto-monitor.exe"
$out = "$env:TEMP\tcm-out.log"
$err = "$env:TEMP\tcm-err.log"
$p = Start-Process -FilePath $exe -PassThru -Wait -RedirectStandardOutput $out -RedirectStandardError $err
"EXIT=$($p.ExitCode)" | Out-File "$env:TEMP\tcm-exit.txt" -Encoding utf8