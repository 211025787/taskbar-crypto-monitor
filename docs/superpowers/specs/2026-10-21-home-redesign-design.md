# 首页改版 + 模拟应用功能设计

日期：2026-10-21
状态：已与用户对齐（方案 A · 持仓中心双列）

## 一、目标

1. **模拟 → 实际应用**：加减仓模拟面板增加"应用到仓位"按钮，一键把模拟结果更新为真实持仓（含累计已实现盈亏）。
2. **首页布局改版**：解决"UI 丑、交互差、信息不清晰"——按方案 A（持仓中心双列）重排，1081×362 超扁窗口内**零滚动**完成全部操作。

## 二、布局设计（方案 A）

```
┌──────────┬──────────────────────────────────────────────────────┐
│ 合约列表  │ 行情数据带：BTCUSDT 82,789.30 +1.52% 高·低·额 ⟳时间 [周期] │
│ (带涨跌%) ├──────────────────────────────┬───────────────────────┤
│ 搜索框    │                              │ 右栏（持仓中心）：      │
│ BTC +1.5% │        K 线图（占宽 2/3）      │ 有仓位→持仓卡+模拟卡   │
│ ETH +2.1% │                              │ 无仓位→新建仓位表单    │
│ ...      │                              │                       │
└──────────┴──────────────────────────────┴───────────────────────┘
```

- **左栏**（保留 300px 宽）：合约列表每项增加 24h 涨跌%（绿涨红跌），搜索行为不变。
- **行情数据带**（一行）：合约名 / 最新价 / 涨跌% / 高·低·成交额（次要灰字）/ 刷新时间+刷新按钮 / K 线周期药丸（从 K 线工具栏移入）。K 线流状态（重连中…）以小字附于数据带尾部。
- **K 线区**：占剩余宽度 2/3，高度撑满（原 canvas 自适应逻辑复用）。
- **右栏**（占 1/3）两态：
  - **有仓位**：上方持仓卡（方向·杠杆 / 均价·数量 / 保证金 / 浮盈·回报率 / 累计已实现 / 强平价·距离）+ 下方模拟操作卡（加/减仓切换、操作价、数量、预览结果、"应用到仓位"金色按钮）+ 删除仓位次级按钮。
  - **无仓位**：右栏整体变为"新建仓位"表单（方向 / 开仓价 / 杠杆 / 数量 / 预览 / "保存仓位"金色按钮）——原基础计算器不再单独占一块。

## 三、功能设计：模拟应用

### 数据模型变更

`Position`（TS `types.ts`）/ `PositionConfig`（Rust `config.rs`）新增字段：

```ts
/** 累计已实现盈亏（USDT，历次减仓锁定盈亏之和；新建/加仓不变，全平后保留供复盘） */
realizedPnl: number;
```

- Rust 侧加 `#[serde(default)]` → 旧 config.json 无此字段时反序列化为 0，向后兼容。
- 前端 `DEFAULT_CONFIG` 不变（positions 为空数组）。

### 应用逻辑（PositionCalculator 内）

1. 用户在模拟卡输入操作价（留空 = 最新价）+ 数量，预览结果（现有 `simulateAdjust`）。
2. 点击"应用到仓位"→ 按钮变**"确认应用？"**（两段式防误触，无弹窗；3 秒不点自动复原）。
3. 二次点击执行：
   - **加仓**：仓位 entryPrice ← newEntryPrice、quantity ← newQuantity（realizedPnl 不变）。
   - **减仓**：quantity ← newQuantity、realizedPnl ← realizedPnl + 本次锁定盈亏（entryPrice 不变）。
   - **全平**：quantity = 0，仓位保留（持仓卡显示"已平仓 · 累计 +X.XX"），用户可手动删除。
   - 全平后若模拟卡已无持仓可用 → 模拟卡显示"先新建仓位"占位。
4. 写入走现有 `save_config` 持久化；成功后表单/持仓卡刷新为新值，模拟输入清空。
5. 写入失败：按钮复原可重试（沿用现有 catch 静默模式）。

### 纯函数

`calc.ts` 新增 `applyAdjust(position, result, action): Position`（把模拟结果合成为新 Position 对象，便于单测）：
- 输入现仓位 + `simulateAdjust` 结果 + 操作类型。
- 输出新 Position（quantity=0 全平时保留 symbol/direction/entryPrice 供复盘展示）。

## 四、功能设计：合约列表涨跌%

### Rust 新增命令 `fetch_tickers(symbols: Vec<String>) -> Vec<TickerBrief>`

- 调 `https://fapi.binance.com/fapi/v1/ticker/24hr?symbols=["A","B",...]`（URL 编码 JSON 数组，单次 ≤100 个）。
- 返回 `TickerBrief { symbol, changePercent }`（仅列表需要的两个字段）。
- 失败返回 `Err`（前端列表显示"—"并沿用上次成功数据）。

### 前端

- Home 拉取 symbolList 后，对**渲染中的 60 个**合约每 10s 调一次 `fetch_tickers`（与概览轮询同节奏）。
- 列表项：`BTCUSDT +1.5%`（涨绿跌红灰 "—"）。
- 搜索过滤后列表变化时立即重拉一次（避免新出现的合约长时间无数据）。

## 五、组件结构

```
Home.tsx（重构）
├── SymbolList（内联，改造：+ 涨跌%）
├── MarketBar（新：原 overview 压缩成一行 + 周期药丸 + 刷新）
├── CandleChart（不动）
└── PositionPanel（原 PositionCalculator.tsx 改造）
    ├── 有仓位：PositionCard + AdjustSimulator（含应用按钮）+ 删除
    └── 无仓位：NewPositionForm（原基础表单+保存）
```

- 文件仍为 `Home.tsx` + `PositionCalculator.tsx`，不新开文件（规模可控）。
- `home.css` 相应重写布局段（flex 骨架从"垂直堆叠"改"顶带 + 双列"），设计 token 不变。

## 六、错误处理

| 场景 | 行为 |
|---|---|
| fetch_tickers 失败 | 列表涨跌% 显示 "—"，沿用上次数据 |
| 应用写入失败 | 按钮复原，可重试 |
| 全平后 symbol 切走再切回 | 持仓卡正常显示已平仓仓位 |
| 旧 config.json 兼容 | serde default → realizedPnl=0 |

## 七、测试

1. **单测**（vitest）：`applyAdjust` 加仓/减仓/全平/累计已实现盈亏叠加（两次减仓）、非法输入。
2. **CDP 实测**（新增/改造脚本）：
   - `cdp-apply.mjs`：新建→保存→模拟减仓→两段式应用→断言持仓卡数量/均价/累计已实现更新、config.json 落盘、删除仓位恢复。
   - `cdp-sim.mjs`/`cdp-interact.mjs`：适配新 DOM 类名与新布局。
   - 零滚动断言：`document.scrollingElement.scrollHeight <= clientHeight`。
3. **回归**：cdp-calc / cdp-save 全绿后打包 NSIS。

## 八、不做（YAGNI）

- 不做交易下单（纯本地记账）。
- 不做自选收藏分组（列表排序仍按字母序）。
- 不做窗口尺寸调整（维持 1081×362 固定）。
- 不做多仓位管理页（每合约一条，现状不变）。