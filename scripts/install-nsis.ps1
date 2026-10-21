# 弹出 NSIS 安装向导（UI 模式，用户手动点下一步；本机静默 /S 会卡死）
$setup = "D:\ipyProject\ai-contract\src-tauri\target\release\bundle\nsis\Taskbar Crypto Monitor_0.1.0_x64-setup.exe"
Start-Process -FilePath $setup
Write-Output "setup wizard launched"