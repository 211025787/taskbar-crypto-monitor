//! Binance USDⓈ-M 永续合约实时行情模块（WebSocket 优先 + REST 轮询回退）
//!
//! 策略：优先连接 `wss://fstream.binance.com/ws/<symbol>@ticker` 推送流；
//! 若连接失败或连接后一段时间无推送（部分代理环境对合约 WS 域名握手成功但不回数据），
//! 自动降级为 REST 轮询 `fapi/v1/ticker/24hr`（受限网络下实测可用）。
//! 切换合约时旧任务按订阅代号让位退出。

use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use serde_json::Value;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tauri::{AppHandle, Emitter};
use tokio_tungstenite::{connect_async, tungstenite::Message};

/// 实时行情快照（广播给前端，字段采用 camelCase 序列化）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TickerData {
    /// 合约名（如 BTCUSDT）
    pub symbol: String,
    /// 最新成交价（USDT 计价）
    pub price: f64,
    /// 24 小时涨跌幅（%，正值代表上涨）
    pub change_percent: f64,
    /// 24 小时涨跌额（USDT）
    pub change_amount: f64,
}

/// WebSocket 连接状态（广播给前端展示连接提示）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WsStatus {
    /// 状态：connecting / connected / reconnecting / polling
    pub state: String,
    /// 状态补充说明（如重连等待秒数、回退原因）
    pub detail: String,
}

/// 订阅代号：每次切换合约递增，旧任务检测到失配后自行退出
static SUBSCRIPTION: AtomicU64 = AtomicU64::new(0);

/// 当前已订阅的合约名（避免重复重连，仅在合约变化时切换）
static ACTIVE_SYMBOL: Mutex<String> = Mutex::new(String::new());

/// REST 轮询客户端（进程级复用连接池）
static REST_AGENT: OnceLock<ureq::Agent> = OnceLock::new();

/// WebSocket 连接后等待首条推送的超时（秒）：超时视为流不通，回退轮询
const FIRST_MESSAGE_TIMEOUT_SECS: u64 = 8;

/// REST 轮询间隔（毫秒）
const POLL_INTERVAL_MS: u64 = 1500;

/// 订阅指定合约的行情流（合约未变化时直接跳过，避免字段开关保存触发重连）
pub fn switch_symbol(app: &AppHandle, symbol: &str) {
    {
        let mut active = ACTIVE_SYMBOL.lock().expect("行情订阅状态锁中毒");
        if active.as_str() == symbol {
            return;
        }
        *active = symbol.to_string();
    }
    // 递增代号使旧任务退出，再启动新订阅任务（复用 Tauri 内置 tokio 运行时）
    let generation = SUBSCRIPTION.fetch_add(1, Ordering::SeqCst) + 1;
    let app = app.clone();
    let stream_symbol = symbol.to_lowercase();
    tauri::async_runtime::spawn(async move {
        run_stream(app, stream_symbol, generation).await;
    });
}

/// 行情流调度主循环：WebSocket 优先（首条超时判定假活流），断线指数退避重连
async fn run_stream(app: AppHandle, symbol: String, generation: u64) {
    let ws_url = format!("wss://fstream.binance.com/ws/{symbol}@ticker");
    println!("[market] 开始订阅行情: {symbol}");
    // 指数退避：1s 起步，每次翻倍，上限 60s；WS 恢复后归位
    let mut backoff_secs = 1u64;
    loop {
        // 订阅已被更新的合约取代：立即退出
        if SUBSCRIPTION.load(Ordering::SeqCst) != generation {
            println!("[market] 订阅已过期，任务退出: {symbol}");
            return;
        }
        let _ = app.emit("ws-status", WsStatus { state: "connecting".to_string(), detail: String::new() });
        match connect_async(ws_url.as_str()).await {
            Ok((ws, _)) => {
                println!("[market] WebSocket 已连接: {symbol}");
                let _ = app.emit("ws-status", WsStatus { state: "connected".to_string(), detail: String::new() });
                let (mut write, mut read) = ws.split();
                // 是否已收到首条推送（未收到前每条读取都带超时，用于识别假活流）
                let mut first_received = false;
                // 首条超时后置位：跳出收流进入轮询回退
                let mut fallback_polling = false;
                'recv: loop {
                    // 取下一条消息：活流无限等待；首条前带超时识别假活流
                    let item = if first_received {
                        match read.next().await {
                            Some(inner) => inner,
                            None => break 'recv,
                        }
                    } else {
                        match tokio::time::timeout(Duration::from_secs(FIRST_MESSAGE_TIMEOUT_SECS), read.next()).await {
                            Ok(Some(inner)) => inner,
                            Ok(None) => break 'recv,
                            Err(_) => {
                                println!(
                                    "[market] WebSocket 连接后 {FIRST_MESSAGE_TIMEOUT_SECS}s 无推送，回退 REST 轮询: {symbol}"
                                );
                                fallback_polling = true;
                                let _ = write.close().await;
                                break 'recv;
                            }
                        }
                    };
                    // 收流中途被切换：关闭连接并退出
                    if SUBSCRIPTION.load(Ordering::SeqCst) != generation {
                        let _ = write.close().await;
                        println!("[market] 订阅已过期，关闭连接退出: {symbol}");
                        return;
                    }
                    match item {
                        // 文本行情推送：解析后广播
                        Ok(Message::Text(text)) => {
                            first_received = true;
                            if let Some(ticker) = parse_ticker(&text) {
                                let _ = app.emit("ticker-update", &ticker);
                            }
                        }
                        // 服务器心跳：按协议回 pong 保活
                        Ok(Message::Ping(payload)) => {
                            first_received = true;
                            let _ = write.send(Message::Pong(payload)).await;
                        }
                        // 其余消息（Pong/Close/Frame）与行情无关，忽略
                        Ok(_) => {}
                        // 流错误：跳出收流循环进入重连
                        Err(e) => {
                            println!("[market] 流错误: {e}");
                            break 'recv;
                        }
                    }
                }
                // 假活流：回退轮询模式（仅订阅过期时返回）
                if fallback_polling {
                    run_polling(app, symbol, generation).await;
                    return;
                }
                // 真实断流：走外层指数退避重连
                println!("[market] 流结束，{backoff_secs}s 后重连: {symbol}");
                if SUBSCRIPTION.load(Ordering::SeqCst) != generation {
                    return;
                }
            }
            Err(e) => println!("[market] WebSocket 连接失败({backoff_secs}s 后重试): {e}"),
        }
        let _ = app.emit(
            "ws-status",
            WsStatus { state: "reconnecting".to_string(), detail: format!("{backoff_secs}s 后重连") },
        );
        tokio::time::sleep(Duration::from_secs(backoff_secs)).await;
        backoff_secs = (backoff_secs * 2).min(60);
    }
}

/// REST 轮询模式：按固定间隔拉取 24hr ticker 并广播，直到订阅过期
///
/// 适用于推送流不可用的网络环境（数据可用性与 WS 等价，延迟略高）。
/// 连续失败 3 次（约 4.5 秒无数据）广播 reconnecting 异常态，前端据此显示网络警示；
/// 恢复成功后广播 polling 复位。
async fn run_polling(app: AppHandle, symbol: String, generation: u64) {
    println!("[market] 进入 REST 轮询模式: {symbol}");
    let _ = app.emit(
        "ws-status",
        WsStatus { state: "polling".to_string(), detail: "推送流不可用，已切换轮询模式".to_string() },
    );
    // 连续失败计数：达到阈值（3）广播一次异常态；恢复成功后归零
    let mut consecutive_failures: u32 = 0;
    loop {
        // 订阅已被更新取代：退出轮询
        if SUBSCRIPTION.load(Ordering::SeqCst) != generation {
            println!("[market] 订阅已过期，轮询任务退出: {symbol}");
            return;
        }
        // ureq 为同步客户端：放阻塞线程池执行，避免占用异步工作线程
        let fetch_symbol = symbol.clone();
        let result = tauri::async_runtime::spawn_blocking(move || fetch_rest_ticker(&fetch_symbol)).await;
        match result {
            Ok(Ok(ticker)) => {
                let _ = app.emit("ticker-update", &ticker);
                // 此前处于异常广播态：恢复成功，复位轮询状态供前端撤销警示
                if consecutive_failures >= 3 {
                    let _ = app.emit(
                        "ws-status",
                        WsStatus { state: "polling".to_string(), detail: "网络已恢复，回到轮询模式".to_string() },
                    );
                }
                consecutive_failures = 0;
            }
            // 单次拉取失败（网络抖动等）：静默跳过，下一轮重试
            Ok(Err(e)) => {
                println!("[market] REST 轮询失败: {e}");
                consecutive_failures += 1;
                // 连续 3 次失败（约 4.5s 无数据）：广播网络异常，前端显示警示
                if consecutive_failures == 3 {
                    let _ = app.emit(
                        "ws-status",
                        WsStatus { state: "reconnecting".to_string(), detail: "轮询失败，网络异常".to_string() },
                    );
                }
            }
            Err(e) => {
                println!("[market] REST 轮询任务异常: {e}");
            }
        }
        tokio::time::sleep(Duration::from_millis(POLL_INTERVAL_MS)).await;
    }
}

/// REST 拉取单合约 24hr 行情（fapi/v1/ticker/24hr）
fn fetch_rest_ticker(symbol: &str) -> Result<TickerData, String> {
    let agent = REST_AGENT.get_or_init(|| {
        ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(5))
            .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) TaskbarCryptoMonitor/0.1")
            .build()
    });
    let url = format!("https://fapi.binance.com/fapi/v1/ticker/24hr?symbol={symbol}");
    let resp: Value = agent
        .get(&url)
        .call()
        .map_err(|e| format!("请求 Binance 失败: {e}"))?
        .into_json()
        .map_err(|e| format!("解析响应失败: {e}"))?;
    Ok(TickerData {
        symbol: resp["symbol"].as_str().unwrap_or_default().to_string(),
        price: resp["lastPrice"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
        change_percent: resp["priceChangePercent"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
        change_amount: resp["priceChange"].as_str().and_then(|v| v.parse().ok()).unwrap_or_default(),
    })
}

/// 解析 Binance 24hrTicker 推送消息；非行情推送返回 None
fn parse_ticker(text: &str) -> Option<TickerData> {
    let value: Value = serde_json::from_str(text).ok()?;
    if value["e"].as_str()? != "24hrTicker" {
        return None;
    }
    Some(TickerData {
        symbol: value["s"].as_str()?.to_string(),
        price: value["c"].as_str()?.parse().ok()?,
        change_percent: value["P"].as_str()?.parse().ok()?,
        change_amount: value["p"].as_str()?.parse().ok()?,
    })
}
