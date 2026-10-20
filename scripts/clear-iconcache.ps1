# 完整清理 Windows 图标缓存数据库：杀应用+Explorer → 删 IconCache.db/iconcache_*.db → 重启 Explorer → 重启应用
# 之前仅重启 Explorer 未删库，坏条目被复用导致任务栏按钮持续黑色
$out = @()
# 1. 停止应用与 Explorer（Explorer 持有 iconcache 句柄，必须先退出才能删除）
Stop-Process -Name "taskbar-crypto-monitor" -Force -ErrorAction SilentlyContinue
$out += "应用已停止"
Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$out += "Explorer 已停止"
# 2. 解除隐藏/系统属性并删除图标缓存数据库
$targets = @("$env:LOCALAPPDATA\IconCache.db") + (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db" -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
foreach ($t in $targets) {
    if (Test-Path $t) {
        attrib +r -h -s $t 2>$null
        attrib -r -h -s $t 2>$null
        Remove-Item $t -Force -ErrorAction SilentlyContinue
        $out += "删除: $t => $(if (Test-Path $t) { '失败' } else { '成功' })"
    }
}
# 3. 重启 Explorer 与应用
Start-Process explorer.exe
Start-Sleep -Seconds 4
$out += "Explorer 已重启"
Start-Process "D:\ipyProject\ai-contract\src-tauri\target\release\taskbar-crypto-monitor.exe"
Start-Sleep -Seconds 5
$out += "应用已重启"
$out | Out-File "D:\ipyProject\ai-contract\.clearcache.txt" -Encoding utf8