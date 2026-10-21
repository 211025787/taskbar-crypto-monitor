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
    /** 各合约的仓位配置集合（首页计算器），每合约至多一条 */
    positions: Position[];
}

/** 单合约仓位配置（与 Rust 端 PositionConfig 对应） */
export interface Position {
    /** 合约名（如 BTCUSDT） */
    symbol: string;
    /** 方向："long"（做多）或 "short"（做空） */
    direction: "long" | "short";
    /** 开仓均价（USDT 计价，正数） */
    entryPrice: number;
    /** 杠杆倍数，有效范围 1 ~ 125 */
    leverage: number;
    /** 持仓数量（以币计，正数；全平后为 0，仓位保留供复盘） */
    quantity: number;
    /** 累计已实现盈亏（USDT，历次减仓锁定盈亏之和；新建为 0，加仓不变，全平后保留） */
    realizedPnl: number;
}

/** 默认配置：BTCUSDT 主合约 + 四个字段全部显示，标准缩放，无仓位 */
export const DEFAULT_CONFIG: CapsuleConfig = {
    symbol: "BTCUSDT",
    showSymbol: true,
    showPrice: true,
    showChange: true,
    showSparkline: true,
    scale: 1.0,
    positions: []
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
/** 单根 K 线（Rust 端 kline-update 事件载荷 / fetch_klines 命令返回元素） */
export interface Kline {
    /** 归属合约名（大写，如 BTCUSDT）：用于丢弃切换后旧流残留推送 */
    symbol: string;
    /** 开盘时间（毫秒时间戳，作为 K 线唯一标识） */
    opentime: number;
    /** 收盘时间（毫秒时间戳） */
    closetime: number;
    /** 开盘价（USDT 计价） */
    open: number;
    /** 最高价（USDT 计价） */
    high: number;
    /** 最低价（USDT 计价） */
    low: number;
    /** 收盘价（USDT 计价，未收盘 K 线为最新价） */
    close: number;
    /** 成交量（以币计） */
    volume: number;
    /** K 线是否已收盘（false 表示正在进行中的 K 线） */
    closed: boolean;
}

/** K 线流连接状态（Rust 端 kline-status 事件载荷） */
export interface KlineStatus {
    /** 状态：connecting / connected / reconnecting / stopped */
    state: "connecting" | "connected" | "reconnecting" | "stopped";
    /** 状态补充说明（如重连等待秒数） */
    detail: string;
}

/** 24h 行情概览（fetch_overview 命令返回） */
export interface MarketOverview {
    /** 合约名（如 BTCUSDT） */
    symbol: string;
    /** 最新成交价（USDT 计价） */
    lastPrice: number;
    /** 24 小时涨跌幅（%，正值代表上涨） */
    changePercent: number;
    /** 24 小时涨跌额（USDT） */
    changeAmount: number;
    /** 24 小时最高价（USDT） */
    high: number;
    /** 24 小时最低价（USDT） */
    low: number;
    /** 24 小时成交量（以币计） */
    volume: number;
    /** 24 小时成交额（USDT 计价） */
    quoteVolume: number;
}

/** 仓位计算器支持的 K 线周期档位 */
export const KLINE_INTERVALS = ["1m", "5m", "15m", "1h", "4h", "1d"] as const;

/** K 线周期类型（字面量联合） */
export type KlineInterval = (typeof KLINE_INTERVALS)[number];
