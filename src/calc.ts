/** 逐仓仓位盈亏计算（纯函数模块，供首页计算器与单测使用）
 *
 * 公式（Binance USDⓈ-M 逐仓简化模型，sign = 多头 +1 / 空头 -1）：
 *   保证金     = entryPrice × quantity / leverage
 *   未实现盈亏 = (lastPrice − entryPrice) × quantity × sign
 *   回报率     = (lastPrice − entryPrice) / entryPrice × leverage × sign
 *   强平价     = entryPrice × (1 − sign/leverage) / (1 − sign × MMR)
 *               （MMR 为维持保证金率；杠杆越高强平价越贴近开仓价）
 *   强平距离   = |liquidationPrice − lastPrice| / lastPrice
 */

import type { Position } from "./types";

/** 仓位计算结果（全部为 USDT 计价的绝对值或百分比） */
export interface PositionResult {
    /** 占用保证金（USDT） */
    margin: number;
    /** 未实现盈亏（USDT，正为盈利负为亏损） */
    pnl: number;
    /** 投资回报率（%，基于保证金，正为盈利负为亏损） */
    roe: number;
    /** 预估强平价（USDT，多头低于开仓价、空头高于开仓价） */
    liquidationPrice: number;
    /** 强平价与最新价的距离（%，越大越安全） */
    liqDistance: number;
}

/** 维持保证金率系数（Binance 多数合约 0.4%~1%，取保守近似 0.9%） */
const MAINTENANCE_MARGIN_RATE = 0.009;

/** 校验仓位输入合法性（杠杆 1~125、开仓价/数量为正数）
 *
 * @param position 仓位输入
 * @returns 输入是否合法（非法时计算器禁用保存并显示占位）
 */
export function isPositionValid(position: Position): boolean {
    return (
        Number.isFinite(position.entryPrice) &&
        position.entryPrice > 0 &&
        Number.isFinite(position.quantity) &&
        position.quantity > 0 &&
        Number.isInteger(position.leverage) &&
        position.leverage >= 1 &&
        position.leverage <= 125
    );
}

/** 加减仓模拟输入（基于现持仓的一次假想操作）
 *
 * 加仓 = 数量加权平均出新均价；减仓 = 均价不变、锁定部分已实现盈亏。
 */
export interface AdjustInput {
    /** 现持仓方向：多头 / 空头 */
    direction: Position["direction"];
    /** 现持仓开仓价（USDT） */
    entryPrice: number;
    /** 现持仓数量（币） */
    quantity: number;
    /** 杠杆倍数（1~125，操作后保持不变） */
    leverage: number;
    /** 操作类型：加仓 / 减仓 */
    action: "add" | "reduce";
    /** 操作价格（USDT，如 0.9 表示在 0.9 价位加减仓） */
    adjustPrice: number;
    /** 操作数量（币，减仓时不得超出持仓数量） */
    adjustQuantity: number;
}

/** 加减仓模拟结果（全部以操作后的持仓状态计算） */
export interface AdjustResult {
    /** 操作后持仓均价（加仓=加权平均；减仓=原开仓价不变） */
    newEntryPrice: number;
    /** 操作后持仓数量（币；全平减仓时为 0） */
    newQuantity: number;
    /** 操作后占用保证金（USDT = 新名义价值 / 杠杆） */
    newMargin: number;
    /** 操作后未实现盈亏（USDT，按 lastPrice 实时计；全平后为 0） */
    newPnl: number;
    /** 操作后回报率（%，基于新保证金；全平后为 0） */
    newRoe: number;
    /** 操作后预估强平价（按新均价重算；全平后为 0） */
    newLiquidationPrice: number;
    /** 本次操作已实现盈亏（USDT，仅减仓锁定；加仓恒为 0） */
    realizedPnl: number;
}

/** 模拟一次指定价格的加仓/减仓操作，返回操作后的持仓指标
 *
 * @param input 模拟输入（现持仓 + 操作参数）
 * @param lastPrice 最新成交价（USDT，用于操作后浮盈计算）
 * @returns 操作后指标；输入非法（现仓位不合法/操作价或量非正/减仓超量）或行情非正时返回 null
 */
export function simulateAdjust(input: AdjustInput, lastPrice: number): AdjustResult | null {
    const base: Position = {
        symbol: "",
        direction: input.direction,
        entryPrice: input.entryPrice,
        leverage: input.leverage,
        quantity: input.quantity
    };
    if (!isPositionValid(base) || !Number.isFinite(lastPrice) || lastPrice <= 0) {
        return null;
    }
    if (!Number.isFinite(input.adjustPrice) || input.adjustPrice <= 0 || !Number.isFinite(input.adjustQuantity) || input.adjustQuantity <= 0) {
        return null;
    }
    // 减仓数量不得超出当前持仓（允许全平）
    if (input.action === "reduce" && input.adjustQuantity > input.quantity) {
        return null;
    }
    const sign = input.direction === "long" ? 1 : -1;
    let newEntryPrice: number;
    let newQuantity: number;
    let realizedPnl: number;
    if (input.action === "add") {
        // 加仓：名义价值加权平均出新均价
        newEntryPrice = (input.entryPrice * input.quantity + input.adjustPrice * input.adjustQuantity) / (input.quantity + input.adjustQuantity);
        newQuantity = input.quantity + input.adjustQuantity;
        realizedPnl = 0;
    } else {
        // 减仓：均价不变，按操作价锁定部分已实现盈亏
        newEntryPrice = input.entryPrice;
        newQuantity = input.quantity - input.adjustQuantity;
        realizedPnl = (input.adjustPrice - input.entryPrice) * input.adjustQuantity * sign;
    }
    // 全平后持仓清零：保证金/浮盈/回报率/强平价归零
    if (newQuantity === 0) {
        return { newEntryPrice, newQuantity, newMargin: 0, newPnl: 0, newRoe: 0, newLiquidationPrice: 0, realizedPnl };
    }
    const newMargin = (newEntryPrice * newQuantity) / input.leverage;
    const newPnl = (lastPrice - newEntryPrice) * newQuantity * sign;
    const newRoe = ((lastPrice - newEntryPrice) / newEntryPrice) * input.leverage * sign * 100;
    const newLiquidationPrice = (newEntryPrice * (1 - sign / input.leverage)) / (1 - sign * MAINTENANCE_MARGIN_RATE);
    return { newEntryPrice, newQuantity, newMargin, newPnl, newRoe, newLiquidationPrice, realizedPnl };
}

/** 计算逐仓仓位的实时盈亏指标
 *
 * @param position 仓位输入（方向/开仓价/杠杆/数量）
 * @param lastPrice 最新成交价（USDT）
 * @returns 计算结果；输入非法或最新价非正时返回 null
 */
export function computePosition(position: Position, lastPrice: number): PositionResult | null {
    if (!isPositionValid(position) || !Number.isFinite(lastPrice) || lastPrice <= 0) {
        return null;
    }
    // 方向符号：多头 +1，空头 -1
    const sign = position.direction === "long" ? 1 : -1;
    const { entryPrice, quantity, leverage } = position;
    // 保证金：名义价值 / 杠杆
    const margin = (entryPrice * quantity) / leverage;
    // 未实现盈亏：价差 × 数量 × 方向
    const pnl = (lastPrice - entryPrice) * quantity * sign;
    // 回报率：价差百分比放大杠杆倍（等价于盈亏/保证金）
    const roe = ((lastPrice - entryPrice) / entryPrice) * leverage * sign * 100;
    // 强平价：权益恰好覆盖维持保证金的临界价（多头向下、空头向上；杠杆越高越贴近开仓价）
    const liquidationPrice =
        (entryPrice * (1 - sign / leverage)) / (1 - sign * MAINTENANCE_MARGIN_RATE);
    const liqDistance = (Math.abs(liquidationPrice - lastPrice) / lastPrice) * 100;
    return { margin, pnl, roe, liquidationPrice, liqDistance };
}

/** 格式化 USDT 金额：千分位 + 2 位小数（大额）；小于 0.01 时保留 4 位精度
 *
 * @param value 金额（USDT）
 * @returns 千分位格式化字符串
 */
export function formatMoney(value: number): string {
    const abs = Math.abs(value);
    const digits = abs >= 0.01 ? 2 : 4;
    return value.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

/** 格式化百分比：保留 2 位小数并带正负号
 *
 * @param value 百分比数值
 * @returns 如 "+12.34%" / "-5.20%"
 */
export function formatSignedPercent(value: number): string {
    const sign = value > 0 ? "+" : "";
    return `${sign}${value.toFixed(2)}%`;
}

/** 格式化价格：千分位 + 6 位小数（小价格合约需要足够精度，与胶囊一致）
 *
 * @param price 价格（USDT）
 * @returns 千分位格式化字符串
 */
export function formatPrice(price: number): string {
    return price.toLocaleString("en-US", { minimumFractionDigits: 6, maximumFractionDigits: 6 });
}


/** 格式化大数值成交量：自动缩放为 K / M / B 单位
 *
 * @param volume 原始数量
 * @returns 如 "12.34M"
 */
export function formatVolume(volume: number): string {
    const abs = Math.abs(volume);
    if (abs >= 1e9) {
        return `${(volume / 1e9).toFixed(2)}B`;
    }
    if (abs >= 1e6) {
        return `${(volume / 1e6).toFixed(2)}M`;
    }
    if (abs >= 1e3) {
        return `${(volume / 1e3).toFixed(2)}K`;
    }
    return volume.toFixed(2);
}
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