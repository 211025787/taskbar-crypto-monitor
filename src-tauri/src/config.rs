//! 胶囊显示配置的持久化模块
//!
//! 配置以 JSON 形式存放于应用数据目录（%APPDATA%/<identifier>/config.json），
//! 字段采用 camelCase 序列化，与前端 TypeScript 接口直接对应。

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

/// 胶囊显示配置
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct CapsuleConfig {
    /// 主显示合约名称（Binance USDⓈ-M 永续，如 BTCUSDT），默认 BTCUSDT
    pub symbol: String,
    /// 是否显示合约名称徽标（如 BTCUSDT）
    pub show_symbol: bool,
    /// 是否显示最新成交价（USDT 计价）
    pub show_price: bool,
    /// 是否显示 24 小时涨跌幅
    pub show_change: bool,
    /// 是否显示迷你趋势曲线（Sparkline）
    pub show_sparkline: bool,
    /// 整体缩放系数，有效范围 0.8 ~ 1.4，默认 1.0
    pub scale: f64,
}

impl Default for CapsuleConfig {
    /// 默认配置：BTCUSDT 主合约 + 四个字段全部显示，标准缩放
    fn default() -> Self {
        Self {
            symbol: "BTCUSDT".to_string(),
            show_symbol: true,
            show_price: true,
            show_change: true,
            show_sparkline: true,
            scale: 1.0,
        }
    }
}

/// 配置文件完整路径（应用数据目录下的 config.json）
fn config_path(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_data_dir().ok().map(|dir| dir.join("config.json"))
}

/// 从磁盘加载配置；文件不存在或解析失败时返回 None（由调用方回退默认值）
pub fn load_config(app: &AppHandle) -> Option<CapsuleConfig> {
    let path = config_path(app)?;
    let text = fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

/// 将配置写入磁盘（自动创建应用数据目录）
pub fn save_config_to_disk(app: &AppHandle, cfg: &CapsuleConfig) -> Result<(), String> {
    let path = config_path(app).ok_or("无法定位应用数据目录")?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("创建配置目录失败: {e}"))?;
    }
    let text = serde_json::to_string_pretty(cfg).map_err(|e| format!("序列化配置失败: {e}"))?;
    fs::write(path, text).map_err(|e| format!("写入配置文件失败: {e}"))?;
    Ok(())
}