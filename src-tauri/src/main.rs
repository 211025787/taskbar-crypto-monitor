// 发布模式下隐藏控制台窗口（切换为 Windows GUI 子系统）
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

/// 需要默认注入的 WebView2 浏览器参数
///
/// - 禁用原生窗口遮挡计算：任务栏 z 序扰动瞬间 Chromium 误判遮挡而暂停合成，造成整窗空白闪
/// - 禁用 GPU 合成：Chromium GPU surface 在任务栏区域重绘时被波及重建（提交间隙空白一帧），
///   胶囊为轻量文本软合成零压力；实测中央位置（不与任务栏重叠）不闪，锁定区域重绘波及路径
const REQUIRED_BROWSER_ARGS: &str = "--disable-features=CalculateNativeWinOcclusion --disable-gpu-compositing";

/// 在 WebView2 环境创建前合并浏览器参数（Loader 读取本进程环境变量）
///
/// 外部已设值（如调试脚本注入 --remote-debugging-port）时追加本参数，避免覆盖；
/// 追加形式产生重复 --disable-features 时 Chromium 会自动合并，无副作用。
fn merge_webview2_browser_args() {
    let existing = std::env::var("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS").unwrap_or_default();
    if existing.contains("CalculateNativeWinOcclusion") {
        return;
    }
    let merged = if existing.trim().is_empty() {
        REQUIRED_BROWSER_ARGS.to_string()
    } else {
        format!("{existing} {REQUIRED_BROWSER_ARGS}")
    };
    // main 最早期调用：WebView2 环境尚未创建，无其它线程读取该变量（edition 2021 set_var 非 unsafe）
    std::env::set_var("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", merged);
}

fn main() {
    // 必须在 Tauri 初始化（WebView2 环境创建）之前完成参数合并
    merge_webview2_browser_args();
    taskbar_crypto_monitor_lib::run()
}