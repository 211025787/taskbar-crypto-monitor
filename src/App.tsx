import { useEffect, useMemo, useRef, useState, type CSSProperties, type MouseEvent } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { DEFAULT_CONFIG, type CapsuleConfig, type TickerData, type WsStatus } from "./types";
import "./styles/capsule.css";

/** 趋势数据点（当前由实时价格流构建，后续阶段接入 Binance Kline 历史数据拼接） */
interface TrendPoint {
    /** 时间戳（毫秒） */
    t: number;
    /** 价格（USDT） */
    p: number;
}

/** Sparkline 折线图的 viewBox 尺寸（逻辑坐标，实际显示尺寸由 CSS 按缩放系数控制） */
const SPARK_VB_WIDTH = 76;
const SPARK_VB_HEIGHT = 22;

/** 实时趋势缓冲区容量上限（环形裁剪，防止内存无限增长） */
const TREND_MAX_POINTS = 90;

/** 将趋势点序列映射为 SVG polyline 的坐标字符串 */
function buildPolylinePoints(trend: TrendPoint[]): string {
    const prices = trend.map((point) => point.p);
    const min = Math.min(...prices);
    const max = Math.max(...prices);
    const range = max - min || 1;
    return trend
        .map((point, index) => {
            const x = (index / (trend.length - 1)) * SPARK_VB_WIDTH;
            const y = SPARK_VB_HEIGHT - ((point.p - min) / range) * (SPARK_VB_HEIGHT - 2) - 1;
            return `${x.toFixed(1)},${y.toFixed(1)}`;
        })
        .join(" ");
}

/** 根据 SVG 折线坐标推导出首尾闭合的填充区域路径（用于渐变面积） */
function buildAreaPath(polyline: string): string {
    const head = polyline.split(" ")[0].split(",")[0];
    const tail = polyline.split(" ").pop()?.split(",")[0] ?? String(SPARK_VB_WIDTH);
    return `M${head},${SPARK_VB_HEIGHT} L${polyline.replace(/ /g, " L")} L${tail},${SPARK_VB_HEIGHT} Z`;
}

/** 格式化价格：千分位 + 6 位小数（小价格合约如 0.000012 需足够精度） */
function formatPrice(price: number): string {
    return price.toLocaleString("en-US", { minimumFractionDigits: 6, maximumFractionDigits: 6 });
}

/** 全透明胶囊行情 UI：直接浮于任务栏之上，右键弹出原生菜单，实时数据由 Binance WebSocket 驱动 */
export default function App() {
    const [config, setConfig] = useState<CapsuleConfig>(DEFAULT_CONFIG);
    /** 最新行情快照（null 表示尚未收到首条推送） */
    const [ticker, setTicker] = useState<TickerData | null>(null);
    /** WebSocket 连接状态（驱动胶囊上的状态指示点） */
    const [wsStatus, setWsStatus] = useState<WsStatus>({ state: "connecting", detail: "" });
    /** 实时价格趋势缓冲（有界，收到推送即追加） */
    const [trend, setTrend] = useState<TrendPoint[]>([]);
    /** 切换合约时清空趋势缓冲的标记（在事件回调内区分新旧合约数据） */
    const trendSymbolRef = useRef("");

    useEffect(() => {
        // 初始加载已保存配置（无存档时 Rust 侧返回默认值），并登记初始合约名
        invoke<CapsuleConfig>("get_config")
            .then((cfg) => {
                setConfig(cfg);
                trendSymbolRef.current = cfg.symbol;
            })
            .catch(() => undefined);
        // 监听设置窗口广播的配置变更事件，胶囊即时刷新
        const unlistenConfig = listen<CapsuleConfig>("config-changed", (event) => {
            setConfig(event.payload);
            // 合约已切换：重置趋势缓冲与旧行情显示，等待新合约首条推送
            if (event.payload.symbol !== trendSymbolRef.current) {
                trendSymbolRef.current = event.payload.symbol;
                setTrend([]);
                setTicker(null);
            }
        });
        // 订阅 Rust 端行情推送（Binance 24hrTicker，约 1 秒 1 条）
        const unlistenTicker = listen<TickerData>("ticker-update", (event) => {
            // 丢弃过期合约的残留推送：切换合约后旧任务退出前仍会推数条旧数据，
            // 若混入新趋势缓冲会造成价格量级突变、趋势图被拉成断裂的两条线
            if (event.payload.symbol !== trendSymbolRef.current) {
                return;
            }
            setTicker(event.payload);
            setTrend((prev) => {
                const next = [...prev, { t: Date.now(), p: event.payload.price }];
                // 超出容量时丢弃最旧数据点，保持缓冲区有界
                return next.length > TREND_MAX_POINTS ? next.slice(next.length - TREND_MAX_POINTS) : next;
            });
        });
        // 订阅连接状态推送（connecting/connected/reconnecting）
        const unlistenStatus = listen<WsStatus>("ws-status", (event) => setWsStatus(event.payload));
        // 组件卸载时取消事件订阅
        return () => {
            unlistenConfig.then((fn) => fn()).catch(() => undefined);
            unlistenTicker.then((fn) => fn()).catch(() => undefined);
            unlistenStatus.then((fn) => fn()).catch(() => undefined);
        };
    }, []);

    /** 右键胶囊：阻止默认上下文菜单，弹出原生菜单（设置 / 退出） */
    const handleContextMenu = (event: MouseEvent) => {
        event.preventDefault();
        invoke("show_capsule_menu").catch(() => undefined);
    };

    // 将缩放系数注入 CSS 变量，供字号/间距/图形尺寸的 calc 表达式使用
    const capsuleStyle = { "--ycs-scale": String(config.scale) } as CSSProperties;

    const polyline = useMemo(() => (trend.length >= 2 ? buildPolylinePoints(trend) : ""), [trend]);
    const areaPath = useMemo(() => (polyline ? buildAreaPath(polyline) : ""), [polyline]);
    const isUp = (ticker?.changePercent ?? 0) >= 0;

    return (
        <div
            className={`ycs-capsule ${isUp ? "ycs-capsule--up" : "ycs-capsule--down"}`}
            style={capsuleStyle}
            onContextMenu={handleContextMenu}
            data-tauri-drag-region
        >
            {config.showSymbol && (
                <span className="ycs-symbol" data-tauri-drag-region>
                    {config.symbol}
                </span>
            )}
            {config.showPrice && (
                <span className="ycs-price" data-tauri-drag-region>
                    {ticker ? formatPrice(ticker.price) : "—"}
                </span>
            )}
            {config.showChange && (
                <span className={`ycs-change ${isUp ? "ycs-change--up" : "ycs-change--down"}`} data-tauri-drag-region>
                    {ticker ? `${isUp ? "+" : ""}${ticker.changePercent.toFixed(2)}%` : "—"}
                </span>
            )}
            {config.showSparkline && (
                <svg
                    className="ycs-sparkline"
                    viewBox={`0 0 ${SPARK_VB_WIDTH} ${SPARK_VB_HEIGHT}`}
                    preserveAspectRatio="none"
                    data-tauri-drag-region
                >
                    <defs>
                        <linearGradient id="ycs-spark-area" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="0%" stopColor={isUp ? "#34d399" : "#f87171"} stopOpacity="0.35" />
                            <stop offset="100%" stopColor={isUp ? "#34d399" : "#f87171"} stopOpacity="0" />
                        </linearGradient>
                    </defs>
                    {areaPath && <path className="ycs-sparkline__area" d={areaPath} />}
                    {polyline && <polyline className="ycs-sparkline__line" points={polyline} />}
                </svg>
            )}
            {/* 连接状态指示点：已连接隐藏；连接中灰、重连中红、轮询模式黄 */}
            {wsStatus.state !== "connected" && (
                <span
                    className={`ycs-ws-dot ${wsStatus.state === "reconnecting" ? "ycs-ws-dot--error" : wsStatus.state === "polling" ? "ycs-ws-dot--poll" : "ycs-ws-dot--wait"}`}
                    title={wsStatus.state === "reconnecting" ? `连接断开，${wsStatus.detail}` : wsStatus.state === "polling" ? wsStatus.detail : "连接行情服务器中…"}
                />
            )}
        </div>
    );
}