/** 胶囊显示配置（与 Rust 端 CapsuleConfig 对应，序列化为 camelCase） */
export interface CapsuleConfig {
    /** 主显示合约名称（Binance USDⓈ-M 永续，如 BTCUSDT） */
    symbol: string;
    /** 是否显示合约名称徽标（如 BTCUSDT） */
    showSymbol: boolean;
    /** 是否显示最新成交价（USDT 计价） */
    showPrice: boolean;
    /** 是否显示 24 小时涨跌幅 */
    showChange: boolean;
    /** 是否显示迷你趋势曲线（Sparkline） */
    showSparkline: boolean;
    /** 整体缩放系数，有效范围 0.8 ~ 1.4，默认 1.0 */
    scale: number;
}

/** 默认配置：BTCUSDT 主合约 + 四个字段全部显示，标准缩放 */
export const DEFAULT_CONFIG: CapsuleConfig = {
    symbol: "BTCUSDT",
    showSymbol: true,
    showPrice: true,
    showChange: true,
    showSparkline: true,
    scale: 1.0
};

/** 合约精简信息（搜索选择用） */
export interface SymbolInfo {
    /** 合约全名（如 BTCUSDT） */
    symbol: string;
    /** 基础资产简称（如 BTC），用于辅助搜索 */
    base: string;
}

/** 合约列表查询结果 */
export interface SymbolList {
    /** 可选的 USDT 本位永续合约集合 */
    symbols: SymbolInfo[];
    /** 数据来源："online"（Binance 实时）或 "builtin"（内置回退） */
    source: "online" | "builtin";
}
/** 实时行情快照（Rust 端 ticker-update 事件载荷） */
export interface TickerData {
    /** 合约名（如 BTCUSDT） */
    symbol: string;
    /** 最新成交价（USDT 计价） */
    price: number;
    /** 24 小时涨跌幅（%，正值代表上涨） */
    changePercent: number;
    /** 24 小时涨跌额（USDT） */
    changeAmount: number;
}
