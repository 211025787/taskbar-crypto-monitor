// 发布模式下隐藏控制台窗口（切换为 Windows GUI 子系统）
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    taskbar_crypto_monitor_lib::run()
}