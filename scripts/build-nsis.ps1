# NSIS 打包：杀掉占用进程后在 PowerShell 原生环境执行 tauri build
Get-Process taskbar-crypto-monitor -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process | Where-Object { $_.Name -like "setup*" } | Stop-Process -Force
Start-Sleep -Milliseconds 800
Remove-Item Env:MSYSTEM -ErrorAction SilentlyContinue
Remove-Item Env:SHELL -ErrorAction SilentlyContinue
$env:RUSTUP_HOME = "D:\develop\rust\rustup"
$env:CARGO_HOME = "D:\develop\rust\cargo"
$env:HTTPS_PROXY = "http://127.0.0.1:7890"
$env:HTTP_PROXY = "http://127.0.0.1:7890"
$env:PATH = "D:\develop\msys2\mingw64\bin;D:\develop\rust\cargo\bin;D:\develop\nodejsnvm;C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0\"
Set-Location D:\ipyProject\ai-contract
npm run tauri build
Write-Output ("BUILD EXIT CODE: " + $LASTEXITCODE)