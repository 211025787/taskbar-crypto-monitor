import { useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { DEFAULT_CONFIG, type CapsuleConfig, type SymbolList } from "./types";
import "./styles/settings.css";

/** 单个显示字段开关行的属性 */
interface FieldRowProps {
    /** 开关左侧的主标签文本 */
    label: string;
    /** 主标签下方的补充说明文本 */
    description: string;
    /** 当前开关状态 */
    checked: boolean;
    /** 开关状态变化回调 */
    onChange: (value: boolean) => void;
}

/** 显示字段开关行：左侧文字说明 + 右侧复选框 */
function FieldRow({ label, description, checked, onChange }: FieldRowProps) {
    return (
        <label className="ycs-setting-row">
            <div className="ycs-setting-row__text">
                <span className="ycs-setting-row__label">{label}</span>
                <span className="ycs-setting-row__desc">{description}</span>
            </div>
            <input
                className="ycs-setting-row__checkbox"
                type="checkbox"
                checked={checked}
                onChange={(event) => onChange(event.target.checked)}
            />
        </label>
    );
}

/** 单个合约列表行的属性 */
interface SymbolRowProps {
    /** 合约全名（如 BTCUSDT） */
    symbol: string;
    /** 基础资产简称（如 BTC） */
    base: string;
    /** 是否为当前选中合约 */
    active: boolean;
    /** 点击选中回调 */
    onSelect: () => void;
}

/** 合约列表行：合约名 + 基础资产徽标 + 当前选中标记 */
function SymbolRow({ symbol, base, active, onSelect }: SymbolRowProps) {
    return (
        <button type="button" className={`ycs-symbol-row ${active ? "ycs-symbol-row--active" : ""}`} onClick={onSelect}>
            <span className="ycs-symbol-row__name">{symbol}</span>
            <span className="ycs-symbol-row__base">{base}</span>
            {active && <span className="ycs-symbol-row__check">✓</span>}
        </button>
    );
}

/** 设置窗口：合约搜索选择 + 胶囊显示字段与整体缩放配置，修改即时生效并自动保存 */
export default function Settings() {
    const [config, setConfig] = useState<CapsuleConfig>(DEFAULT_CONFIG);
    const [saved, setSaved] = useState(false);
    const [symbolList, setSymbolList] = useState<SymbolList | null>(null);
    const [query, setQuery] = useState("");

    useEffect(() => {
        // 初始加载已保存配置
        invoke<CapsuleConfig>("get_config")
            .then(setConfig)
            .catch(() => undefined);
        // 拉取可选合约列表（Rust 端优先 Binance 在线列表，失败回退内置）
        invoke<SymbolList>("fetch_symbols")
            .then(setSymbolList)
            .catch(() => setSymbolList(null));
        // 多窗口同步：其它入口保存配置时刷新本地状态
        const unlistenConfig = listen<CapsuleConfig>("config-changed", (event) => setConfig(event.payload));
        // 组件卸载时取消订阅（关闭窗口由 Rust 端拦截为隐藏）
        return () => {
            unlistenConfig.then((fn) => fn()).catch(() => undefined);
        };
    }, []);

    /** 更新并即时保存配置（Rust 侧会同步调整胶囊窗口尺寸并广播事件） */
    const update = (patch: Partial<CapsuleConfig>) => {
        const next = { ...config, ...patch };
        setConfig(next);
        invoke("save_config", { config: next })
            .then(() => {
                // 显示 1.2 秒"已保存"反馈后自动消失
                setSaved(true);
                window.setTimeout(() => setSaved(false), 1200);
            })
            .catch(() => undefined);
    };

    // 搜索过滤：匹配合约全名或基础资产简称（大小写不敏感），最多展示 60 条避免长列表卡顿
    const filteredSymbols = useMemo(() => {
        if (!symbolList) {
            return [];
        }
        const keyword = query.trim().toLowerCase();
        const matched = symbolList.symbols.filter(
            (item) => item.symbol.toLowerCase().includes(keyword) || item.base.toLowerCase().includes(keyword)
        );
        return matched.slice(0, 60);
    }, [symbolList, query]);

    const percent = Math.round(config.scale * 100);

    return (
        <div className="ycs-settings">
            <h1 className="ycs-settings__title">胶囊显示设置</h1>
            <p className="ycs-settings__hint">在任务栏胶囊上点击右键可打开菜单；修改即时生效并自动保存。</p>

            <button
                type="button"
                className="ycs-open-home"
                onClick={() => invoke("open_home").catch(() => undefined)}
            >
                打开首页（合约详情 / K 线 / 仓位计算器）
            </button>

            <section className="ycs-settings__section">
                <h2 className="ycs-settings__section-title">合约选择</h2>
                <div className="ycs-symbol-current">
                    当前合约：<span className="ycs-symbol-current__name">{config.symbol}</span>
                </div>
                <input
                    className="ycs-symbol-search"
                    type="text"
                    placeholder="搜索合约，如 BTC / SOL / PEPE"
                    value={query}
                    onChange={(event) => setQuery(event.target.value)}
                />
                {symbolList === null && <div className="ycs-symbol-status">正在加载合约列表…</div>}
                {symbolList?.source === "builtin" && (
                    <div className="ycs-symbol-status ycs-symbol-status--warn">网络不可用，当前显示内置合约列表</div>
                )}
                {symbolList !== null && filteredSymbols.length === 0 && (
                    <div className="ycs-symbol-status">没有匹配的合约</div>
                )}
                {filteredSymbols.length > 0 && (
                    <div className="ycs-symbol-list">
                        {filteredSymbols.map((item) => (
                            <SymbolRow
                                key={item.symbol}
                                symbol={item.symbol}
                                base={item.base}
                                active={item.symbol === config.symbol}
                                onSelect={() => update({ symbol: item.symbol })}
                            />
                        ))}
                    </div>
                )}
            </section>

            <section className="ycs-settings__section">
                <h2 className="ycs-settings__section-title">显示字段</h2>
                <FieldRow
                    label="合约名称"
                    description="如 BTCUSDT 标识"
                    checked={config.showSymbol}
                    onChange={(value) => update({ showSymbol: value })}
                />
                <FieldRow
                    label="最新价格"
                    description="最新成交价（USDT）"
                    checked={config.showPrice}
                    onChange={(value) => update({ showPrice: value })}
                />
                <FieldRow
                    label="24 小时涨跌幅"
                    description="百分比涨跌，绿涨红跌"
                    checked={config.showChange}
                    onChange={(value) => update({ showChange: value })}
                />
                <FieldRow
                    label="趋势曲线"
                    description="迷你 Sparkline 折线图"
                    checked={config.showSparkline}
                    onChange={(value) => update({ showSparkline: value })}
                />
            </section>

            <section className="ycs-settings__section">
                <h2 className="ycs-settings__section-title">整体大小</h2>
                <div className="ycs-setting-row">
                    <div className="ycs-setting-row__text">
                        <span className="ycs-setting-row__label">缩放比例</span>
                        <span className="ycs-setting-row__desc">{percent}%（范围 80% ~ 140%）</span>
                    </div>
                    <input
                        className="ycs-setting-row__slider"
                        type="range"
                        min={0.8}
                        max={1.4}
                        step={0.05}
                        value={config.scale}
                        onChange={(event) => update({ scale: Number(event.target.value) })}
                    />
                </div>
            </section>

            <footer className="ycs-settings__footer">
                <span className={`ycs-settings__saved ${saved ? "ycs-settings__saved--visible" : ""}`}>已保存</span>
                <span className="ycs-settings__note">行情数据来自 Binance 实时推送；断线后自动重连</span>
            </footer>
        </div>
    );
}