import { describe, expect, it } from "vitest";
import { applyAdjust, computePosition, formatMoney, formatSignedPercent, isPositionValid, simulateAdjust } from "../src/calc";
import type { AdjustInput } from "../src/calc";
import type { Position } from "../src/types";

/** 构造测试用仓位的工厂函数 */
function makePosition(overrides: Partial<Position> = {}): Position {
    return {
        symbol: "BTCUSDT",
        direction: "long",
        entryPrice: 100,
        leverage: 10,
        quantity: 1,
        realizedPnl: 0,
        ...overrides
    };
}

describe("isPositionValid 输入校验", () => {
    it("合法多头仓位通过校验", () => {
        expect(isPositionValid(makePosition())).toBe(true);
    });

    it("合法空头仓位通过校验", () => {
        expect(isPositionValid(makePosition({ direction: "short" }))).toBe(true);
    });

    it("杠杆边界 1 与 125 均合法", () => {
        expect(isPositionValid(makePosition({ leverage: 1 }))).toBe(true);
        expect(isPositionValid(makePosition({ leverage: 125 }))).toBe(true);
    });

    it("杠杆 0 / 126 / 非整数均非法", () => {
        expect(isPositionValid(makePosition({ leverage: 0 }))).toBe(false);
        expect(isPositionValid(makePosition({ leverage: 126 }))).toBe(false);
        expect(isPositionValid(makePosition({ leverage: 10.5 }))).toBe(false);
    });

    it("开仓价与数量非正数或非有限数均非法", () => {
        expect(isPositionValid(makePosition({ entryPrice: 0 }))).toBe(false);
        expect(isPositionValid(makePosition({ entryPrice: -5 }))).toBe(false);
        expect(isPositionValid(makePosition({ entryPrice: Number.NaN }))).toBe(false);
        expect(isPositionValid(makePosition({ quantity: 0 }))).toBe(false);
        expect(isPositionValid(makePosition({ quantity: Number.POSITIVE_INFINITY }))).toBe(false);
    });
});

describe("computePosition 多头计算", () => {
    it("价格不变时盈亏与回报率均为零", () => {
        const result = computePosition(makePosition(), 100);
        expect(result).not.toBeNull();
        expect(result!.pnl).toBe(0);
        expect(result!.roe).toBe(0);
        expect(result!.margin).toBe(10);
    });

    it("价格上涨 10% 时回报率 = 涨幅 × 杠杆 = 100%", () => {
        const result = computePosition(makePosition(), 110);
        expect(result!.pnl).toBe(10);
        expect(result!.roe).toBeCloseTo(100);
    });

    it("价格下跌 5% 时回报率 = -50%", () => {
        const result = computePosition(makePosition(), 95);
        expect(result!.pnl).toBe(-5);
        expect(result!.roe).toBeCloseTo(-50);
    });

    it("多头强平价低于开仓价：entry×(1−1/lev)/(1−MMR)", () => {
        const result = computePosition(makePosition({ leverage: 10 }), 100);
        expect(result!.liquidationPrice).toBeCloseTo((100 * (1 - 0.1)) / (1 - 0.009));
    });

    it("强平距离按最新价计算百分比", () => {
        const liq = (100 * (1 - 0.1)) / (1 - 0.009);
        const result = computePosition(makePosition(), 120);
        expect(result!.liqDistance).toBeCloseTo((Math.abs(liq - 120) / 120) * 100);
    });
});

describe("computePosition 空头计算", () => {
    it("价格下跌 10% 时空头盈利 10（与多头镜像）", () => {
        const result = computePosition(makePosition({ direction: "short" }), 90);
        expect(result!.pnl).toBe(10);
        expect(result!.roe).toBeCloseTo(100);
    });

    it("价格上涨 10% 时空头亏损", () => {
        const result = computePosition(makePosition({ direction: "short" }), 110);
        expect(result!.pnl).toBe(-10);
        expect(result!.roe).toBeCloseTo(-100);
    });

    it("空头强平价高于开仓价：entry×(1+1/lev)/(1+MMR)", () => {
        const result = computePosition(makePosition({ direction: "short", leverage: 10 }), 100);
        expect(result!.liquidationPrice).toBeCloseTo((100 * (1 + 0.1)) / (1 + 0.009));
    });
});

describe("computePosition 边界与防御", () => {
    it("杠杆 1 时多头强平价为 0（无杠杆不强平）", () => {
        const result = computePosition(makePosition({ leverage: 1 }), 100);
        expect(result!.liquidationPrice).toBeCloseTo(0);
    });

    it("杠杆 125 时强平价贴近开仓价（约 0.81% 距离）", () => {
        const result = computePosition(makePosition({ leverage: 125 }), 100);
        expect(result!.liquidationPrice).toBeCloseTo((100 * (1 - 1 / 125)) / (1 - 0.009));
        expect(Math.abs(100 - result!.liquidationPrice)).toBeLessThan(1);
    });

    it("非法仓位输入返回 null", () => {
        expect(computePosition(makePosition({ leverage: 0 }), 100)).toBeNull();
        expect(computePosition(makePosition({ entryPrice: -1 }), 100)).toBeNull();
    });

    it("最新价非正或非有限数返回 null", () => {
        expect(computePosition(makePosition(), 0)).toBeNull();
        expect(computePosition(makePosition(), -10)).toBeNull();
        expect(computePosition(makePosition(), Number.NaN)).toBeNull();
    });
});

describe("格式化函数", () => {
    it("formatMoney 常规金额千分位 2 位小数", () => {
        expect(formatMoney(1234.567)).toBe("1,234.57");
    });

    it("formatMoney 小额保留 4 位精度", () => {
        expect(formatMoney(0.001234)).toBe("0.0012");
    });

    it("formatSignedPercent 正数带加号负数带负号", () => {
        expect(formatSignedPercent(12.345)).toBe("+12.35%");
        expect(formatSignedPercent(-5.2)).toBe("-5.20%");
        expect(formatSignedPercent(0)).toBe("0.00%");
    });
});
/** 构造加减仓模拟输入的工厂函数 */
function makeAdjust(overrides: Partial<AdjustInput> = {}): AdjustInput {
    return {
        direction: "long",
        entryPrice: 100,
        quantity: 1,
        leverage: 10,
        action: "add",
        adjustPrice: 100,
        adjustQuantity: 1,
        ...overrides
    };
}

describe("simulateAdjust 加仓", () => {
    it("用户示例：开仓 1.0 持有 10 个、0.9 加仓 10 个 → 新均价 0.95", () => {
        const result = simulateAdjust(
            makeAdjust({ entryPrice: 1.0, quantity: 10, adjustPrice: 0.9, adjustQuantity: 10 }),
            0.9
        );
        expect(result).not.toBeNull();
        expect(result!.newEntryPrice).toBeCloseTo(0.95);
        expect(result!.newQuantity).toBe(20);
        expect(result!.newMargin).toBeCloseTo(0.95 * 20 / 10);
        expect(result!.newPnl).toBeCloseTo((0.9 - 0.95) * 20);
        expect(result!.newRoe).toBeCloseTo(((0.9 - 0.95) / 0.95) * 10 * 100);
        expect(result!.realizedPnl).toBe(0);
    });

    it("加仓价与原价相同则均价不变", () => {
        const result = simulateAdjust(makeAdjust(), 100);
        expect(result!.newEntryPrice).toBe(100);
        expect(result!.newQuantity).toBe(2);
        expect(result!.newPnl).toBe(0);
    });

    it("空头加仓：均价加权平均、盈亏取空头符号", () => {
        const result = simulateAdjust(
            makeAdjust({ direction: "short", entryPrice: 0.8, quantity: 10, adjustPrice: 0.85, adjustQuantity: 10 }),
            0.85
        );
        expect(result!.newEntryPrice).toBeCloseTo(0.825);
        expect(result!.newPnl).toBeCloseTo((0.85 - 0.825) * 20 * -1);
    });
});

describe("simulateAdjust 减仓", () => {
    it("部分减仓：均价不变、锁定已实现盈亏", () => {
        const result = simulateAdjust(
            makeAdjust({ action: "reduce", entryPrice: 1.0, quantity: 10, adjustPrice: 0.95, adjustQuantity: 4 }),
            0.9
        );
        expect(result!.newEntryPrice).toBe(1.0);
        expect(result!.newQuantity).toBe(6);
        expect(result!.realizedPnl).toBeCloseTo((0.95 - 1.0) * 4);
        expect(result!.newPnl).toBeCloseTo((0.9 - 1.0) * 6);
    });

    it("空头减仓在高价锁定正盈亏", () => {
        const result = simulateAdjust(
            makeAdjust({ direction: "short", action: "reduce", entryPrice: 0.8, quantity: 10, adjustPrice: 0.75, adjustQuantity: 10 }),
            0.75
        );
        expect(result!.realizedPnl).toBeCloseTo((0.75 - 0.8) * 10 * -1);
        expect(result!.realizedPnl).toBeGreaterThan(0);
    });

    it("全平：数量/保证金/浮盈/回报率/强平价归零", () => {
        const result = simulateAdjust(
            makeAdjust({ action: "reduce", entryPrice: 1.0, quantity: 10, adjustPrice: 0.9, adjustQuantity: 10 }),
            0.9
        );
        expect(result!.newQuantity).toBe(0);
        expect(result!.newMargin).toBe(0);
        expect(result!.newPnl).toBe(0);
        expect(result!.newRoe).toBe(0);
        expect(result!.newLiquidationPrice).toBe(0);
        expect(result!.realizedPnl).toBeCloseTo(-1);
    });
});

describe("simulateAdjust 非法输入", () => {
    it("减仓数量超出持仓返回 null", () => {
        expect(simulateAdjust(makeAdjust({ action: "reduce", adjustQuantity: 2 }), 100)).toBeNull();
    });

    it("操作价/操作量非正返回 null", () => {
        expect(simulateAdjust(makeAdjust({ adjustPrice: 0 }), 100)).toBeNull();
        expect(simulateAdjust(makeAdjust({ adjustQuantity: 0 }), 100)).toBeNull();
        expect(simulateAdjust(makeAdjust({ adjustQuantity: Number.NaN }), 100)).toBeNull();
    });

    it("现仓位非法或行情非正返回 null", () => {
        expect(simulateAdjust(makeAdjust({ leverage: 0 }), 100)).toBeNull();
        expect(simulateAdjust(makeAdjust({ entryPrice: 0 }), 100)).toBeNull();
        expect(simulateAdjust(makeAdjust(), 0)).toBeNull();
    });
});
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
        const s2 = simulateAdjust({ direction: "long", entryPrice: 1, quantity: p1.quantity, leverage: 10, action: "reduce", adjustPrice: 1.1, adjustQuantity: 6 }, 1)!;
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
