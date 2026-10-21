# 首页主窗口设计（合约搜索 / K线图 / 仓位计算器）

- 日期：2026-10-20
- 状态：已确认（三段设计均获用户批准）
- 范围：Taskbar Crypto Monitor 新增 `home` 主窗口，含合约搜索、详情 K 线图、逐仓仓位计算器

## 1. 目标

新增独立"首页"主窗口（约 1100×700）：搜索并选择合约 → 查看详情（24h 概览 + 六档周期 K 线蜡烛图）→ 配置个人仓位（方向/开仓价/杠杆/数量）→ 实时计算回报率、未实现盈亏、强平价与强平距离。任务栏胶囊与设置窗口保持现状，不受影响。

## 2. 窗口与整体架构

### 窗口结构

| 窗口 | label | 变化 |
|---|---|---|
| 胶囊 | `capsule` | 不动；右键菜单新增"打开首页"；双击胶囊打开首页 |
| 设置 | `settings` | 不动；新增"打开首页"按钮入口 |
| 首页 | `home`（新增） | 1100×700，启动 `visible: false`，居中，可缩放 |

- 打开方式：双击胶囊 / 胶囊右键菜单 / 设置页按钮，复用 `open_settings` 的 show + set_focus 模式（Rust 命令 `open_home`）
- `main.tsx` 的 label 分流新增 `home` 分支

### 数据层（Rust，方案 A：统一数据层）

新增 `klines.rs`（与 `market.rs` 同构）：

- `fetch_klines(symbol, interval, limit)`：REST `GET /fapi/v1/klines` 拉历史（默认 500 根），Tauri 命令直接返回
- `switch_kline_stream(symbol, interval)`：订阅 WS `wss://fstream.binance.com/ws/<symbol>@kline_<interval>`，增量以 `kline-update` 事件推前端
- 切换即重连；generation 计数防旧流残留推送（复用 market.rs 已验证模式）
- 每周期环形缓冲上限 500 根（服务当前查看的 symbol+interval，切走即弃）

### 数据流

```
REST 首屏(500根) ──┐
                   ├→ 前端 state → Canvas 渲染
WS kline 增量 ─────┘（500ms 合帧节流）
```

### 持久化

`config.json` 新增 `positions` 数组，每元素：

```json
{
    "symbol": "BTCUSDT",
    "direction": "long",
    "entryPrice": 60000.0,
    "leverage": 20,
    "quantity": 0.01
}
```

每合约一条，保存即写盘；重新选中合约自动回填。

## 3. K 线图组件（CandleChart.tsx，自绘 Canvas，零依赖）

- 布局：主图（蜡烛 + 最新价虚线标签）+ 副图（成交量柱），高度比 4:1
- 交互：十字光标 + OHLC 浮窗；滚轮缩放（可见根数 30~300）；拖拽平移
- 周期：1m / 5m / 15m / 1h / 4h / 1d 药丸切换组，切换时重拉 REST + 重挂 WS
- 渲染：DPR 适配防模糊；涨绿跌红与胶囊配色一致；背景网格 5% 不透明度
- 更新：`kline-update` 事件 500ms 合帧重绘当前 K 线

## 4. 仓位计算器（PositionCalculator.tsx，纯前端公式）

输入：方向（多/空）、开仓价、杠杆（1~125）、数量（币）。

公式（实时联动最新价 `P`，`sign = +1 多头 / -1 空头`）：

```
保证金      = entryPrice × quantity / leverage
未实现盈亏  = (P − entryPrice) × quantity × sign
回报率      = (P − entryPrice) / entryPrice × leverage × sign
强平价      = entryPrice × (1 − sign/leverage) / (1 − sign × 0.9%)   （维持保证金率 0.9%，杠杆越高越贴近开仓价）
强平距离    = |强平价 − P| / P
```

- 输出区实时刷新并挂涨跌色
- 持久化经 `save_config` 随 `positions[]` 落盘

## 5. UI 设计基调

- 深色金融终端：近黑蓝底 + 玻璃拟态卡片，与胶囊 `#1e2c54→#3e6cc0` 渐变同族
- 语义色：涨绿跌红、金色强调（选中态指示条/周期药丸选中）
- 左栏 300px：搜索框 + 合约列表（即时过滤、悬停高亮、选中金色左条）
- 数值 tabular-nums 等宽，防跳动
- 实现阶段加载 finesse-ui skill 落地视觉细节

## 6. 错误处理

- K 线 REST 失败：图表区错误文案 + 重试按钮（大陆直连失败场景已有先例）
- WS kline 断连：图表冻结最后数据 + 状态提示，后台指数退避重连（复用 market.rs 模式）
- 合约列表：复用 online / builtin 双源回退
- 公式输入校验：杠杆 1~125、数量 > 0、开仓价 > 0，非法输入禁用保存

## 7. 验证策略

- 计算器公式：Vitest 单测（多空双向、杠杆边界 1/125、强平价、零值防御）
- 渲染与交互：用户肉眼验证（本机 CopyFromScreen 小窗口测量不可靠的既定结论）
- 构建：`npm run build` + `tsc` 零错误；`cargo check` 零警告

## 8. 不做的事（YAGNI）

- 不做全仓模式、追加保证金、资金费率计算
- 不做技术指标（MA/MACD/布林带）——后续可加
- 不做多合约同时持仓组合视图
- 不做交易下单（只读公开行情的既定约束）