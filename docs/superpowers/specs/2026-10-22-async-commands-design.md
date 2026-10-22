# 网络命令 async 化修复断网卡死 设计

日期：2026-10-22
状态：根因明确（无需用户决策）

## 一、问题与根因

**症状**：首次打开无网络时窗口长时间无响应（Windows 幽灵窗：白色系统框架）；断网后也会卡死一会。

**根因链**：
1. `fetch_symbols`（lib.rs，ureq 5s 超时）、`fetch_klines` / `fetch_overview` / `fetch_tickers`（klines.rs，各 8s 超时）均为**同步 `#[tauri::command] fn`**。
2. Tauri 2 同步命令默认在**主线程**执行。
3. 断网时每次调用阻塞至超时（DNS/TCP 失败常等满 5-8 秒）；首页概览 10s 轮询 + 列表涨跌 10s 轮询叠加 → 主线程被持续占满 → WebView UI 线程消息泵饥饿 → 窗口无响应 → Win11 显示幽灵窗（系统接管渲染的白框）。

## 二、修复设计

4 个网络命令改 `async fn`，ureq 同步调用包 `tauri::async_runtime::spawn_blocking`（模式与 market.rs `run_polling` 一致）：

- `fetch_symbols`：`async fn` + `spawn_blocking(fetch_online_symbols)` + 缓存/回退逻辑不变（OnceLock/builtin 原样）
- `fetch_klines`：`async fn` + `spawn_blocking(闭包拉取)`
- `fetch_overview`：`async fn` + `spawn_blocking`
- `fetch_tickers`：`async fn` + `spawn_blocking`

返回类型不变（前端 invoke 无感知）。其余命令（get_config/save_config/open_* /minimize/hide/show_capsule_menu/switch_kline_stream/stop_kline_stream）不动：轻量或已异步。

## 三、错误处理

- spawn_blocking JoinError → `Err("后台任务异常")`（与现有错误消息风格一致）
- 网络失败错误消息原样透传（前端已有降级路径）

## 四、测试

1. cargo check / tsc / 单测 33 全绿
2. CDP 实测断网场景：启动应用（断网态）→ 60 秒内窗口保持响应（selftest isvis/click 均通）→ 价格 "—" + ⚠ 警示正常（已有功能不回归）
3. 回归：cdp-titlebar / cdp-interact

## 五、不做（YAGNI）

- 不做命令合并/缓存层重构
- 不做断网时停止轮询（保持警示功能依赖轮询信号）