# 首页改版 + 模拟应用 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按方案 A（持仓中心双列）重排首页实现零滚动，并给加减仓模拟加"应用到仓位"（含累计已实现盈亏持久化），合约列表增加 24h 涨跌%。

**Architecture:** 前端三文件重构（Home.tsx 布局、PositionCalculator.tsx 双态面板、home.css 布局段重写）；数据模型 `Position`/`PositionConfig` 增加 `realizedPnl`（Rust `#[serde(default)]` 兼容旧配置）；Rust 新增 `fetch_tickers` 批量涨跌命令；纯函数 `applyAdjust` 承载应用逻辑便于单测。

**Tech Stack:** Tauri 2 + Rust（ureq）+ React 19 + TypeScript + Vite + vitest；实机验证走 WebView2 CDP（端口 9333）。

**设计 spec:** `docs/superpowers/specs/2026-10-21-home-redesign-design.md`

---

## 关键约定（全程适用）

- code-spec：4 空格缩进、行宽 160、UTF-8 无 BOM、类/方法/属性全覆盖文档注释、删未用导入、禁止通配符导入。
- 构建必须 PowerShell 原生环境（模板已存 `scripts/build-nsis.ps1`）。
- 项目是 git 仓库，每任务结束 commit。
- CDP 点击前必须 `scrollIntoView`（视口外坐标注入会被静默丢弃）。

## 类名映射表（CDP 脚本与 CSS 均按此执行）

| 旧 | 新 |
|---|---|
| `.ycs-overview`（大头部） | `.ycs-marketbar`（一行数据带） |
| `.ycs-overview__symbol/__price/__change/__time/__refresh-btn` | `.ycs-marketbar__symbol/__price/__change/__time/__refresh-btn` |
| `.ycs-overview__stats/__stat/__stat-label/__stat-value` | 删除（高低/额压成 `.ycs-marketbar__extra` 一段灰字） |
| `.ycs-chart-panel__toolbar`（周期+状态） | 移入 `.ycs-marketbar`（`.ycs-intervals` 类名不变，状态 `.ycs-marketbar__status`） |
| `.ycs-calc`（计算器大区） | `.ycs-panel`（右栏容器） |
| `.ycs-calc__form`（基础表单） | `.ycs-newpos__form`（仅新建态渲染；field/input/label/direction/dir-btn 子类名不变） |
| `.ycs-calc__results`（基础结果格） | `.ycs-newpos__results`（result/label/value 子类名不变） |
| `.ycs-calc__save/__remove/__hint` | `.ycs-newpos__save/__remove/__hint`（hint 文案逻辑保留） |
| （无） | `.ycs-poscard`（持仓卡）+ `.ycs-poscard__row/__label/__value/__closed` |
| `.ycs-sim__*` | 不变（新增 `.ycs-sim__apply` / `.ycs-sim__apply--confirm`） |
| （无） | `.ycs-home__body`（主区双列容器：图 + 右栏） |
| （无） | `.ycs-home__symbol-change`（列表项涨跌%，`--up/--down` 修饰） |

---

### Task 1: 数据模型 + applyAdjust 纯函数（TDD）

**Files:**
- Modify: `src/types.ts:19-31`
- Modify: `src/calc.ts`（文件末尾追加）
- Modify: `test/calc.test.ts`（工厂 + 末尾追加）

- [ ] **Step 1: 写失败测试**

`test/calc.test.ts`：工厂 `makePosition` 增加默认字段（第 8-16 行的 return 对象内，`quantity: 1` 之后）：

```ts
        realizedPnl: 0,
```

文件末尾追加：

```ts
describe("applyAdjust 应用模拟结果", () => {
    it("加仓：更新均价与数量，累计已实现盈亏不变", () => {
        const sim = simulateAdjust({ direction: "long", entryPrice: 1, quantity: 10, leverage: 10, action: "add", adjustPrice: 0.9, adjustQuantity: 10 }, 1)!;
        const next = applyAdjust(makePosition({ entryPrice: 1, quantity: 10, leverage: 10, realizedPnl: 0.5 }), sim, "add");
        expect(next.entryPrice).toBeCloseTo(0.95);
        expect(next.quantity).toBe(20);
        expect(next.realizedPnl).toBe(0.5);
    });

    it("减仓：均价不变、数量减少、累计已实现盈亏叠加", () => {
        const sim = simulateAdjust({ direction: "long", entryPrice: 1, quantity: 10, leverage: 10, action: "reduce", adjustPrice: 0.9, adjustQuantity: 4 }, 1)!;
        const next = applyAdjust(makePosition({ entryPrice: 1, quantity: 10, leverage: 10, realizedPnl: -1 }), sim, "reduce");
        expect(next.entryPrice).toBe(1);
        expect(next.quantity).toBe(6);
        expect(next.realizedPnl).toBeCloseTo(-1.4);
    });

    it("两次连续减仓：累计已实现盈亏正确叠加到全平", () => {
        const p0 = makePosition({ entryPrice: 1, quantity: 10, leverage: 10 });
        const s1 = simulateAdjust({ direction: "long", entryPrice: 1, quantity: 10, leverage: 10, action: "reduce", adjustPrice: 1.2, adjustQuantity: 4 }, 1)!;
        const p1 = applyAdjust(p0, s1, "reduce");
        const s2 = simulateAdjust({ direction: "long", entryPrice: 1, quantity: 6, leverage: 10, action: "reduce", adjustPrice: 1.1, adjustQuantity: 6 }, 1)!;
        const p2 = applyAdjust(p1, s2, "reduce");
        expect(p2.quantity).toBe(0);
        expect(p2.realizedPnl).toBeCloseTo(0.8 + 0.6);
    });

    it("全平：数量归零但保留复盘信息（symbol/方向/均价）", () => {
        const sim = simulateAdjust({ direction: "short", entryPrice: 2, quantity: 5, leverage: 5, action: "reduce", adjustPrice: 1.8, adjustQuantity: 5 }, 2)!;
        const next = applyAdjust(makePosition({ direction: "short", entryPrice: 2, quantity: 5, leverage: 5 }), sim, "reduce");
        expect(next.quantity).toBe(0);
        expect(next.symbol).toBe("BTCUSDT");
        expect(next.direction).toBe("short");
        expect(next.entryPrice).toBe(2);
        expect(next.realizedPnl).toBeCloseTo(1);
    });
});
```

`test/calc.test.ts` 头部 import 增加 `applyAdjust`：

```ts
import { applyAdjust, computePosition, formatMoney, formatSignedPercent, isPositionValid, simulateAdjust } from "../src/calc";
```

- [ ] **Step 2: 跑测试确认失败**

Run: `npm test -- --run 2>&1 | tail -20`
Expected: FAIL（`applyAdjust` 未定义 / 类型缺 `realizedPnl`）

- [ ] **Step 3: 实现 types.ts 与 calc.ts**

`src/types.ts` 的 `Position` 接口（第 30 行 `quantity` 后追加，同时更新其上方注释）：

```ts
    /** 持仓数量（以币计，正数；全平后为 0，仓位保留供复盘） */
    quantity: number;
    /** 累计已实现盈亏（USDT，历次减仓锁定盈亏之和；新建为 0，加仓不变，全平后保留） */
    realizedPnl: number;
```

`src/calc.ts` 末尾追加：

```ts
/** 把一次模拟结果合成为新仓位对象（"应用到仓位"的纯函数变换，便于单测）
 *
 * 加仓 = 均价/数量替换为模拟结果；减仓 = 数量替换 + 累计已实现盈亏叠加。
 * 全平（newQuantity = 0）时保留 symbol/方向/均价/杠杆供复盘展示。
 *
 * @param position 现持仓（含累计已实现盈亏）
 * @param sim simulateAdjust 返回的操作后指标
 * @param action 操作类型：加仓 / 减仓
 * @returns 新仓位对象（不修改入参）
 */
export function applyAdjust(position: Position, sim: AdjustResult, action: "add" | "reduce"): Position {
    if (action === "add") {
        return { ...position, entryPrice: sim.newEntryPrice, quantity: sim.newQuantity };
    }
    return { ...position, quantity: sim.newQuantity, realizedPnl: position.realizedPnl + sim.realizedPnl };
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `npm test -- --run 2>&1 | tail -5`
Expected: 全部 PASS（原 29 + 新 4 = 33）。注意此时 `src/PositionCalculator.tsx` 与 `src/Home.tsx` 因类型缺字段会 tsc 报错——属预期，Task 4/5 修复；`npm test`（vitest）不跑 tsc 不受影响。

- [ ] **Step 5: Commit**

```bash
git add src/types.ts src/calc.ts test/calc.test.ts
git commit -m "Feat Position 增加 realizedPnl + applyAdjust 纯函数与单测"
```

---

### Task 2: Rust PositionConfig 增加 realized_pnl（向后兼容）

**Files:**
- Modify: `src-tauri/src/config.rs:14-25`

- [ ] **Step 1: 修改 PositionConfig**

`src-tauri/src/config.rs` 的 `PositionConfig` 结构体，在 `quantity` 字段后追加：

```rust
    /// 累计已实现盈亏（USDT，历次减仓锁定盈亏之和；旧配置缺省为 0）
    #[serde(default)]
    pub realized_pnl: f64,
```

- [ ] **Step 2: cargo check 验证**

Run: `powershell -NoProfile -Command '$env:RUSTUP_HOME="D:\develop\rust\rustup"; $env:CARGO_HOME="D:\develop\rust\cargo"; $env:PATH="D:\develop\msys2\mingw64\bin;D:\develop\rust\cargo\bin;C:\Windows\System32;C:\Windows"; Set-Location D:\ipyProject\ai-contract\src-tauri; cargo check 2>&1 | Select-Object -Last 5'`
Expected: 无 error（config.rs 无其他构造点；`Default for CapsuleConfig` 的 positions 为空 Vec 不涉及）

- [ ] **Step 3: Commit**

```bash
git add src-tauri/src/config.rs
git commit -m "Feat PositionConfig 增加 realized_pnl（serde default 兼容旧配置）"
```

---

### Task 3: Rust fetch_tickers 批量涨跌命令

**Files:**
- Modify: `src-tauri/src/klines.rs`（文件末尾追加）
- Modify: `src-tauri/src/lib.rs:12`（use）与 `:228-239`（注册）

- [ ] **Step 1: klines.rs 末尾追加命令**

```rust
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
```

- [ ] **Step 2: lib.rs 注册**

`src-tauri/src/lib.rs:12` 的 use 改为：

```rust
use klines::{fetch_klines, fetch_overview, fetch_tickers, stop_kline_stream, switch_kline_stream};
```

`invoke_handler` 列表（`fetch_overview` 之后）追加一行：

```rust
            fetch_overview,
            fetch_tickers
```

- [ ] **Step 3: cargo check 验证**

Run: `powershell -NoProfile -Command '$env:RUSTUP_HOME="D:\develop\rust\rustup"; $env:CARGO_HOME="D:\develop\rust\cargo"; $env:PATH="D:\develop\msys2\mingw64\bin;D:\develop\rust\cargo\bin;C:\Windows\System32;C:\Windows"; Set-Location D:\ipyProject\ai-contract\src-tauri; cargo check 2>&1 | Select-Object -Last 5'`
Expected: 无 error

- [ ] **Step 4: Commit**

```bash
git add src-tauri/src/klines.rs src-tauri/src/lib.rs
git commit -m "Feat fetch_tickers 命令批量拉取合约 24h 涨跌幅"
```

---

### Task 4: PositionCalculator.tsx 重构为双态面板

**Files:**
- Modify: `src/PositionCalculator.tsx`（整文件重写）

- [ ] **Step 1: 重写组件**

保留文件头注释与 `CalcFormText`/`EMPTY_FORM`/`parseText`/`sanitizeNumberText`（第 1-66 行原样），从 `/** 仓位计算器：... */` 起替换为以下完整实现：

```tsx
/** 仓位面板（右栏）：有仓位 = 持仓卡 + 模拟操作卡（可应用）；无仓位 = 新建仓位表单 */
export default function PositionCalculator({ symbol, lastPrice, config, onConfigChange }: PositionCalculatorProps) {
    /** 新建表单文本态（无仓位时渲染；保存成功后重置） */
    const [form, setForm] = useState<CalcFormText>(EMPTY_FORM);
    /** 新建仓位方向：多头 / 空头 */
    const [direction, setDirection] = useState<Position["direction"]>("long");
    /** 模拟操作类型：加仓 / 减仓 */
    const [simAction, setSimAction] = useState<"add" | "reduce">("add");
    /** 模拟操作价输入文本（空 = 跟随最新价，placeholder 实时显示） */
    const [simPriceText, setSimPriceText] = useState("");
    /** 模拟操作数量输入文本 */
    const [simQtyText, setSimQtyText] = useState("");
    /** 应用按钮两段式确认标记（true = 已进入"确认应用？"待二次点击） */
    const [confirming, setConfirming] = useState(false);
    /** 确认态自动复原定时器（3 秒无二次点击回到普通态） */
    const confirmTimerRef = useRef<number | null>(null);

    // 卸载时清理确认定时器
    useEffect(() => () => {
        if (confirmTimerRef.current !== null) {
            window.clearTimeout(confirmTimerRef.current);
        }
    }, []);

    /** 当前合约的持久化仓位（无则右栏渲染新建表单） */
    const persistedPosition = config.positions.find((item) => item.symbol === symbol) ?? null;

    // ===== 新建表单派生态 =====
    const draft: Position = {
        symbol,
        direction,
        entryPrice: parseText(form.entryText),
        leverage: Math.round(parseText(form.levText)),
        quantity: parseText(form.qtyText)
    };
    const draftValid = isPositionValid(draft);
    const draftResult = lastPrice !== null ? computePosition(draft, lastPrice) : null;

    // ===== 持仓卡派生态 =====
    const liveResult = persistedPosition !== null && lastPrice !== null ? computePosition(persistedPosition, lastPrice) : null;
    /** 是否已全平（数量为 0 的复盘态仓位） */
    const closed = (persistedPosition?.quantity ?? 0) === 0;

    // ===== 模拟派生态（基于持久化仓位） =====
    // 操作价为空时跟随实时最新价：默认即在当前价操作，手动输入则固定
    const simPrice = simPriceText.trim() === "" ? (lastPrice ?? 0) : parseText(simPriceText);
    const simQty = parseText(simQtyText);
    const simResult =
        persistedPosition !== null && persistedPosition.quantity > 0 && lastPrice !== null
            ? simulateAdjust(
                  {
                      direction: persistedPosition.direction,
                      entryPrice: persistedPosition.entryPrice,
                      quantity: persistedPosition.quantity,
                      leverage: persistedPosition.leverage,
                      action: simAction,
                      adjustPrice: simPrice,
                      adjustQuantity: simQty
                  },
                  lastPrice
              )
            : null;
    // 减仓超量专属提示（simulateAdjust 返回 null 的具体原因之一）
    const simOverReduce = simAction === "reduce" && simQty > (persistedPosition?.quantity ?? 0);

    /** 保存新仓位到磁盘（新建表单提交）：合并进 positions 后全量保存并重置表单 */
    const saveDraft = () => {
        const next: CapsuleConfig = {
            ...config,
            positions: [...config.positions.filter((item) => item.symbol !== symbol), { ...draft, symbol, realizedPnl: 0 }]
        };
        invoke("save_config", { config: next })
            .then(() => {
                onConfigChange(next);
                setDirection("long");
                setForm(EMPTY_FORM);
            })
            .catch(() => undefined);
    };

    /** 删除当前合约的持久化仓位（复盘态清理 / 重新开仓入口） */
    const removePosition = () => {
        const next: CapsuleConfig = { ...config, positions: config.positions.filter((item) => item.symbol !== symbol) };
        invoke("save_config", { config: next })
            .then(() => {
                onConfigChange(next);
                setDirection("long");
                setForm(EMPTY_FORM);
                setSimAction("add");
                setSimPriceText("");
                setSimQtyText("");
            })
            .catch(() => undefined);
    };

    /** 应用模拟结果到真实仓位：首击进入确认态（3 秒自动复原），二击写入磁盘 */
    const applySim = () => {
        if (persistedPosition === null || simResult === null) {
            return;
        }
        if (!confirming) {
            setConfirming(true);
            confirmTimerRef.current = window.setTimeout(() => {
                confirmTimerRef.current = null;
                setConfirming(false);
            }, 3000);
            return;
        }
        if (confirmTimerRef.current !== null) {
            window.clearTimeout(confirmTimerRef.current);
            confirmTimerRef.current = null;
        }
        const nextPosition = applyAdjust(persistedPosition, simResult, simAction);
        const next: CapsuleConfig = {
            ...config,
            positions: [...config.positions.filter((item) => item.symbol !== symbol), nextPosition]
        };
        invoke("save_config", { config: next })
            .then(() => {
                onConfigChange(next);
                setConfirming(false);
                setSimPriceText("");
                setSimQtyText("");
            })
            .catch(() => setConfirming(false));
    };

    // ===== 无仓位：新建仓位表单 =====
    if (persistedPosition === null) {
        return (
            <section className="ycs-panel">
                <div className="ycs-newpos__form">
                    <div className="ycs-calc__field">
                        <label className="ycs-calc__label">方向</label>
                        <div className="ycs-calc__direction">
                            <button
                                type="button"
                                className={`ycs-calc__dir-btn ${direction === "long" ? "ycs-calc__dir-btn--long" : ""}`}
                                onClick={() => setDirection("long")}
                            >
                                做多
                            </button>
                            <button
                                type="button"
                                className={`ycs-calc__dir-btn ${direction === "short" ? "ycs-calc__dir-btn--short" : ""}`}
                                onClick={() => setDirection("short")}
                            >
                                做空
                            </button>
                        </div>
                    </div>
                    <div className="ycs-calc__field">
                        <label className="ycs-calc__label">开仓价 (USDT)</label>
                        <input
                            className="ycs-calc__input"
                            type="text"
                            inputMode="decimal"
                            autoComplete="off"
                            value={form.entryText}
                            placeholder="0.00"
                            onChange={(event) => setForm((prev) => ({ ...prev, entryText: sanitizeNumberText(event.target.value, false) }))}
                        />
                    </div>
                    <div className="ycs-calc__field">
                        <label className="ycs-calc__label">杠杆倍数 (1-125)</label>
                        <input
                            className="ycs-calc__input"
                            type="text"
                            inputMode="numeric"
                            autoComplete="off"
                            value={form.levText}
                            placeholder="10"
                            onChange={(event) => setForm((prev) => ({ ...prev, levText: sanitizeNumberText(event.target.value, true) }))}
                        />
                    </div>
                    <div className="ycs-calc__field">
                        <label className="ycs-calc__label">数量 (币)</label>
                        <input
                            className="ycs-calc__input"
                            type="text"
                            inputMode="decimal"
                            autoComplete="off"
                            value={form.qtyText}
                            placeholder="0.00"
                            onChange={(event) => setForm((prev) => ({ ...prev, qtyText: sanitizeNumberText(event.target.value, false) }))}
                        />
                    </div>
                </div>
                <div className="ycs-newpos__results">
                    <div className="ycs-calc__result">
                        <span className="ycs-calc__result-label">占用保证金</span>
                        <span className="ycs-calc__result-value">{draftResult ? `${formatMoney(draftResult.margin)} USDT` : "—"}</span>
                    </div>
                    <div className={`ycs-calc__result ${(draftResult?.pnl ?? 0) >= 0 ? "ycs-calc__result--up" : "ycs-calc__result--down"}`}>
                        <span className="ycs-calc__result-label">未实现盈亏</span>
                        <span className="ycs-calc__result-value">
                            {draftResult ? `${draftResult.pnl >= 0 ? "+" : ""}${formatMoney(draftResult.pnl)} USDT` : "—"}
                        </span>
                    </div>
                    <div className={`ycs-calc__result ${(draftResult?.roe ?? 0) >= 0 ? "ycs-calc__result--up" : "ycs-calc__result--down"}`}>
                        <span className="ycs-calc__result-label">回报率</span>
                        <span className="ycs-calc__result-value">{draftResult ? formatSignedPercent(draftResult.roe) : "—"}</span>
                    </div>
                    <div className="ycs-calc__result">
                        <span className="ycs-calc__result-label">预估强平价</span>
                        <span className="ycs-calc__result-value">{draftResult ? draftResult.liquidationPrice.toPrecision(8) : "—"}</span>
                    </div>
                </div>
                <div className="ycs-newpos__hint">{draftValid ? "按最新价实时预览（可先保存后用模拟加/减仓）" : "填写完整后可保存仓位"}</div>
                <div className="ycs-newpos__actions">
                    <button type="button" className="ycs-newpos__save" disabled={!draftValid} onClick={saveDraft}>
                        保存仓位
                    </button>
                </div>
            </section>
        );
    }

    // ===== 有仓位：持仓卡 + 模拟操作卡 =====
    return (
        <section className="ycs-panel">
            <div className="ycs-poscard">
                <div className="ycs-poscard__head">
                    <h3 className="ycs-poscard__title">当前持仓</h3>
                    {closed ? (
                        <span className="ycs-poscard__closed">已平仓</span>
                    ) : (
                        <span className={`ycs-poscard__dir ${persistedPosition.direction === "long" ? "ycs-poscard__dir--long" : "ycs-poscard__dir--short"}`}>
                            {persistedPosition.direction === "long" ? "多" : "空"} · {persistedPosition.leverage}×
                        </span>
                    )}
                </div>
                {closed ? (
                    <div className={`ycs-poscard__row ${(persistedPosition.realizedPnl ?? 0) >= 0 ? "ycs-poscard__row--up" : "ycs-poscard__row--down"}`}>
                        <span className="ycs-poscard__label">累计已实现盈亏</span>
                        <span className="ycs-poscard__value">
                            {persistedPosition.realizedPnl >= 0 ? "+" : ""}
                            {formatMoney(persistedPosition.realizedPnl)} USDT
                        </span>
                    </div>
                ) : (
                    <>
                        <div className="ycs-poscard__row">
                            <span className="ycs-poscard__label">均价 / 数量</span>
                            <span className="ycs-poscard__value">
                                {persistedPosition.entryPrice.toPrecision(8)} · {persistedPosition.quantity.toPrecision(8)}
                            </span>
                        </div>
                        <div className="ycs-poscard__row">
                            <span className="ycs-poscard__label">占用保证金</span>
                            <span className="ycs-poscard__value">{liveResult ? `${formatMoney(liveResult.margin)} USDT` : "—"}</span>
                        </div>
                        <div className={`ycs-poscard__row ${(liveResult?.pnl ?? 0) >= 0 ? "ycs-poscard__row--up" : "ycs-poscard__row--down"}`}>
                            <span className="ycs-poscard__label">浮盈 / 回报率</span>
                            <span className="ycs-poscard__value">
                                {liveResult ? `${liveResult.pnl >= 0 ? "+" : ""}${formatMoney(liveResult.pnl)} · ${formatSignedPercent(liveResult.roe)}` : "—"}
                            </span>
                        </div>
                        <div className={`ycs-poscard__row ${persistedPosition.realizedPnl >= 0 ? "ycs-poscard__row--up" : "ycs-poscard__row--down"}`}>
                            <span className="ycs-poscard__label">累计已实现</span>
                            <span className="ycs-poscard__value">
                                {persistedPosition.realizedPnl >= 0 ? "+" : ""}
                                {formatMoney(persistedPosition.realizedPnl)} USDT
                            </span>
                        </div>
                        <div className="ycs-poscard__row">
                            <span className="ycs-poscard__label">强平价 / 距离</span>
                            <span className="ycs-poscard__value">
                                {liveResult ? `${liveResult.liquidationPrice.toPrecision(8)} · ${liveResult.liqDistance.toFixed(2)}%` : "—"}
                            </span>
                        </div>
                    </>
                )}
            </div>

            <div className="ycs-sim">
                <div className="ycs-sim__head">
                    <h3 className="ycs-sim__title">模拟操作</h3>
                    <span className="ycs-sim__badge">预览 → 应用</span>
                </div>
                {closed ? (
                    <div className="ycs-sim__hint">仓位已平，删除后可重新开仓</div>
                ) : (
                    <>
                        <div className="ycs-sim__form">
                            <div className="ycs-calc__field">
                                <label className="ycs-calc__label">操作</label>
                                <div className="ycs-calc__direction">
                                    <button
                                        type="button"
                                        className={`ycs-calc__dir-btn ${simAction === "add" ? "ycs-calc__dir-btn--long" : ""}`}
                                        onClick={() => setSimAction("add")}
                                    >
                                        加仓
                                    </button>
                                    <button
                                        type="button"
                                        className={`ycs-calc__dir-btn ${simAction === "reduce" ? "ycs-calc__dir-btn--short" : ""}`}
                                        onClick={() => setSimAction("reduce")}
                                    >
                                        减仓
                                    </button>
                                </div>
                            </div>
                            <div className="ycs-calc__field">
                                <label className="ycs-calc__label">操作价 (USDT)</label>
                                <input
                                    className="ycs-calc__input"
                                    type="text"
                                    inputMode="decimal"
                                    autoComplete="off"
                                    value={simPriceText}
                                    placeholder={lastPrice !== null ? String(lastPrice) : "当前价"}
                                    onChange={(event) => setSimPriceText(sanitizeNumberText(event.target.value, false))}
                                />
                            </div>
                            <div className="ycs-calc__field">
                                <label className="ycs-calc__label">数量 (币)</label>
                                <input
                                    className="ycs-calc__input"
                                    type="text"
                                    inputMode="decimal"
                                    autoComplete="off"
                                    value={simQtyText}
                                    placeholder="0.00"
                                    onChange={(event) => setSimQtyText(sanitizeNumberText(event.target.value, false))}
                                />
                            </div>
                        </div>
                        <div className="ycs-sim__results">
                            <div className="ycs-calc__result">
                                <span className="ycs-calc__result-label">操作后均价</span>
                                <span className="ycs-calc__result-value">{simResult ? simResult.newEntryPrice.toPrecision(8) : "—"}</span>
                            </div>
                            <div className="ycs-calc__result">
                                <span className="ycs-calc__result-label">操作后数量</span>
                                <span className="ycs-calc__result-value">{simResult ? simResult.newQuantity.toPrecision(8) : "—"}</span>
                            </div>
                            <div className="ycs-calc__result">
                                <span className="ycs-calc__result-label">操作后保证金</span>
                                <span className="ycs-calc__result-value">{simResult ? `${formatMoney(simResult.newMargin)} USDT` : "—"}</span>
                            </div>
                            <div className={`ycs-calc__result ${(simResult?.newPnl ?? 0) >= 0 ? "ycs-calc__result--up" : "ycs-calc__result--down"}`}>
                                <span className="ycs-calc__result-label">操作后盈亏</span>
                                <span className="ycs-calc__result-value">
                                    {simResult ? `${simResult.newPnl >= 0 ? "+" : ""}${formatMoney(simResult.newPnl)} USDT` : "—"}
                                </span>
                            </div>
                            <div className={`ycs-calc__result ${(simResult?.newRoe ?? 0) >= 0 ? "ycs-calc__result--up" : "ycs-calc__result--down"}`}>
                                <span className="ycs-calc__result-label">操作后回报率</span>
                                <span className="ycs-calc__result-value">{simResult ? formatSignedPercent(simResult.newRoe) : "—"}</span>
                            </div>
                            <div className="ycs-calc__result">
                                <span className="ycs-calc__result-label">操作后强平价</span>
                                <span className="ycs-calc__result-value">{simResult ? simResult.newLiquidationPrice.toPrecision(8) : "—"}</span>
                            </div>
                            {simAction === "reduce" && (
                                <div className={`ycs-calc__result ${(simResult?.realizedPnl ?? 0) >= 0 ? "ycs-calc__result--up" : "ycs-calc__result--down"}`}>
                                    <span className="ycs-calc__result-label">本次已实现盈亏</span>
                                    <span className="ycs-calc__result-value">
                                        {simResult ? `${simResult.realizedPnl >= 0 ? "+" : ""}${formatMoney(simResult.realizedPnl)} USDT` : "—"}
                                    </span>
                                </div>
                            )}
                        </div>
                        <div className="ycs-sim__hint">
                            {simQty <= 0 ? "输入操作数量后即时计算（操作价留空 = 按最新价）" : simOverReduce ? "减仓数量超出当前持仓" : ""}
                        </div>
                        <button
                            type="button"
                            className={`ycs-sim__apply ${confirming ? "ycs-sim__apply--confirm" : ""}`}
                            disabled={simResult === null}
                            onClick={applySim}
                        >
                            {confirming ? "确认应用？" : "应用到仓位"}
                        </button>
                    </>
                )}
            </div>

            <div className="ycs-newpos__actions">
                <button type="button" className="ycs-newpos__remove" onClick={removePosition}>
                    删除仓位
                </button>
            </div>
        </section>
    );
}
```

头部 import 更新（第 1-3 行）：

```tsx
import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { applyAdjust, computePosition, formatMoney, formatSignedPercent, isPositionValid, simulateAdjust } from "./calc";
```

- [ ] **Step 2: 类型检查**

Run: `npx tsc --noEmit 2>&1 | head -10`
Expected: PositionCalculator 无错误（Home.tsx 的报错留待 Task 5；若 Home 报 `realizedPnl` 缺失相关错误属预期）

- [ ] **Step 3: Commit**

```bash
git add src/PositionCalculator.tsx
git commit -m "Refactor PositionCalculator 双态面板（持仓卡+模拟应用/新建表单）"
```

---

### Task 5: Home.tsx 布局重构（MarketBar + 双列 + 列表涨跌%）

**Files:**
- Modify: `src/types.ts`（末尾追加 TickerBrief）
- Modify: `src/Home.tsx`（render 与新增 effect）

- [ ] **Step 1: types.ts 末尾追加**

```ts
/** 合约列表行情简报（fetch_tickers 命令返回元素） */
export interface TickerBrief {
    /** 合约名（如 BTCUSDT） */
    symbol: string;
    /** 24 小时涨跌幅（%，正值代表上涨） */
    changePercent: number;
}
```

- [ ] **Step 2: Home.tsx 增量修改**

① 头部 import 的 types 增加 `TickerBrief`：

```ts
import { DEFAULT_CONFIG, KLINE_INTERVALS, type CapsuleConfig, type Kline, type KlineInterval, type KlineStatus, type MarketOverview, type SymbolList, type TickerBrief } from "./types";
```

② 常量区（`SYMBOL_LIST_MAX` 后）追加：

```ts
/** 合约列表涨跌%轮询间隔（毫秒） */
const TICKER_POLL_MS = 10000;
```

③ state 区（`refreshKey` 后）追加：

```ts
    /** 列表涨跌%快照（合约名 → 24h 涨跌幅；拉取失败沿用上次数据） */
    const [tickerChanges, setTickerChanges] = useState<Record<string, number>>({});
```

④ `filteredSymbols` useMemo 之后追加轮询 effect：

```ts
    // 列表涨跌%轮询：对渲染中的合约批量拉取（过滤结果变化时立即重拉一次）
    useEffect(() => {
        const names = filteredSymbols.map((item) => item.symbol);
        if (names.length === 0) {
            return;
        }
        let stopped = false;
        const poll = () => {
            invoke<TickerBrief[]>("fetch_tickers", { symbols: names })
                .then((list) => {
                    if (!stopped) {
                        setTickerChanges(Object.fromEntries(list.map((item) => [item.symbol, item.changePercent])));
                    }
                })
                .catch(() => undefined);
        };
        poll();
        const timer = window.setInterval(poll, TICKER_POLL_MS);
        return () => {
            stopped = true;
            window.clearInterval(timer);
        };
    }, [filteredSymbols]);
```

⑤ render 整体替换（从 `return (` 到文件末尾的 `}` 之前）：

```tsx
    return (
        <div className="ycs-home">
            <aside className="ycs-home__sidebar">
                <h1 className="ycs-home__brand">
                    <span className="ycs-home__brand-mark">◆</span>
                    Taskbar Crypto Monitor
                </h1>
                <input
                    className="ycs-home__search"
                    type="text"
                    placeholder="搜索合约，如 BTC / SOL / PEPE"
                    value={query}
                    onChange={(event) => setQuery(event.target.value)}
                />
                {symbolList?.source === "builtin" && (
                    <div className="ycs-home__list-status ycs-home__list-status--warn">网络不可用，显示内置合约列表</div>
                )}
                {symbolList !== null && filteredSymbols.length === 0 && (
                    <div className="ycs-home__list-status">没有匹配的合约</div>
                )}
                <div className="ycs-home__list">
                    {filteredSymbols.map((item) => {
                        const change = tickerChanges[item.symbol];
                        return (
                            <button
                                key={item.symbol}
                                type="button"
                                className={`ycs-home__symbol ${item.symbol === symbol ? "ycs-home__symbol--active" : ""}`}
                                onClick={() => setSymbol(item.symbol)}
                            >
                                <span className="ycs-home__symbol-name">{item.symbol}</span>
                                <span
                                    className={`ycs-home__symbol-change ${
                                        change === undefined ? "" : change >= 0 ? "ycs-home__symbol-change--up" : "ycs-home__symbol-change--down"
                                    }`}
                                >
                                    {change === undefined ? "—" : `${change >= 0 ? "+" : ""}${change.toFixed(1)}%`}
                                </span>
                            </button>
                        );
                    })}
                </div>
            </aside>

            <div className="ycs-home__main">
                <header className={`ycs-marketbar ${changeUp ? "ycs-marketbar--up" : "ycs-marketbar--down"}`}>
                    <span className="ycs-marketbar__symbol">{symbol}</span>
                    <span className="ycs-marketbar__price">{overview ? formatPrice(overview.lastPrice) : "—"}</span>
                    <span className="ycs-marketbar__change">
                        {overview ? `${changeUp ? "+" : ""}${overview.changePercent.toFixed(2)}%` : "—"}
                    </span>
                    <span className="ycs-marketbar__extra">
                        {overview ? `高 ${formatPrice(overview.high)} · 低 ${formatPrice(overview.low)} · 额 ${formatVolume(overview.quoteVolume)} USDT` : "—"}
                    </span>
                    <span className="ycs-marketbar__status">{statusText}</span>
                    <div className="ycs-marketbar__refresh">
                        <span className="ycs-marketbar__time">{overviewTimeText ? `${overviewTimeText} 更新` : ""}</span>
                        <button type="button" className="ycs-marketbar__refresh-btn" title="立即刷新 24h 概览" onClick={refreshOverview}>
                            ⟳
                        </button>
                    </div>
                    <div className="ycs-intervals">
                        {KLINE_INTERVALS.map((item) => (
                            <button
                                key={item}
                                type="button"
                                className={`ycs-intervals__btn ${item === interval ? "ycs-intervals__btn--active" : ""}`}
                                onClick={() => setInterval_(item)}
                            >
                                {item}
                            </button>
                        ))}
                    </div>
                </header>

                <div className="ycs-home__body">
                    <div className="ycs-chart-panel">
                        {klineError !== null ? (
                            <div className="ycs-chart-panel__error">
                                <span>{klineError}</span>
                                <button type="button" onClick={retryKlines}>
                                    重试
                                </button>
                            </div>
                        ) : (
                            <CandleChart klines={klines} interval={interval} lastPrice={lastPrice} />
                        )}
                    </div>
                    <PositionCalculator symbol={symbol} lastPrice={lastPrice} config={config} onConfigChange={setConfig} />
                </div>
            </div>
        </div>
    );
}
```

- [ ] **Step 3: 类型检查**

Run: `npx tsc --noEmit 2>&1 | head -10`
Expected: 零错误

- [ ] **Step 4: Commit**

```bash
git add src/Home.tsx src/types.ts
git commit -m "Refactor Home 布局：行情数据带+双列主体，列表涨跌%轮询"
```

---

### Task 6: home.css 布局段重写

**Files:**
- Modify: `src/styles/home.css`

- [ ] **Step 1: 调整布局骨架段**

找到 `/* ===== 布局骨架：左栏 300px 搜索 + 右区主内容 ===== */` 起的 `.ycs-home`/`.ycs-home__sidebar`/`.ycs-home__main` 规则块，替换为：

```css
/* ===== 布局骨架：左栏 300px 搜索 + 右区（数据带 + 图/仓位双列） ===== */

.ycs-home {
    position: relative;
    display: flex;
    width: 100%;
    height: 100%;
    background: var(--ycs-bg);
    overflow: hidden;
}

.ycs-home__sidebar {
    display: flex;
    flex-direction: column;
    width: 300px;
    flex-shrink: 0;
    background: var(--ycs-side);
    padding: 14px 12px;
    overflow: hidden;
}

.ycs-home__main {
    display: flex;
    flex-direction: column;
    flex: 1;
    min-width: 0;
    padding: 10px 12px 12px;
    gap: 8px;
    overflow: hidden;
}

/* 主区双列：K 线占大头 + 右栏仓位面板固定宽 */
.ycs-home__body {
    display: flex;
    flex: 1;
    min-height: 0;
    gap: 10px;
    overflow: hidden;
}
```

（原 `.ycs-home__main` 里的 `overflow-y: auto` 等滚动相关规则一并移除——新布局零滚动。）

- [ ] **Step 2: 替换概览大区样式**

删除旧 `/* ===== 概览头部 ===== */`（或类似注释）起的 `.ycs-overview*` 全部规则块（含 stats/stat/stat-label/stat-value），替换为：

```css
/* ===== 行情数据带（一行：合约/价格/涨跌/高低额/状态/刷新/周期） ===== */

.ycs-marketbar {
    display: flex;
    align-items: center;
    gap: 12px;
    flex-shrink: 0;
    height: 34px;
    padding: 0 12px;
    background: var(--ycs-surface);
    border: 1px solid var(--ycs-border);
    border-radius: 8px;
    overflow: hidden;
}

.ycs-marketbar__symbol {
    color: var(--ycs-gold);
    font-weight: 700;
    font-size: 13px;
    flex-shrink: 0;
}

.ycs-marketbar__price {
    font-size: 16px;
    font-weight: 700;
    font-variant-numeric: tabular-nums;
    flex-shrink: 0;
}

.ycs-marketbar--up .ycs-marketbar__price,
.ycs-marketbar--up .ycs-marketbar__change {
    color: var(--ycs-up);
}

.ycs-marketbar--down .ycs-marketbar__price,
.ycs-marketbar--down .ycs-marketbar__change {
    color: var(--ycs-down);
}

.ycs-marketbar__change {
    font-size: 12px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
    flex-shrink: 0;
}

.ycs-marketbar__extra {
    color: var(--ycs-muted);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
}

.ycs-marketbar__status {
    color: var(--ycs-muted);
    font-size: 10px;
    flex-shrink: 0;
}

.ycs-marketbar__refresh {
    display: flex;
    align-items: center;
    gap: 6px;
    flex-shrink: 0;
    margin-left: auto;
}

.ycs-marketbar__time {
    color: var(--ycs-dim);
    font-size: 10px;
    font-variant-numeric: tabular-nums;
}

.ycs-marketbar__refresh-btn {
    width: 22px;
    height: 22px;
    border: none;
    border-radius: 6px;
    background: var(--ycs-surface-raised);
    color: var(--ycs-muted);
    font-size: 13px;
    line-height: 1;
    cursor: pointer;
}

.ycs-marketbar__refresh-btn:hover {
    background: var(--ycs-surface-raised);
    color: var(--ycs-ink);
}

.ycs-marketbar .ycs-intervals {
    display: flex;
    gap: 4px;
    flex-shrink: 0;
}
```

保留既有 `.ycs-intervals__btn*` 规则（药丸样式沿用），如原规则在旧 toolbar 块内被删则原样恢复：

```css
.ycs-intervals__btn {
    padding: 3px 10px;
    border: none;
    border-radius: 999px;
    background: transparent;
    color: var(--ycs-muted);
    font-size: 11px;
    cursor: pointer;
}

.ycs-intervals__btn--active {
    background: var(--ycs-gold);
    color: var(--ycs-bg);
    font-weight: 600;
}
```

- [ ] **Step 3: K 线面板与右栏面板样式**

`.ycs-chart-panel` 调整为（删除其中 toolbar 相关规则）：

```css
/* ===== K 线面板（自适应画布） ===== */

.ycs-chart-panel {
    position: relative;
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    background: var(--ycs-surface);
    border: 1px solid var(--ycs-border);
    border-radius: 8px;
    overflow: hidden;
}

.ycs-chart-panel__error {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 10px;
    color: var(--ycs-muted);
    font-size: 12px;
}

.ycs-chart-panel__error button {
    padding: 5px 18px;
    border: none;
    border-radius: 6px;
    background: var(--ycs-gold);
    color: var(--ycs-bg);
    font-weight: 600;
    cursor: pointer;
}
```

新增右栏面板段（追加到文件，同时**删除**旧 `.ycs-calc` 大区规则与 `.ycs-calc__head/__title/__symbol/__form 布局/__actions` 中已废弃的容器规则；`.ycs-calc__field/__label/__input/__direction/__dir-btn*__result*` 子元素规则全部保留复用）：

```css
/* ===== 右栏仓位面板（持仓卡 + 模拟 / 新建表单） ===== */

.ycs-panel {
    display: flex;
    flex-direction: column;
    width: 300px;
    flex-shrink: 0;
    gap: 8px;
    overflow-y: auto;
    overflow-x: hidden;
}

.ycs-poscard {
    background: var(--ycs-surface);
    border: 1px solid var(--ycs-border);
    border-radius: 8px;
    padding: 10px 12px;
}

.ycs-poscard__head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 6px;
}

.ycs-poscard__title {
    margin: 0;
    font-size: 12px;
    font-weight: 600;
    color: var(--ycs-muted);
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.ycs-poscard__dir {
    font-size: 11px;
    font-weight: 700;
}

.ycs-poscard__dir--long {
    color: var(--ycs-up);
}

.ycs-poscard__dir--short {
    color: var(--ycs-down);
}

.ycs-poscard__closed {
    padding: 1px 8px;
    border-radius: 999px;
    border: 1px dashed rgba(245, 202, 85, 0.6);
    color: var(--ycs-gold);
    font-size: 10px;
    font-weight: 600;
}

.ycs-poscard__row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 3px 0;
    font-size: 11px;
}

.ycs-poscard__label {
    color: var(--ycs-muted);
    flex-shrink: 0;
    margin-right: 10px;
}

.ycs-poscard__value {
    font-variant-numeric: tabular-nums;
    text-align: right;
    word-break: break-all;
}

.ycs-poscard__row--up .ycs-poscard__value {
    color: var(--ycs-up);
}

.ycs-poscard__row--down .ycs-poscard__value {
    color: var(--ycs-down);
}

/* 新建仓位表单（复用 .ycs-calc__field 系列） */
.ycs-newpos__form {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 6px;
    padding: 10px 12px;
    background: var(--ycs-surface);
    border: 1px solid var(--ycs-border);
    border-radius: 8px;
}

.ycs-newpos__form .ycs-calc__field:first-child {
    grid-column: 1 / -1;
}

.ycs-newpos__results {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 6px;
}

.ycs-newpos__hint {
    padding: 0 4px;
    color: var(--ycs-muted);
    font-size: 10px;
}

.ycs-newpos__actions {
    display: flex;
    flex-direction: column;
    gap: 6px;
}

.ycs-newpos__save,
.ycs-newpos__remove {
    padding: 7px 0;
    border: none;
    border-radius: 6px;
    font-size: 12px;
    font-weight: 600;
    cursor: pointer;
}

.ycs-newpos__save {
    background: var(--ycs-gold);
    color: var(--ycs-bg);
}

.ycs-newpos__save:disabled {
    opacity: 0.4;
    cursor: not-allowed;
}

.ycs-newpos__remove {
    background: transparent;
    border: 1px solid var(--ycs-border-strong);
    color: var(--ycs-muted);
    font-weight: 400;
}

.ycs-newpos__remove:hover {
    color: var(--ycs-down);
    border-color: rgba(248, 113, 113, 0.4);
}
```

`.ycs-sim` 系列沿用现有规则，追加应用按钮样式：

```css
.ycs-sim__apply {
    padding: 7px 0;
    border: none;
    border-radius: 6px;
    background: var(--ycs-gold);
    color: var(--ycs-bg);
    font-size: 12px;
    font-weight: 700;
    cursor: pointer;
}

.ycs-sim__apply:disabled {
    opacity: 0.4;
    cursor: not-allowed;
}

.ycs-sim__apply--confirm {
    background: var(--ycs-down);
    color: var(--ycs-ink);
}
```

列表涨跌%（追加；`.ycs-home__symbol` 既有规则改为两栏布局时可加 `justify-content: space-between`，若无则在此处理）：

```css
.ycs-home__symbol-change {
    font-size: 10px;
    font-variant-numeric: tabular-nums;
    color: var(--ycs-muted);
    flex-shrink: 0;
}

.ycs-home__symbol-change--up {
    color: var(--ycs-up);
}

.ycs-home__symbol-change--down {
    color: var(--ycs-down);
}
```

- [ ] **Step 4: 全局数字规则同步**

全局 `font-variant-numeric` 选择器清单（`html/body` reset 之后那段）中，把 `.ycs-overview__*` 系列选择器替换为 `.ycs-marketbar__price, .ycs-marketbar__change, .ycs-marketbar__extra, .ycs-marketbar__time, .ycs-poscard__value, .ycs-home__symbol-change`。

- [ ] **Step 5: 构建验证**

Run: `powershell -NoProfile -Command 'Set-Location D:\ipyProject\ai-contract; npm run build 2>&1 | Select-Object -Last 8'`
Expected: tsc 零错误 + vite 构建成功

- [ ] **Step 6: Commit**

```bash
git add src/styles/home.css
git commit -m "Style 首页改版样式：数据带/双列/持仓卡/应用按钮"
```

---

### Task 7: CDP 实机验证（新脚本 + 适配 + 全量回归）

**Files:**
- Create: `scripts/cdp-apply.mjs`
- Modify: `scripts/cdp-sim.mjs`、`scripts/cdp-calc.mjs`、`scripts/cdp-save.mjs`、`scripts/cdp-interact.mjs`

- [ ] **Step 1: 写 cdp-apply.mjs（完整新文件）**

```js
// 应用到仓位端到端验证：新建→保存→模拟减仓→两段式应用→持久化→删除恢复
// 用法：node scripts/cdp-apply.mjs [port]
const port = Number(process.argv[2] ?? 9333);

async function getTargets() {
    const res = await fetch(`http://127.0.0.1:${port}/json/list`);
    return res.json();
}

function connect(wsUrl) {
    return new Promise((resolve, reject) => {
        const ws = new WebSocket(wsUrl);
        ws.onopen = () => resolve(ws);
        ws.onerror = () => reject(new Error(`连接失败: ${wsUrl}`));
    });
}

let nextId = 1;
function call(ws, method, params = {}) {
    return new Promise((resolve, reject) => {
        const id = nextId++;
        const onMsg = (event) => {
            const msg = JSON.parse(String(event.data));
            if (msg.id === id) {
                ws.removeEventListener("message", onMsg);
                if (msg.error) {
                    reject(new Error(`${method}: ${JSON.stringify(msg.error)}`));
                } else {
                    resolve(msg.result);
                }
            }
        };
        ws.addEventListener("message", onMsg);
        ws.send(JSON.stringify({ id, method, params }));
    });
}

async function evalOn(ws, expression) {
    const r = await call(ws, "Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) {
        throw new Error(`evaluate 异常: ${JSON.stringify(r.exceptionDetails.exception?.description ?? r.exceptionDetails).slice(0, 200)}`);
    }
    return r.result.value;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 坐标点击前 scrollIntoView（视口外坐标注入会被 CDP 静默丢弃） */
async function click(ws, selector) {
    await evalOn(ws, `document.querySelector(${JSON.stringify(selector)})?.scrollIntoView({ block: "center" })`);
    await sleep(200);
    const pos = await evalOn(
        ws,
        `(() => { const el = document.querySelector(${JSON.stringify(selector)}); if (!el) return null; const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2, vw: window.innerWidth, vh: window.innerHeight }; })()`
    );
    if (pos === null) {
        throw new Error(`元素不存在: ${selector}`);
    }
    if (pos.x >= 0 && pos.y >= 0 && pos.x < pos.vw && pos.y < pos.vh) {
        await call(ws, "Input.dispatchMouseEvent", { type: "mouseMoved", x: pos.x, y: pos.y, button: "none", pointerType: "mouse" });
        await call(ws, "Input.dispatchMouseEvent", { type: "mousePressed", x: pos.x, y: pos.y, button: "left", clickCount: 1, pointerType: "mouse" });
        await call(ws, "Input.dispatchMouseEvent", { type: "mouseReleased", x: pos.x, y: pos.y, button: "left", clickCount: 1, pointerType: "mouse" });
    } else {
        await evalOn(ws, `document.querySelector(${JSON.stringify(selector)}).click()`);
    }
    await sleep(250);
}

/** 程序化设值触发 React onChange */
async function setInput(ws, selector, value) {
    await evalOn(
        ws,
        `(() => {
            const input = document.querySelector(${JSON.stringify(selector)});
            if (!input) throw new Error("input 不存在: ${selector}");
            const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
            setter.call(input, ${JSON.stringify(value)});
            input.dispatchEvent(new Event("input", { bubbles: true }));
            return true;
        })()`
    );
    await sleep(150);
}

/** 持仓卡 label→value 映射 */
function poscardExpr() {
    return `(() => {
        const out = {};
        for (const el of document.querySelectorAll(".ycs-poscard__row")) {
            const label = el.querySelector(".ycs-poscard__label")?.textContent ?? "";
            const value = el.querySelector(".ycs-poscard__value")?.textContent ?? "";
            out[label] = value;
        }
        return out;
    })()`;
}

let pass = 0;
let fail = 0;
function check(name, ok, detail = "") {
    if (ok) {
        pass++;
        console.log(`PASS ${name} ${detail}`);
    } else {
        fail++;
        console.log(`FAIL ${name} ${detail}`);
    }
}

async function main() {
    const targets = (await getTargets()).filter((t) => t.type === "page");
    let home = null;
    for (const t of targets) {
        const ws = await connect(t.webSocketDebuggerUrl);
        const label = await evalOn(ws, "window.__TAURI_INTERNALS__?.metadata?.currentWindow?.label ?? 'unknown'");
        if (label === "home") {
            home = ws;
        } else {
            ws.close();
        }
    }
    if (!home) {
        throw new Error("未找到 home 窗口");
    }

    // 等待渲染就绪
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
        if ((await evalOn(home, `document.querySelector(".ycs-home__symbol") !== null`))) {
            break;
        }
        await sleep(500);
    }
    await sleep(800);

    // ===== 0. 清场：若已有仓位先删除（幂等） =====
    if ((await evalOn(home, `document.querySelector(".ycs-newpos__remove") !== null`))) {
        await click(home, ".ycs-newpos__remove");
        await sleep(600);
    }

    // ===== 1. 新建仓位：做多 1.0 / 杠杆 10 / 数量 10 → 保存 =====
    await click(home, `.ycs-newpos__form .ycs-calc__direction button:first-child`);
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(2) input`, "1");
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(3) input`, "10");
    await setInput(home, `.ycs-newpos__form .ycs-calc__field:nth-child(4) input`, "10");
    await sleep(300);
    await click(home, ".ycs-newpos__save");
    await sleep(800);
    let card = await evalOn(home, poscardExpr());
    check("新建保存-持仓卡出现", "均价 / 数量" in card, `keys=${Object.keys(card).join(",")}`);
    check("新建保存-仓位值正确", (card["均价 / 数量"] ?? "").startsWith("1.0000000"), `row='${card["均价 / 数量"]}'`);

    // ===== 2. 模拟减仓 10 @ 0.9（全平）→ 两段式应用 =====
    await click(home, `.ycs-sim__form .ycs-calc__direction button:last-child`);
    await setInput(home, `.ycs-sim__form .ycs-calc__field:nth-child(2) input`, "0.9");
    await setInput(home, `.ycs-sim__form .ycs-calc__field:nth-child(3) input`, "10");
    await sleep(400);
    const simText = await evalOn(home, `document.querySelector(".ycs-sim__results")?.textContent ?? ""`);
    check("模拟预览-含本次已实现盈亏", simText.includes("本次已实现盈亏"), `text=${simText.slice(0, 80)}`);

    // 首击：按钮进入确认态
    await click(home, ".ycs-sim__apply");
    await sleep(300);
    const confirmText = await evalOn(home, `document.querySelector(".ycs-sim__apply")?.textContent ?? ""`);
    check("应用首击-按钮变确认态", confirmText.includes("确认应用"), `text='${confirmText}'`);

    // 二击：真正写入
    await click(home, ".ycs-sim__apply");
    await sleep(1000);
    card = await evalOn(home, poscardExpr());
    const closedBadge = await evalOn(home, `document.querySelector(".ycs-poscard__closed")?.textContent ?? ""`);
    check("应用二击-全平徽标", closedBadge.includes("已平仓"), `badge='${closedBadge}'`);
    check("应用二击-累计已实现 -1.00", (card["累计已实现盈亏"] ?? "").startsWith("-1.00"), `row='${card["累计已实现盈亏"]}'`);

    // ===== 3. 模拟卡全平占位 =====
    const simHint = await evalOn(home, `document.querySelector(".ycs-sim__hint")?.textContent ?? ""`);
    check("全平后-模拟卡占位提示", simHint.includes("已平"), `hint='${simHint}'`);

    // ===== 4. 重启验证持久化（config.json 落盘回显） =====
    await click(home, ".ycs-newpos__remove");
    await sleep(600);
    const backToForm = await evalOn(home, `document.querySelector(".ycs-newpos__form") !== null`);
    check("删除仓位-回到新建表单", backToForm === true, `form=${backToForm}`);

    console.log(`RESULT pass=${pass} fail=${fail}`);
    home.close();
    process.exit(fail > 0 ? 1 : 0);
}

main().catch((e) => {
    console.error("FAILED:", e.message);
    process.exit(1);
});
```

- [ ] **Step 2: 适配现有脚本（关键 diff）**

`scripts/cdp-sim.mjs`：
- 基础仓位填写段改为"新建表单保存"流程（选择器 `.ycs-newpos__form ...` + `.ycs-newpos__save`，同 cdp-apply 第 1 步）。
- 删除"减仓模拟-已实现盈亏出现"断言中 `-1` 前缀保留（现基于持久化仓位，模拟结果一致）。
- `.ycs-sim__form .ycs-calc__field:nth-child(1) input`（操作价）改为 `:nth-child(2)`、数量改 `:nth-child(3)`（新表单操作在第一位：操作/操作价/数量）。
- 刷新按钮选择器 `.ycs-overview__refresh-btn` → `.ycs-marketbar__refresh-btn`；`.ycs-overview__time` → `.ycs-marketbar__time`。

`scripts/cdp-calc.mjs`：
- 测试前若 `.ycs-newpos__remove` 存在先点击删除（保证新建表单态）。
- `.ycs-calc__input` NodeList 语义不变（新建表单内前三个 input 依次为 开仓价/杠杆/数量）；保存按钮 `.ycs-calc__save` → `.ycs-newpos__save`；`.ycs-calc__hint` → `.ycs-newpos__hint`；`.ycs-overview__price` → `.ycs-marketbar__price`；`.ycs-calc__result-value` → 新建表单结果格 `.ycs-newpos__results .ycs-calc__result-value`。

`scripts/cdp-save.mjs`：
- 保存/删除按钮选择器 → `.ycs-newpos__save` / `.ycs-newpos__remove`（scrollIntoView 防护已有，保留）。
- 删除后表单重置断言改为 `.ycs-newpos__form 存在`（新建态即复位）。

`scripts/cdp-interact.mjs`：
- `.ycs-overview__symbol` → `.ycs-marketbar__symbol`。
- 追加零滚动断言：

```js
    const noScroll = await evalOn(home, `document.scrollingElement.scrollHeight <= document.scrollingElement.clientHeight`);
    check("首页零滚动", noScroll === true, `scrollHeight=${await evalOn(home, "document.scrollingElement.scrollHeight")} clientHeight=${await evalOn(home, "document.scrollingElement.clientHeight")}`);
```

- [ ] **Step 3: 重启调试实例跑全套**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/launch-debug.ps1 -Port 9333
```

Run: `node scripts/cdp-apply.mjs 9333 && node scripts/cdp-sim.mjs 9333 && node scripts/cdp-calc.mjs 9333 && node scripts/cdp-save.mjs 9333 && node scripts/cdp-interact.mjs 9333`
Expected: 全部 PASS（需代理可用：先 `netstat -ano | grep 7890` 确认 FlClash）

- [ ] **Step 4: Commit**

```bash
git add scripts/cdp-apply.mjs scripts/cdp-sim.mjs scripts/cdp-calc.mjs scripts/cdp-save.mjs scripts/cdp-interact.mjs
git commit -m "Test CDP 脚本适配新布局 + 应用到仓位端到端验证"
```

---

### Task 8: NSIS 打包 + 安装

- [ ] **Step 1: 打包**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-nsis.ps1`
Expected: `Finished 1 bundle at ...setup.exe`，EXIT CODE 0

- [ ] **Step 2: 弹安装向导**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-nsis.ps1`
Expected: 向导弹出，提示用户手动点击完成升级

- [ ] **Step 3: 验证安装落盘**

Run: `ls -la "/c/Users/wu211/AppData/Local/Taskbar Crypto Monitor/taskbar-crypto-monitor.exe"`
Expected: 时间戳为今日（用户点完向导后）

---

### Task 9: 记忆更新 + 汇报

- [ ] **Step 1: 更新记忆**

`C:\Users\wu211\.codeartsdoer\memory\D--ipyProject-ai-contract\project_react_number_input_trap.md` 无需动；在 `MEMORY.md` 的项目主记忆 `taskbar-crypto-monitor.md` 追加本轮事实：布局改版为方案 A（持仓中心双列零滚动）、`Position.realizedPnl` 字段语义、`fetch_tickers` 命令、两段式应用按钮交互。

- [ ] **Step 2: 汇报用户**

汇总：新功能（应用/累计已实现/列表涨跌%/零滚动布局）、验证结果（单测 33 + CDP 全绿）、安装指引。