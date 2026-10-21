import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { applyAdjust, computePosition, formatMoney, formatSignedPercent, isPositionValid, simulateAdjust } from "./calc";
import type { CapsuleConfig, Position } from "./types";

/** 仓位计算器属性 */
export interface PositionCalculatorProps {
    /** 当前查看的合约名（如 BTCUSDT） */
    symbol: string;
    /** 最新成交价（USDT，null 表示暂无行情） */
    lastPrice: number | null;
    /** 全量配置（positions 持久化挂载其上） */
    config: CapsuleConfig;
    /** 配置变更回调（保存后刷新父级状态） */
    onConfigChange: (config: CapsuleConfig) => void;
}

/** 表单文本态：保留用户逐键输入的原始字符串（如 "0." / "0.005"）
 *
 * 受控 number 输入若直接绑定 Number 转换值，前导零会被吞
 * （Number("0.00")=0 为 falsy，回写空串清空输入框），
 * 故输入框绑定文本、计算时才解析为数字。
 */
interface CalcFormText {
    /** 开仓价输入文本（USDT，空串表示未填） */
    entryText: string;
    /** 杠杆倍数输入文本（默认 "10"，空串表示未填） */
    levText: string;
    /** 持仓数量输入文本（币本位，空串表示未填） */
    qtyText: string;
}

/** 新仓位的默认表单文本（杠杆预填 10 倍） */
const EMPTY_FORM: CalcFormText = {
    entryText: "",
    levText: "10",
    qtyText: ""
};

/** 解析输入文本为非负数字（解析失败/NaN 时回退 0） */
function parseText(text: string): number {
    const value = Number.parseFloat(text);
    return Number.isFinite(value) ? value : 0;
}

/** 过滤数字输入文本：仅保留数字与小数点（金融输入框标准做法，配合 type=text 使用）
 *
 * 为什么不用 type=number：number 输入框的 value getter 会把 "0." 等中间态
 * 规范化为 "0"，受控回写会吞掉用户刚敲的小数点/前导零（重渲染竞态下必现）。
 *
 * @param text 输入框原始文本
 * @param integerOnly true 时仅保留数字字符（杠杆等整数字段）
 * @returns 过滤后的文本（小数场景仅保留首个小数点）
 */
function sanitizeNumberText(text: string, integerOnly: boolean): string {
    const filtered = integerOnly ? text.replace(/[^\d]/g, "") : text.replace(/[^\d.]/g, "");
    if (integerOnly) {
        return filtered;
    }
    // 小数字段仅保留首个小数点，其后的小数点全部剔除
    const firstDot = filtered.indexOf(".");
    if (firstDot === -1) {
        return filtered;
    }
    return filtered.slice(0, firstDot + 1) + filtered.slice(firstDot + 1).replace(/\./g, "");
}

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
        quantity: parseText(form.qtyText),
        // 新建草稿的累计已实现盈亏恒为 0（尚未发生任何减仓）
        realizedPnl: 0
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