//! Binance USDⓈ-M K 线数据模块（REST 历史拉取 + WebSocket 实时增量 + 24h 概览）
//!
//! 与 market.rs 同构的 generation 防残留模式：每次切换 (symbol, interval)
//! 递增代号，旧流任务检测到失配后自行退出。Rust 侧维护 500 根环形缓冲
//! 用于当前流去重合并，前端通过 kline-update 事件接收增量。
//! 24h 概览走 REST ticker/24hr，由前端轮询调用（不占用行情推送通道）。

use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tauri::{AppHandle, Emitter};
use tokio_tungstenite::{connect_async, tungstenite::Message};

/// 单根 K 线（广播给前端，字段采用 camelCase 序列化）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Kline {
    /// 归属合约名（大写，如 BTCUSDT）：前端用于丢弃切换后旧流残留推送
    pub symbol: String,
    /// 开盘时间（毫秒时间戳，作为 K 线唯一标识）
    pub opentime: i64,
    /// 收盘时间（毫秒时间戳）
    pub closetime: i64,
    /// 开盘价（USDT 计价）
    pub open: f64,
    /// 最高价（USDT 计价）
    pub high: f64,
    /// 最低价（USDT 计价）
    pub low: f64,
    /// 收盘价（USDT 计价，未收盘 K 线为最新价）
    pub close: f64,
    /// 成交量（以币计）
    pub volume: f64,
    /// K 线是否已收盘（false 表示当前正在进行中的 K 线）
    pub closed: bool,
}

/// K 线流连接状态（广播给前端展示图表数据源状态）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KlineStatus {
    /// 状态：connecting / connected / reconnecting / stopped
    pub state: String,
    /// 状态补充说明（如重连等待秒数）
    pub detail: String,
}

/// 24h 行情概览（REST 拉取，供首页头部展示）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OverviewData {
    /// 合约名（如 BTCUSDT）
    pub symbol: String,
    /// 最新成交价（USDT 计价）
    pub last_price: f64,
    /// 24 小时涨跌幅（%，正值代表上涨）
    pub change_percent: f64,
    /// 24 小时涨跌额（USDT）
    pub change_amount: f64,
    /// 24 小时最高价（USDT）
    pub high: f64,
    /// 24 小时最低价（USDT）
    pub low: f64,
    /// 24 小时成交量（以币计）
    pub volume: f64,
    /// 24 小时成交额（USDT 计价）
    pub quote_volume: f64,
}

/// 订阅代号：每次切换 (symbol, interval) 递增，旧任务检测到失配后自行退出
static KLINE_SUBSCRIPTION: AtomicU64 = AtomicU64::new(0);

/// 当前流缓冲（仅服务当前查看的 symbol+interval，切走即弃）
static KLINE_BUFFER: OnceLock<Mutex<VecDeque<Kline>>> = OnceLock::new();

/// 环形缓冲容量上限（根）
const KLINE_BUFFER_MAX: usize = 500;

/// REST 客户端（进程级复用连接池）
static KLINE_REST_AGENT: OnceLock<ureq::Agent> = OnceLock::new();

/// 允许的 K 线周期档位（Binance interval 参数白名单）
const VALID_INTERVALS: [&str; 6] = ["1m", "5m", "15m", "1h", "4h", "1d"];

/// 取（或初始化）当前流缓冲队列
fn buffer() -> &'static Mutex<VecDeque<Kline>> {
    KLINE_BUFFER.get_or_init(|| Mutex::new(VecDeque::with_capacity(KLINE_BUFFER_MAX + 1)))
}

/// 取（或初始化）REST 客户端
fn rest_agent() -> &'static ureq::Agent {
    KLINE_REST_AGENT.get_or_init(|| {
        ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(8))
            .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) TaskbarCryptoMonitor/0.1")
            .build()
    })
}

/// 校验周期参数是否在白名单内（防任意参数注入 URL）
fn valid_interval(interval: &str) -> bool {
    VALID_INTERVALS.contains(&interval)
}

/// 合并增量 K 线进缓冲：opentime 相同则覆盖（未收盘 K 线的滚动更新），否则追加并裁剪
fn merge_into_buffer(k: Kline) {
    let mut buf = buffer().lock().expect("K 线缓冲锁中毒");
    // 队尾即最新 K 线：opentime 匹配直接覆盖，大于则追加
    if buf.back().is_some_and(|last| last.opentime == k.opentime) {
        *buf.back_mut().expect("back 已校验非空") = k;
    } else {
        buf.push_back(k);
    }
    // 超容量时丢弃最旧数据，保持缓冲有界
    while buf.len() > KLINE_BUFFER_MAX {
        buf.pop_front();
    }
}

/// REST 拉取历史 K 线（fapi/v1/klines），返回按时间升序的 K 线序列
fn fetch_rest_klines(symbol: &str, interval: &str, limit: u32) -> Result<Vec<Kline>, String> {
    let url = format!("https://fapi.binance.com/fapi/v1/klines?symbol={symbol}&interval={interval}&limit={limit}");
    let resp: Vec<Value> = rest_agent()
        .get(&url)
        .call()
        .map_err(|e| format!("请求 Binance 失败: {e}"))?
        .into_json()
        .map_err(|e| format!("解析响应失败: {e}"))?;
    let mut list = Vec::with_capacity(resp.len());
    for item in &resp {
        // klines 数组元素：[openTime, open, high, low, close, volume, closeTime, ...]
        let Some(k) = parse_rest_kline(symbol, item) else {
            continue;
        };
        list.push(k);
    }
    if list.is_empty() {
        return Err("K 线数据为空".to_string());
    }
    Ok(list)
}

/// 解析 REST klines 数组的单个元素
fn parse_rest_kline(symbol: &str, item: &Value) -> Option<Kline> {
    Some(Kline {
        symbol: symbol.to_string(),
        opentime: item[0].as_i64()?,
        closetime: item[6].as_i64()?,
        open: item[1].as_str()?.parse().ok()?,
        high: item[2].as_str()?.parse().ok()?,
        low: item[3].as_str()?.parse().ok()?,
        close: item[4].as_str()?.parse().ok()?,
        volume: item[5].as_str()?.parse().ok()?,
        // REST 历史中最后一根可能未收盘，其余均已收盘
        closed: true,
    })
}

/// 拉取历史 K 线的 Tauri 命令（首屏数据；limit 钳制 1 ~ 1000）
#[tauri::command]
pub fn fetch_klines(symbol: String, interval: String, limit: u32) -> Result<Vec<Kline>, String> {
    if !valid_interval(&interval) {
        return Err(format!("不支持的周期: {interval}"));
    }
    let limit = limit.clamp(1, 1000);
    fetch_rest_klines(&symbol, &interval, limit)
}

/// 切换 K 线实时流订阅（symbol 或 interval 变化时重连；相同则跳过）
#[tauri::command]
pub fn switch_kline_stream(app: AppHandle, symbol: String, interval: String) {
    if !valid_interval(&interval) {
        return;
    }
    // 递增代号使旧任务退出，并清空旧缓冲（切换即弃）
    {
        let mut buf = buffer().lock().expect("K 线缓冲锁中毒");
        buf.clear();
    }
    let generation = KLINE_SUBSCRIPTION.fetch_add(1, Ordering::SeqCst) + 1;
    let app = app.clone();
    let stream_symbol = symbol.to_lowercase();
    tauri::async_runtime::spawn(async move {
        run_kline_stream(app, stream_symbol, interval, generation).await;
    });
}

/// 停止 K 线实时流（首页窗口隐藏/关闭时调用，释放连接）
#[tauri::command]
pub fn stop_kline_stream(app: AppHandle) {
    // 代号递增使在跑任务退出，并广播停止状态
    KLINE_SUBSCRIPTION.fetch_add(1, Ordering::SeqCst);
    let _ = app.emit("kline-status", KlineStatus { state: "stopped".to_string(), detail: String::new() });
}

/// K 线流主循环：断线指数退避重连（K 线数据已有 REST 首屏，无需轮询回退）
async fn run_kline_stream(app: AppHandle, symbol: String, interval: String, generation: u64) {
    let ws_url = format!("wss://fstream.binance.com/ws/{symbol}@kline_{interval}");
    println!("[klines] 开始订阅 K 线: {symbol} {interval}");
    let mut backoff_secs = 1u64;
    loop {
        if KLINE_SUBSCRIPTION.load(Ordering::SeqCst) != generation {
            println!("[klines] 订阅已过期，任务退出: {symbol} {interval}");
            return;
        }
        let _ = app.emit("kline-status", KlineStatus { state: "connecting".to_string(), detail: String::new() });
        match connect_async(ws_url.as_str()).await {
            Ok((ws, _)) => {
                println!("[klines] WebSocket 已连接: {symbol} {interval}");
                let (mut write, mut read) = ws.split();
                loop {
                    // 收流中途被切换：关闭连接并退出
                    if KLINE_SUBSCRIPTION.load(Ordering::SeqCst) != generation {
                        let _ = write.close().await;
                        println!("[klines] 订阅已过期，关闭连接退出: {symbol} {interval}");
                        return;
                    }
                    let item = match read.next().await {
                        Some(inner) => inner,
                        None => break,
                    };
                    match item {
                        // K 线增量推送：解析后合并进缓冲并广播
                        Ok(Message::Text(text)) => {
                            if let Some(k) = parse_kline_message(&text) {
                                merge_into_buffer(k.clone());
                                let _ = app.emit("kline-update", &k);
                            }
                        }
                        // 服务器心跳：按协议回 pong 保活
                        Ok(Message::Ping(payload)) => {
                            let _ = write.send(Message::Pong(payload)).await;
                        }
                        // 其余消息（Pong/Close/Frame）忽略
                        Ok(_) => {}
                        // 流错误：跳出内层循环进入外层退避重连
                        Err(e) => {
                            println!("[klines] 流错误: {e}");
                            break;
                        }
                    }
                }
                let _ = app.emit(
                    "kline-status",
                    KlineStatus { state: "reconnecting".to_string(), detail: format!("{backoff_secs}s 后重连") },
                );
            }
            Err(e) => {
                println!("[klines] WebSocket 连接失败({backoff_secs}s 后重试): {e}");
                let _ = app.emit(
                    "kline-status",
                    KlineStatus { state: "reconnecting".to_string(), detail: format!("{backoff_secs}s 后重连") },
                );
            }
        }
        if KLINE_SUBSCRIPTION.load(Ordering::SeqCst) != generation {
            return;
        }
        tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
        backoff_secs = (backoff_secs * 2).min(60);
    }
}

/// 解析 Binance kline 推送消息；非 K 线推送返回 None
fn parse_kline_message(text: &str) -> Option<Kline> {
    let value: Value = serde_json::from_str(text).ok()?;
    if value["e"].as_str()? != "kline" {
        return None;
    }
    let k = &value["k"];
    Some(Kline {
        symbol: value["s"].as_str()?.to_string(),
        opentime: k["t"].as_i64()?,
        closetime: k["T"].as_i64()?,
        open: k["o"].as_str()?.parse().ok()?,
        high: k["h"].as_str()?.parse().ok()?,
        low: k["l"].as_str()?.parse().ok()?,
        close: k["c"].as_str()?.parse().ok()?,
        volume: k["v"].as_str()?.parse().ok()?,
        closed: k["x"].as_bool().unwrap_or(false),
    })
}

/// 拉取 24h 行情概览的 Tauri 命令（首页头部轮询调用）
#[tauri::command]
pub fn fetch_overview(symbol: String) -> Result<OverviewData, String> {
    let url = format!("https://fapi.binance.com/fapi/v1/ticker/24hr?symbol={symbol}");
    let resp: Value = rest_agent()
        .get(&url)
        .call()
        .map_err(|e| format!("请求 Binance 失败: {e}"))?
        .into_json()
        .map_err(|e| format!("解析响应失败: {e}"))?;
    Ok(OverviewData {
        symbol: resp["symbol"].as_str().unwrap_or_default().to_string(),
        last_price: resp["lastPrice"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
        change_percent: resp["priceChangePercent"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
        change_amount: resp["priceChange"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
        high: resp["highPrice"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
        low: resp["lowPrice"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
        volume: resp["volume"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
        quote_volume: resp["quoteVolume"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
    })
}
/// 合约行情简报（列表涨跌%批量查询用）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TickerBrief {
    /// 合约名（如 BTCUSDT）
    pub symbol: String,
    /// 24 小时涨跌幅（%，正值代表上涨）
    pub change_percent: f64,
}

/// 批量拉取合约 24h 涨跌幅（首页合约列表 10s 轮询调用）
///
/// Binance 接口：GET /fapi/v1/ticker/24hr?symbols=["A","B",...]（单次上限 100）
#[tauri::command]
pub fn fetch_tickers(symbols: Vec<String>) -> Result<Vec<TickerBrief>, String> {
    // 上限保护：超出部分截断，避免 URL 过长被网关拒绝
    let symbols: Vec<String> = symbols.into_iter().take(100).collect();
    if symbols.is_empty() {
        return Ok(Vec::new());
    }
    let symbols_json = serde_json::to_string(&symbols).map_err(|e| format!("序列化参数失败: {e}"))?;
    let resp: Vec<Value> = rest_agent()
        .get("https://fapi.binance.com/fapi/v1/ticker/24hr")
        .query("symbols", &symbols_json)
        .call()
        .map_err(|e| format!("请求 Binance 失败: {e}"))?
        .into_json()
        .map_err(|e| format!("解析响应失败: {e}"))?;
    let mut list = Vec::with_capacity(resp.len());
    for item in resp {
        list.push(TickerBrief {
            symbol: item["symbol"].as_str().unwrap_or_default().to_string(),
            change_percent: item["priceChangePercent"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
        });
    }
    Ok(list)
}