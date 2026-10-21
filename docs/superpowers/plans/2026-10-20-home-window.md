# 首页主窗口实现计划（合约搜索 / K线图 / 仓位计算器）

> **For agentic workers:** 本计划由当前会话 inline 执行（executing-plans 模式，用户已授权全自动）。项目无 git 仓库，跳过所有 commit 步骤。

**Goal:** 新增 home 主窗口：合约搜索 → 24h 概览 + 六档周期自绘蜡烛图 → 逐仓仓位计算器（回报率/盈亏/强平价实时联动）。

**Architecture:** Rust 统一数据层（klines.rs 与 market.rs 同构：REST 首屏 + WS 增量 + generation 防残留），前端纯渲染；概览头部走 REST 10s 轮询（不动 market.rs 的胶囊单订阅）。

**Tech Stack:** Tauri 2 / Rust / React 19 / TypeScript / Canvas 2D / Vitest

---

## Task 1: Rust config.rs 扩展 positions

- Modify: `src-tauri/src/config.rs`
- 新增 `PositionConfig { symbol, direction, entry_price, leverage, quantity }`（camelCase 序列化）
- `CapsuleConfig` 加 `positions: Vec<PositionConfig>`（`#[serde(default)]` 兼容旧存档；Default 给空数组）
- 验证：`cargo check` 零错误

## Task 2: Rust klines.rs 数据层

- Create: `src-tauri/src/klines.rs`
- `Kline { opentime, closetime, open, high, low, close, volume, closed }` camelCase
- `fetch_klines(symbol, interval, limit)` REST `/fapi/v1/klines`（interval 白名单校验，limit ≤ 1000）
- `switch_kline_stream(app, symbol, interval)`：WS `<symbol>@kline_<interval>`，generation 防残留（照 market.rs 模式），指数退避重连；推 `kline-update`（Kline）与 `kline-status`
- `stop_kline_stream()`：generation+1 使旧任务退出
- `fetch_overview(symbol)`：REST `ticker/24hr` 返回 `OverviewData { symbol, lastPrice, changePercent, changeAmount, high, low, volume, quoteVolume }`
- Rust 侧 VecDeque 环形缓冲 500 根（当前流去重合并）
- 验证：`cargo check`

## Task 3: lib.rs 注册 + tauri.conf.json home 窗口

- Modify: `src-tauri/src/lib.rs`（mod klines；命令注册 fetch_klines/switch_kline_stream/stop_kline_stream/fetch_overview/open_home；菜单加"打开首页"capsule-home；setup 图标块覆盖 home 窗口）
- Modify: `src-tauri/tauri.conf.json`（home：1100x700、visible:false、center、resizable、minWidth 900 minHeight 600）
- 验证：`cargo check`

## Task 4: 前端类型 + 计算器公式 + Vitest 单测

- Modify: `src/types.ts`（Position、Kline、KlineStatus、MarketOverview、CapsuleConfig.positions）
- Create: `src/calc.ts`（computePosition 纯函数：margin/pnl/roe/liquidationPrice/liqDistance；强平价 = entry×(1∓0.9/lev)，多减空加）
- Create: `test/calc.test.ts`（多空双向、杠杆 1/125 边界、零值防御）
- Modify: `package.json`（+vitest devDep，scripts.test）
- 验证：`npx vitest run` 全绿

## Task 5: Home.tsx 主布局 + 搜索左栏 + 概览头部

- Create: `src/Home.tsx`；Modify: `src/main.tsx`（label=home 分流）
- 左栏 300px：搜索框 + 合约列表（复用 fetch_symbols，即时过滤 60 条上限）
- 选中合约 → fetch_klines(500) + switch_kline_stream + fetch_overview + 10s 轮询概览
- kline-update 监听：symbol 校验 + 500ms 合帧更新当前 K 线
- 概览头部：最新价（kline close 实时刷新）、24h 涨跌幅、高、低、成交量、涨跌色

## Task 6: CandleChart.tsx 自绘蜡烛图

- Create: `src/CandleChart.tsx`
- 单 Canvas 主图(蜡烛)+副图(成交量) 4:1；DPR 适配；网格 5% 透明度
- 交互：滚轮缩放（可见 30~300 根，围绕鼠标锚点）、拖拽平移、十字光标 + 顶部 OHLC 信息条（DOM）
- 最新价虚线 + 右侧标签；涨绿跌红与胶囊一致；WS 断连时状态提示由父组件传入

## Task 7: PositionCalculator.tsx

- Create: `src/PositionCalculator.tsx`
- 表单：方向(多/空)、开仓价、杠杆(1-125)、数量；选中合约变化自动回填 config.positions
- 输出卡实时联动最新价：保证金/未实现盈亏/回报率/强平价/强平距离 + 涨跌色
- 保存：get_config → 更新 positions → save_config（全量保存防覆盖胶囊字段）

## Task 8: home.css（finesse-ui 落地）

- Create: `src/styles/home.css`
- 执行时加载 finesse-ui skill；深色金融终端、玻璃拟态卡片、金色强调、tabular-nums

## Task 9: 入口接线

- Modify: `src/App.tsx`（双击胶囊 open_home；单击/双击用 250ms 延时区分避免误触 hidden 切换）
- Modify: `src/Settings.tsx`（顶部"打开首页"按钮）

## Task 10: 构建验证 + 实机自测

- `npm run build`（tsc 零错误）+ `cargo check` 零警告
- `npm run tauri build` 或 dev 模式实机：肉眼验证（既定方法论）
- 更新记忆