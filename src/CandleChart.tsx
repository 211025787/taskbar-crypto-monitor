import { useCallback, useEffect, useRef, useState, type MouseEvent as ReactMouseEvent, type WheelEvent as ReactWheelEvent } from "react";
import type { Kline, KlineInterval } from "./types";

/** 蜡烛图组件属性 */
export interface CandleChartProps {
    /** 全量 K 线数据（时间升序，末尾为进行中的 K 线） */
    klines: Kline[];
    /** 当前周期（影响时间轴标签格式） */
    interval: KlineInterval;
    /** 最新成交价（用于最新价虚线；null 时退化为末根收盘价） */
    lastPrice: number | null;
}

/** 涨跌语义色（与胶囊配色一致：涨绿跌红） */
const COLOR_UP = "#34d399";
const COLOR_DOWN = "#f87171";
/** 网格与坐标轴文字色（低不透明度弱化视觉噪音） */
const COLOR_GRID = "rgba(148, 163, 184, 0.10)";
const COLOR_AXIS = "rgba(148, 163, 184, 0.55)";
/** 十字光标线色 */
const COLOR_CROSS = "rgba(245, 202, 85, 0.55)";
/** 最新价标签文字色 */
const COLOR_LABEL = "#0f172a";
/** 可见 K 线根数范围 */
const MIN_VISIBLE = 30;
const MAX_VISIBLE = 300;
/** 主图占整体高度的比例（其余为成交量副图与间距） */
const MAIN_RATIO = 0.78;
/** 价格轴上下留白比例（避免蜡烛贴边） */
const PRICE_PADDING = 0.06;

/** 将毫秒时间戳格式化为时间轴标签（按周期选择粒度） */
function formatTimeLabel(timestamp: number, interval: KlineInterval): string {
    const date = new Date(timestamp);
    const pad = (value: number) => String(value).padStart(2, "0");
    const hhmm = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
    const md = `${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
    // 日线粒度只显示日期；分钟线显示时分；小时线日期+时
    if (interval === "1d") {
        return md;
    }
    if (interval === "4h" || interval === "1h") {
        return `${md} ${pad(date.getHours())}时`;
    }
    return hhmm;
}

/** 价格轴标签格式化：大数缩位、小数保留精度 */
function formatAxisPrice(price: number): string {
    const abs = Math.abs(price);
    if (abs >= 1e6) {
        return `${(price / 1e6).toFixed(2)}M`;
    }
    if (abs >= 100) {
        return price.toFixed(2);
    }
    if (abs >= 1) {
        return price.toFixed(4);
    }
    return price.toFixed(6);
}

/** 自绘 Canvas 蜡烛图：主图 K 线 + 副图成交量，支持滚轮缩放 / 拖拽平移 / 十字光标 */
export default function CandleChart({ klines, interval, lastPrice }: CandleChartProps) {
    /** 画布容器（尺寸自适应的观察目标） */
    const containerRef = useRef<HTMLDivElement | null>(null);
    /** 画布元素（DPR 适配后按 CSS 像素绘制） */
    const canvasRef = useRef<HTMLCanvasElement | null>(null);
    /** 容器 CSS 尺寸（ResizeObserver 维护） */
    const [size, setSize] = useState({ width: 0, height: 0 });
    /** 可见 K 线根数（缩放状态） */
    const visibleCountRef = useRef(120);
    /** 右端偏移根数（0 = 对齐最新；> 0 = 向左平移回看历史） */
    const rightOffsetRef = useRef(0);
    /** 拖拽状态：起点 X 与起始偏移（指针捕获期间生效） */
    const dragRef = useRef<{ startX: number; startOffset: number } | null>(null);
    /** 十字光标位置（CSS 像素；null = 未悬停） */
    const [crosshair, setCrosshair] = useState<{ x: number; y: number } | null>(null);
    /** 悬停命中的 K 线索引（驱动顶部 OHLC 信息条）；-1 = 未命中 */
    const [hoverIndex, setHoverIndex] = useState(-1);
    /** 缩放/平移版本号：递增触发重绘（与数据变化解耦） */
    const [viewVersion, setViewVersion] = useState(0);

    // 容器尺寸自适应：ResizeObserver 监听布局变化
    useEffect(() => {
        const element = containerRef.current;
        if (!element) {
            return;
        }
        const observer = new ResizeObserver((entries) => {
            const rect = entries[0].contentRect;
            setSize({ width: rect.width, height: rect.height });
        });
        observer.observe(element);
        return () => observer.disconnect();
    }, []);

    /** 全量重绘：网格 / 蜡烛 / 成交量 / 最新价线 / 十字光标 */
    const draw = useCallback(() => {
        const canvas = canvasRef.current;
        if (!canvas || size.width <= 0 || size.height <= 0 || klines.length === 0) {
            return;
        }
        // DPR 适配：物理像素 = CSS 像素 × devicePixelRatio，防止高分屏模糊
        const dpr = window.devicePixelRatio || 1;
        if (canvas.width !== Math.round(size.width * dpr) || canvas.height !== Math.round(size.height * dpr)) {
            canvas.width = Math.round(size.width * dpr);
            canvas.height = Math.round(size.height * dpr);
        }
        const ctx = canvas.getContext("2d");
        if (!ctx) {
            return;
        }
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, size.width, size.height);

        const total = klines.length;
        const visible = Math.min(visibleCountRef.current, total);
        const maxOffset = Math.max(0, total - visible);
        const rightOffset = Math.min(rightOffsetRef.current, maxOffset);
        // 可见窗口切片（rightOffset=0 时右端对齐最新一根）；命名避免遮蔽全局 window
        const end = total - rightOffset;
        const start = end - visible;
        const visibleWindow = klines.slice(start, end);
        if (visibleWindow.length === 0) {
            return;
        }

        // 主图/副图分区：底部预留时间轴标签高度
        const axisH = 20;
        const plotW = size.width - 64;
        const plotH = size.height - axisH;
        const mainH = plotH * MAIN_RATIO;
        const volTop = mainH + 8;
        const volH = plotH - volTop;

        // 价格区间：可见窗口内最低低点~最高高点，上下加留白
        let priceMin = Number.POSITIVE_INFINITY;
        let priceMax = Number.NEGATIVE_INFINITY;
        let volumeMax = 0;
        for (const k of visibleWindow) {
            priceMin = Math.min(priceMin, k.low);
            priceMax = Math.max(priceMax, k.high);
            volumeMax = Math.max(volumeMax, k.volume);
        }
        const pricePad = (priceMax - priceMin) * PRICE_PADDING || priceMax * 0.01;
        priceMin -= pricePad;
        priceMax += pricePad;
        const priceRange = priceMax - priceMin;
        // Y 坐标映射：主图内价格线性映射
        const yOf = (price: number) => ((priceMax - price) / priceRange) * mainH;

        // 水平网格 + 右侧价格标签（5 档均分）
        ctx.font = "11px 'Segoe UI', sans-serif";
        ctx.textBaseline = "middle";
        for (let i = 0; i <= 4; i++) {
            const y = (mainH / 4) * i;
            ctx.strokeStyle = COLOR_GRID;
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(0, y + 0.5);
            ctx.lineTo(plotW, y + 0.5);
            ctx.stroke();
            const price = priceMax - (priceRange / 4) * i;
            ctx.fillStyle = COLOR_AXIS;
            ctx.textAlign = "left";
            ctx.fillText(formatAxisPrice(price), plotW + 8, y);
        }

        // 蜡烛绘制：每根占一个等宽槽位，蜡烛体占槽位 70%
        const slot = plotW / visibleWindow.length;
        const bodyW = Math.max(1, slot * 0.7);
        for (let i = 0; i < visibleWindow.length; i++) {
            const k = visibleWindow[i];
            const x = slot * i + slot / 2;
            const up = k.close >= k.open;
            const color = up ? COLOR_UP : COLOR_DOWN;
            // 影线：最高价到最低价的细线
            ctx.strokeStyle = color;
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(x, yOf(k.high));
            ctx.lineTo(x, yOf(k.low));
            ctx.stroke();
            // 蜡烛体：开盘价到收盘价的矩形（倒挂时高度至少 1px 保持可见）
            const yOpen = yOf(k.open);
            const yClose = yOf(k.close);
            const top = Math.min(yOpen, yClose);
            const height = Math.max(1, Math.abs(yClose - yOpen));
            ctx.fillStyle = color;
            ctx.fillRect(x - bodyW / 2, top, bodyW, height);
            // 成交量副图：按最大可见成交量归一化的底部柱
            if (volumeMax > 0 && volH > 0) {
                const barH = (k.volume / volumeMax) * volH;
                ctx.fillStyle = up ? "rgba(52, 211, 153, 0.45)" : "rgba(248, 113, 113, 0.45)";
                ctx.fillRect(x - bodyW / 2, volTop + volH - barH, bodyW, barH);
            }
        }

        // 时间轴标签：约每 1/6 可见宽度取一根 K 线的时间
        const labelStep = Math.max(1, Math.floor(visibleWindow.length / 6));
        ctx.fillStyle = COLOR_AXIS;
        ctx.textAlign = "center";
        ctx.textBaseline = "alphabetic";
        for (let i = 0; i < visibleWindow.length; i += labelStep) {
            const x = slot * i + slot / 2;
            ctx.fillText(formatTimeLabel(visibleWindow[i].opentime, interval), x, size.height - 6);
        }

        // 最新价虚线 + 右侧价签（色随最新价相对前收的涨跌）
        const livePrice = lastPrice ?? visibleWindow[visibleWindow.length - 1].close;
        const liveY = yOf(livePrice);
        if (liveY >= 0 && liveY <= mainH) {
            const up = livePrice >= visibleWindow[visibleWindow.length - 1].open;
            ctx.strokeStyle = up ? COLOR_UP : COLOR_DOWN;
            ctx.lineWidth = 1;
            ctx.setLineDash([4, 4]);
            ctx.beginPath();
            ctx.moveTo(0, liveY + 0.5);
            ctx.lineTo(plotW, liveY + 0.5);
            ctx.stroke();
            ctx.setLineDash([]);
            // 右侧实心价签：超出网格区绘制在价格轴上
            const label = formatAxisPrice(livePrice);
            const tagW = ctx.measureText(label).width + 10;
            ctx.fillStyle = up ? COLOR_UP : COLOR_DOWN;
            ctx.fillRect(plotW + 4, liveY - 9, tagW, 18);
            ctx.fillStyle = COLOR_LABEL;
            ctx.textAlign = "left";
            ctx.textBaseline = "middle";
            ctx.fillText(label, plotW + 9, liveY);
        }

        // 十字光标：悬停位置画横竖虚线，不绘制文字（OHLC 由顶部 DOM 信息条展示）
        if (crosshair && crosshair.x < plotW) {
            ctx.strokeStyle = COLOR_CROSS;
            ctx.lineWidth = 1;
            ctx.setLineDash([3, 3]);
            ctx.beginPath();
            ctx.moveTo(crosshair.x + 0.5, 0);
            ctx.lineTo(crosshair.x + 0.5, plotH);
            ctx.moveTo(0, crosshair.y + 0.5);
            ctx.lineTo(plotW, crosshair.y + 0.5);
            ctx.stroke();
            ctx.setLineDash([]);
        }
    }, [klines, interval, lastPrice, size, crosshair]);

    // 任何绘制输入变化即重绘（数据 / 尺寸 / 视窗 / 光标）
    useEffect(() => {
        draw();
    }, [draw, viewVersion]);

    /** 滚轮缩放：以鼠标所在槽位为锚点调整可见根数（30~300），锚点 K 线尽量保持在鼠标下方 */
    const handleWheel = (event: ReactWheelEvent<HTMLCanvasElement>) => {
        event.preventDefault();
        const canvas = canvasRef.current;
        if (!canvas || klines.length === 0 || size.width <= 0) {
            return;
        }
        const rect = canvas.getBoundingClientRect();
        const mouseX = event.clientX - rect.left;
        const plotW = size.width - 64;
        const total = klines.length;
        const oldVisible = Math.min(visibleCountRef.current, total);
        const oldOffset = Math.min(rightOffsetRef.current, Math.max(0, total - oldVisible));
        // 鼠标相对可见窗口的位置比例（0=最旧端，1=最新端）
        const ratio = Math.min(1, Math.max(0, mouseX / plotW));
        // 新可见根数：向上滚放大（根数减少），向下滚缩小（根数增加）
        const direction = event.deltaY < 0 ? -1 : 1;
        const nextVisible = Math.min(MAX_VISIBLE, Math.max(MIN_VISIBLE, Math.round(oldVisible * (1 + direction * 0.15))));
        // 保持鼠标指向的 K 线不动：按比例换算新右端偏移
        const endOld = total - oldOffset;
        const anchorIndex = endOld - Math.round((1 - ratio) * oldVisible);
        const nextOffset = Math.min(Math.max(0, total - nextVisible), Math.max(0, total - (anchorIndex + Math.round(ratio * nextVisible))));
        visibleCountRef.current = nextVisible;
        rightOffsetRef.current = nextOffset;
        setViewVersion((version) => version + 1);
    };

    /** 拖拽开始：记录起点与起始偏移 */
    const handleMouseDown = (event: ReactMouseEvent<HTMLCanvasElement>) => {
        dragRef.current = { startX: event.clientX, startOffset: rightOffsetRef.current };
    };

    /** 拖拽平移：按每根槽位宽度换算平移根数（右拖看更新，左拖看更旧） */
    const handleMouseMove = (event: ReactMouseEvent<HTMLCanvasElement>) => {
        const canvas = canvasRef.current;
        if (!canvas || size.width <= 0) {
            return;
        }
        const rect = canvas.getBoundingClientRect();
        const x = event.clientX - rect.left;
        const y = event.clientY - rect.top;
        setCrosshair({ x, y });
        // 命中检测：换算鼠标所在 K 线的全量索引（驱动 OHLC 信息条）
        if (klines.length > 0) {
            const plotW = size.width - 64;
            const visible = Math.min(visibleCountRef.current, klines.length);
            const slot = plotW / visible;
            const indexInWindow = Math.floor(x / slot);
            const total = klines.length;
            const maxOffset = Math.max(0, total - visible);
            const offset = Math.min(rightOffsetRef.current, maxOffset);
            const globalIndex = total - offset - visible + indexInWindow;
            setHoverIndex(globalIndex >= 0 && globalIndex < total ? globalIndex : -1);
        }
        // 拖拽中：累积位移换算为偏移根数
        if (dragRef.current) {
            const dx = event.clientX - dragRef.current.startX;
            const plotW = size.width - 64;
            const visible = Math.min(visibleCountRef.current, klines.length);
            const slot = plotW / visible;
            const moved = Math.round(dx / slot);
            const total = klines.length;
            const maxOffset = Math.max(0, total - visible);
            rightOffsetRef.current = Math.min(maxOffset, Math.max(0, dragRef.current.startOffset + moved));
            setViewVersion((version) => version + 1);
        }
    };

    /** 拖拽/悬停结束：清空状态 */
    const handleMouseUp = () => {
        dragRef.current = null;
    };
    const handleMouseLeave = () => {
        dragRef.current = null;
        setCrosshair(null);
        setHoverIndex(-1);
    };

    // 悬停 K 线的 OHLC 信息（无悬停时取最新一根）
    const info = hoverIndex >= 0 && hoverIndex < klines.length ? klines[hoverIndex] : klines[klines.length - 1];
    const infoUp = info ? info.close >= info.open : true;

    return (
        <div className="ycs-chart">
            {info && (
                <div className={`ycs-chart__ohlc ${infoUp ? "ycs-chart__ohlc--up" : "ycs-chart__ohlc--down"}`}>
                    <span>开 {info.open}</span>
                    <span>高 {info.high}</span>
                    <span>低 {info.low}</span>
                    <span>收 {info.close}</span>
                    <span>量 {info.volume.toFixed(2)}</span>
                </div>
            )}
            <div ref={containerRef} className="ycs-chart__canvas-wrap">
                <canvas
                    ref={canvasRef}
                    className="ycs-chart__canvas"
                    style={{ width: size.width, height: size.height }}
                    onWheel={handleWheel}
                    onMouseDown={handleMouseDown}
                    onMouseMove={handleMouseMove}
                    onMouseUp={handleMouseUp}
                    onMouseLeave={handleMouseLeave}
                />
                {klines.length === 0 && <div className="ycs-chart__empty">暂无 K 线数据</div>}
            </div>
        </div>
    );
}