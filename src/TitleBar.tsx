import { invoke } from "@tauri-apps/api/core";
import "./styles/titlebar.css";

/** 深色自绘标题栏属性 */
export interface TitleBarProps {
    /** 标题文本（显示在拖动区左侧） */
    title: string;
}

/** 深色自绘标题栏（home/settings 共享）：拖动区 + 最小化 + 关闭（关闭 = 隐藏窗口，应用常驻胶囊） */
export default function TitleBar({ title }: TitleBarProps) {
    /** 最小化当前窗口：走 Rust 注入式命令（home 不在 capability 窗口列表，JS window API 无权限） */
    const minimize = () => {
        invoke("minimize_current").catch(() => undefined);
    };

    /** 隐藏当前窗口：home 双击胶囊可再开，settings 右键菜单可再开 */
    const hide = () => {
        invoke("hide_current").catch(() => undefined);
    };

    return (
        <header className="ycs-titlebar">
            <div className="ycs-titlebar__drag" data-tauri-drag-region>
                <span className="ycs-titlebar__title">{title}</span>
            </div>
            <button type="button" className="ycs-titlebar__btn ycs-titlebar__btn--min" title="最小化" onClick={minimize}>
                <svg viewBox="0 0 10 10" width="10" height="10">
                    <rect x="0" y="4.5" width="10" height="1" fill="currentColor" />
                </svg>
            </button>
            <button type="button" className="ycs-titlebar__btn ycs-titlebar__btn--close" title="关闭（隐藏到胶囊）" onClick={hide}>
                <svg viewBox="0 0 10 10" width="10" height="10">
                    <path d="M0.5 0.5 L9.5 9.5 M9.5 0.5 L0.5 9.5" stroke="currentColor" strokeWidth="1.2" fill="none" />
                </svg>
            </button>
        </header>
    );
}