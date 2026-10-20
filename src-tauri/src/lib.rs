//! Taskbar Crypto Monitor 主应用：胶囊行情窗口覆盖于 Windows 11 任务栏
//!
//! 当前阶段：全透明胶囊 + Binance 实时行情 WebSocket + 原生右键菜单（设置/退出）
//! + 合约搜索选择 + 显示字段/缩放配置。

mod config;
mod market;
mod taskbar;

use config::CapsuleConfig;
use serde::Serialize;
use std::sync::OnceLock;
use std::time::Duration;
use tauri::menu::{ContextMenu, Menu, MenuItem};
use tauri::{AppHandle, Emitter, LogicalSize, Manager};

/// 合约精简信息（供前端搜索选择）
#[derive(Debug, Clone, Serialize)]
pub struct SymbolInfo {
    /// 合约全名（如 BTCUSDT）
    pub symbol: String,
    /// 基础资产简称（如 BTC），用于辅助搜索
    pub base: String,
}

/// 合约列表查询结果
#[derive(Debug, Clone, Serialize)]
pub struct SymbolList {
    /// 可选的 USDT 本位永续合约集合
    pub symbols: Vec<SymbolInfo>,
    /// 数据来源："online"（Binance 实时）或 "builtin"（内置回退）
    pub source: String,
}

/// 在线合约列表的进程级缓存：首次成功拉取后驻留内存
static ONLINE_SYMBOLS: OnceLock<Vec<SymbolInfo>> = OnceLock::new();

/// 胶囊右键菜单的进程级单例
///
/// 菜单必须常驻：若在命令返回时 Drop，菜单事件通道随 Drop 被移除，
/// 与事件派发形成竞态，导致点击菜单项后 on_menu_event 丢失。
static CAPSULE_MENU: OnceLock<Menu<tauri::Wry>> = OnceLock::new();

/// 获取（或首次构建）胶囊右键菜单的共享实例
fn capsule_menu(app: &AppHandle) -> Menu<tauri::Wry> {
    CAPSULE_MENU
        .get_or_init(|| {
            let menu = Menu::new(app).expect("构建菜单失败");
            let settings_item =
                MenuItem::with_id(app, "capsule-settings", "设置…", true, None::<&str>)
                    .expect("构建菜单项失败");
            let quit_item =
                MenuItem::with_id(app, "capsule-quit", "退出", true, None::<&str>).expect("构建菜单项失败");
            let _ = menu.append(&settings_item);
            let _ = menu.append(&quit_item);
            menu
        })
        .clone()
}

/// 内置热门 USDT 永续合约（网络不可用时的回退列表）
fn builtin_symbols() -> Vec<SymbolInfo> {
    [
        "BTC", "ETH", "BNB", "SOL", "XRP", "DOGE", "ADA", "AVAX", "LINK", "TRX", "DOT", "LTC", "BCH", "UNI", "ATOM",
        "XLM", "NEAR", "APT", "ARB", "OP", "FIL", "ICP", "ETC", "HBAR", "VET", "TON", "SUI", "SEI", "PEPE", "SHIB",
        "1000PEPE", "WIF", "BONK", "ENA", "WLD", "TIA",
    ]
    .iter()
    .map(|base| SymbolInfo { symbol: format!("{base}USDT"), base: base.to_string() })
    .collect()
}

/// 从 Binance USDⓈ-M Futures exchangeInfo 拉取可交易的 USDT 本位永续合约
fn fetch_online_symbols() -> Result<Vec<SymbolInfo>, String> {
    // 5 秒超时：大陆网络无法直连 Binance 时快速回退，避免设置窗口长时间等待
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(5))
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) TaskbarCryptoMonitor/0.1")
        .build();
    let resp: serde_json::Value = agent
        .get("https://fapi.binance.com/fapi/v1/exchangeInfo")
        .call()
        .map_err(|e| format!("请求 Binance 失败: {e}"))?
        .into_json()
        .map_err(|e| format!("解析响应失败: {e}"))?;
    let mut list = Vec::new();
    if let Some(symbols) = resp["symbols"].as_array() {
        for item in symbols {
            // 仅保留：交易中 + 永续合约 + USDT 本位
            let trading = item["status"].as_str() == Some("TRADING");
            let perpetual = item["contractType"].as_str() == Some("PERPETUAL");
            let usdt_quote = item["quoteAsset"].as_str() == Some("USDT");
            if trading && perpetual && usdt_quote {
                if let (Some(symbol), Some(base)) = (item["symbol"].as_str(), item["baseAsset"].as_str()) {
                    list.push(SymbolInfo { symbol: symbol.to_string(), base: base.to_string() });
                }
            }
        }
    }
    if list.is_empty() {
        return Err("合约列表为空".to_string());
    }
    list.sort_by(|a, b| a.symbol.cmp(&b.symbol));
    Ok(list)
}

/// 查询可选合约列表：优先在线拉取（成功后缓存），失败回退内置列表
#[tauri::command]
fn fetch_symbols() -> SymbolList {
    if let Some(cached) = ONLINE_SYMBOLS.get() {
        return SymbolList { symbols: cached.clone(), source: "online".to_string() };
    }
    match fetch_online_symbols() {
        Ok(list) => {
            let _ = ONLINE_SYMBOLS.set(list.clone());
            SymbolList { symbols: list, source: "online".to_string() }
        }
        Err(_) => SymbolList { symbols: builtin_symbols(), source: "builtin".to_string() },
    }
}

/// 依据配置计算胶囊窗口的逻辑尺寸（宽度随可见字段、合约名长度与缩放变化）
fn compute_capsule_size(cfg: &CapsuleConfig) -> LogicalSize<f64> {
    let mut content = 0.0f64;
    let mut fields = 0u32;
    if cfg.show_symbol {
        // 合约名宽度按字符数估算：每字符约 8.5 逻辑像素 + 8 基础边距，上限 120
        let chars = cfg.symbol.chars().count().max(4) as f64;
        content += (8.0 + chars * 8.5).min(120.0);
        fields += 1;
    }
    if cfg.show_price {
        content += 96.0;
        fields += 1;
    }
    if cfg.show_change {
        content += 58.0;
        fields += 1;
    }
    if cfg.show_sparkline {
        content += 82.0;
        fields += 1;
    }
    // 字段间距：相邻可见字段各留 10 逻辑像素
    if fields > 1 {
        content += 10.0 * f64::from(fields - 1);
    }
    // 左右内边距 12*2 固定不缩放；内容宽度整体乘缩放系数
    let width = 24.0 + content * cfg.scale;
    LogicalSize::new(width, 44.0)
}

/// 按配置调整胶囊窗口尺寸并重新覆盖定位到任务栏
fn apply_capsule_layout(app: &AppHandle, cfg: &CapsuleConfig) {
    if let Some(window) = app.get_webview_window("capsule") {
        let _ = window.set_size(compute_capsule_size(cfg));
        // 定位需要物理像素尺寸，从窗口实际 outer_size 读取
        if let Ok(hwnd_raw) = window.hwnd() {
            let hwnd = hwnd_raw.0 as windows_sys::Win32::Foundation::HWND;
            if let Ok(size) = window.outer_size() {
                let placed = taskbar::place_capsule_over_taskbar(hwnd, size.width as i32, size.height as i32);
                println!("[taskbar-crypto-monitor] 任务栏覆盖定位: {}", if placed { "成功" } else { "失败" });
            }
        }
    }
}

/// 读取当前配置（磁盘无存档时返回默认值）
#[tauri::command]
fn get_config(app: AppHandle) -> CapsuleConfig {
    config::load_config(&app).unwrap_or_default()
}

/// 保存配置：写入磁盘 + 调整胶囊窗口布局 + 切换行情订阅 + 广播事件给所有窗口
#[tauri::command]
fn save_config(app: AppHandle, config: CapsuleConfig) -> Result<(), String> {
    config::save_config_to_disk(&app, &config)?;
    apply_capsule_layout(&app, &config);
    // 合约变化时切换 WebSocket 行情订阅（market 内部去重，未变化不重连）
    market::switch_symbol(&app, &config.symbol);
    app.emit("config-changed", &config).map_err(|e| e.to_string())
}

/// 打开（或前置已打开的）设置窗口
#[tauri::command]
fn open_settings(app: AppHandle) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// 在胶囊窗口上弹出原生右键菜单（设置 / 退出）
#[tauri::command]
fn show_capsule_menu(app: AppHandle, window: tauri::WebviewWindow) {
    // 取常驻单例菜单（避免 Drop 竞态丢失菜单事件）
    let menu = capsule_menu(&app);
    // 诊断结论：直接改写 GWL_EXSTYLE 会与 wry 透明窗口的合成状态产生竞态，
    // 导致胶囊屏幕合成永久损坏（PrintWindow 有内容但屏幕不可见），暂不启用
    let _ = menu.popup(window.as_ref().window());
    println!("[taskbar-crypto-monitor] popup 调用已返回");
}

/// 应用入口：注册命令与事件处理，setup 阶段完成胶囊窗口初始化
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            get_config,
            save_config,
            open_settings,
            show_capsule_menu,
            fetch_symbols
        ])
        .on_menu_event(|app, event| match event.id().as_ref() {
            // 右键菜单：打开设置窗口
            "capsule-settings" => {
                println!("[taskbar-crypto-monitor] 菜单事件: capsule-settings");
                if let Some(window) = app.get_webview_window("settings") {
                    let _ = window.show();
                    let _ = window.set_focus();
                    println!("[taskbar-crypto-monitor] 设置窗口已请求显示");
                }
            }
            // 右键菜单：退出整个程序
            "capsule-quit" => app.exit(0),
            other => println!("[taskbar-crypto-monitor] 未知菜单事件: {other}"),
        })
        .on_window_event(|window, event| {
            // 设置窗口点击关闭时仅隐藏而非销毁：保留实例供右键菜单反复打开
            // （在 Rust 端拦截，不依赖前端权限，修复此前点击关闭无效的问题）
            if window.label() == "settings" {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .setup(|app| {
            let handle = app.handle().clone();

            // 取出配置中声明的胶囊窗口
            let window = app
                .get_webview_window("capsule")
                .expect("胶囊窗口 capsule 未在 tauri.conf.json 中定义");
            let hwnd_raw = window.hwnd().expect("获取胶囊窗口句柄失败");
            let hwnd = hwnd_raw.0 as windows_sys::Win32::Foundation::HWND;

            // 追加不抢焦点样式（须在放置前完成，避免样式变更触发激活）
            taskbar::apply_no_activate_style(hwnd);

            // 首次启动：按已存配置初始化尺寸并覆盖定位到任务栏
            let cfg = config::load_config(&handle).unwrap_or_default();
            apply_capsule_layout(&handle, &cfg);

            // 启动配置合约的实时行情 WebSocket 订阅
            market::switch_symbol(&handle, &cfg.symbol);

            // 启动 Z 序看门狗：对抗 Win11 任务栏的周期性置顶重断言
            taskbar::spawn_zorder_watchdog(hwnd);


            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Tauri 应用启动失败");
}