import { useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import CandleChart from "./CandleChart";
import PositionCalculator from "./PositionCalculator";
import TitleBar from "./TitleBar";
import { formatPrice, formatVolume } from "./calc";
import {
    DEFAULT_CONFIG,
    KLINE_INTERVALS,
    type CapsuleConfig,
    type Kline,
    type KlineInterval,
    type KlineStatus,
    type MarketOverview,
    type SymbolList,
    type TickerBrief,
} from "./types";
import "./styles/home.css";

/** 首屏拉取的 K 线根数（与 Rust 侧环形缓冲容量一致） */
const KLINE_FETCH_LIMIT = 500;

/** 概览头部的 REST 轮询间隔（毫秒） */
const OVERVIEW_POLL_MS = 10000;

/** kline-update 事件的合帧间隔（毫秒）：WS 推送频繁，按此节流批量更新 state */
const KLINE_MERGE_INTERVAL_MS = 500;

/** 合约列表展示条数上限（避免长列表渲染卡顿）
 *  须保持 ≤ Rust 侧 fetch_tickers 的 take(100) 上限，超出部分合约涨跌% 将静默缺失 */
const SYMBOL_LIST_MAX = 60;

/** 合约列表涨跌%轮询间隔（毫秒） */
const TICKER_POLL_MS = 10000;

/** 首页主窗口：左栏合约搜索 + 右区 24h 概览 / 六档周期 K 线 / 仓位计算器 */
export default function Home() {
    const [config, setConfig] = useState<CapsuleConfig>(DEFAULT_CONFIG);
    const [symbolList, setSymbolList] = useState<SymbolList | null>(null);
    const [query, setQuery] = useState("");
    /** 当前查看的合约（初始取胶囊主合约，切换仅影响本窗口） */
    const [symbol, setSymbol] = useState(DEFAULT_CONFIG.symbol);
    /** 当前 K 线周期 */
    const [interval, setInterval_] = useState<KlineInterval>("15m");
    /** K 线数据（时间升序，末根为进行中的 K 线） */
    const [klines, setKlines] = useState<Kline[]>([]);
    /** K 线加载失败文案（null = 未失败） */
    const [klineError, setKlineError] = useState<string | null>(null);
    /** K 线流连接状态 */
    const [klineStatus, setKlineStatus] = useState<KlineStatus | null>(null);
    /** 24h 概览数据 */
    const [overview, setOverview] = useState<MarketOverview | null>(null);
    /** 概览最近一次成功刷新的时间戳（毫秒，头部展示） */
    const [overviewTime, setOverviewTime] = useState<number | null>(null);
    /** 手动刷新触发器（自增使概览 effect 立即重拉一次） */
    const [refreshKey, setRefreshKey] = useState(0);
    /** 列表涨跌%快照（合约名 → 24h 涨跌幅；拉取失败沿用上次数据） */
    const [tickerChanges, setTickerChanges] = useState<Record<string, number>>({});
    /** 合帧缓冲：两次 setState 之间的 WS 增量暂存（ref 避免重渲染） */
    const pendingKlinesRef = useRef<Kline[]>([]);
    /** 合帧定时器（卸载/切换时清理） */
    const mergeTimerRef = useRef<number | null>(null);
    /** 当前生效的 symbol 校验标记（丢弃切换后旧流残留推送） */
    const activeSymbolRef = useRef(DEFAULT_CONFIG.symbol);

    // 初始加载配置与合约列表
    useEffect(() => {
        invoke<CapsuleConfig>("get_config")
            .then((cfg) => {
                setConfig(cfg);
                setSymbol(cfg.symbol);
                activeSymbolRef.current = cfg.symbol;
            })
            .catch(() => undefined);
        invoke<SymbolList>("fetch_symbols")
            .then(setSymbolList)
            .catch(() => setSymbolList(null));
    }, []);

    // 全局事件：其它窗口保存配置时同步（positions 回填依赖最新配置）
    useEffect(() => {
        const unlistenConfig = listen<CapsuleConfig>("config-changed", (event) => setConfig(event.payload));
        return () => {
            unlistenConfig.then((fn) => fn()).catch(() => undefined);
        };
    }, []);

    // 合约/周期切换：重拉历史 + 重挂 WS 流 + 重置概览
    useEffect(() => {
        let cancelled = false;
        activeSymbolRef.current = symbol;
        setKlines([]);
        setKlineError(null);
        setOverview(null);
        pendingKlinesRef.current = [];
        // REST 首屏：500 根历史 K 线
        invoke<Kline[]>("fetch_klines", { symbol, interval, limit: KLINE_FETCH_LIMIT })
            .then((list) => {
                if (!cancelled) {
                    setKlines(list);
                }
            })
            .catch((error: unknown) => {
                if (!cancelled) {
                    setKlineError(String(error));
                }
            });
        // WS 增量流订阅（切换即重连）
        invoke("switch_kline_stream", { symbol, interval }).catch(() => undefined);
        return () => {
            cancelled = true;
        };
    }, [symbol, interval]);

    // 概览轮询：固定间隔刷新 24h 头部（K 线 close 实时刷新价格，此处补全高低/成交量）
    // refreshKey 变化（手动点刷新）重建 effect 立即拉取一次
    useEffect(() => {
        let stopped = false;
        const poll = () => {
            invoke<MarketOverview>("fetch_overview", { symbol })
                .then((data) => {
                    if (!stopped) {
                        setOverview(data);
                        setOverviewTime(Date.now());
                    }
                })
                .catch(() => undefined);
        };
        poll();
        const timer = window.setInterval(poll, OVERVIEW_POLL_MS);
        return () => {
            stopped = true;
            window.clearInterval(timer);
        };
    }, [symbol, refreshKey]);

    // K 线 WS 增量：合帧缓冲 + 定时批量合入 state（高频推送防渲染抖动）
    useEffect(() => {
        const unlistenKline = listen<Kline>("kline-update", (event) => {
            // 丢弃切换后旧流的残留推送（旧任务退出前仍会推数条；不同合约同周期 opentime 会重叠）
            if (event.payload.symbol !== activeSymbolRef.current) {
                return;
            }
            pendingKlinesRef.current.push(event.payload);
            // 首条增量立即起表，其后按间隔合帧
            if (mergeTimerRef.current === null) {
                mergeTimerRef.current = window.setTimeout(() => {
                    mergeTimerRef.current = null;
                    const pending = pendingKlinesRef.current;
                    if (pending.length === 0) {
                        return;
                    }
                    pendingKlinesRef.current = [];
                    setKlines((prev) => {
                        const next = [...prev];
                        for (const k of pending) {
                            // opentime 与末根相同：覆盖（进行中 K 线滚动更新）；不同：追加
                            if (next.length > 0 && next[next.length - 1].opentime === k.opentime) {
                                next[next.length - 1] = k;
                            } else if (next.length === 0 || k.opentime > next[next.length - 1].opentime) {
                                next.push(k);
                            }
                        }
                        return next;
                    });
                }, KLINE_MERGE_INTERVAL_MS);
            }
        });
        const unlistenStatus = listen<KlineStatus>("kline-status", (event) => setKlineStatus(event.payload));
        return () => {
            if (mergeTimerRef.current !== null) {
                window.clearTimeout(mergeTimerRef.current);
                mergeTimerRef.current = null;
            }
            unlistenKline.then((fn) => fn()).catch(() => undefined);
            unlistenStatus.then((fn) => fn()).catch(() => undefined);
        };
    }, [symbol]);


    // 搜索过滤：匹配合约全名或基础资产简称（大小写不敏感）
    const filteredSymbols = useMemo(() => {
        if (!symbolList) {
            return [];
        }
        const keyword = query.trim().toLowerCase();
        const matched = symbolList.symbols.filter(
            (item) => item.symbol.toLowerCase().includes(keyword) || item.base.toLowerCase().includes(keyword)
        );
        return matched.slice(0, SYMBOL_LIST_MAX);
    }, [symbolList, query]);

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

    // 最新价优先取 K 线末根收盘价（WS 实时，约 500ms 级），无 K 线时回退概览（10s 轮询）
    const lastPrice = klines[klines.length - 1]?.close ?? overview?.lastPrice ?? null;
    const changeUp = (overview?.changePercent ?? 0) >= 0;

    /** 概览最近刷新时间的短文本（如 14:03:27；无数据时空串） */
    const overviewTimeText = overviewTime === null ? "" : new Date(overviewTime).toLocaleTimeString("zh-CN", { hour12: false });

    /** 手动刷新：立即重拉概览（refreshKey 自增重建轮询 effect） */
    const refreshOverview = () => {
        setRefreshKey((value) => value + 1);
    };

    /** 重试 K 线首屏拉取（错误态按钮） */
    const retryKlines = () => {
        setKlineError(null);
        invoke<Kline[]>("fetch_klines", { symbol, interval, limit: KLINE_FETCH_LIMIT })
            .then(setKlines)
            .catch((error: unknown) => setKlineError(String(error)));
    };

    /** K 线流状态的中文描述 */
    const statusText =
        klineStatus === null
            ? ""
            : { connecting: "连接中…", connected: "", reconnecting: `重连中（${klineStatus.detail}）`, stopped: "已停止" }[klineStatus.state];

    return (
        <div className="ycs-home-wrap">
            {/* 深色自绘标题栏：拖动区 + 最小化/关闭（decorations:false 后无系统边框） */}
            <TitleBar title="Taskbar Crypto Monitor" />
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
                            {overview
                                ? `高 ${formatPrice(overview.high)} · 低 ${formatPrice(overview.low)} · 额 ${formatVolume(overview.quoteVolume)} USDT`
                                : "—"}
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
        </div>
    );
}
