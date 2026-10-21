# 标题栏深色化 + 胶囊盈亏显示 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 去除首页/设置窗口白色系统标题栏换深色自绘（关闭=隐藏）、滚动条主题色化、胶囊显示实时浮盈（可设置开关）。

**Architecture:** 共享 `TitleBar.tsx` 组件（home/settings 挂载，capsule 不引用）；窗口操作走 Rust 注入式命令（home 不在 capability 窗口列表，JS window API 有权限风险，自定义命令无此限制）；胶囊盈亏复用 `computePosition` 纯函数 + `CapsuleConfig.showPnl` 配置全链路（TS 类型/Rust serde/宽度计算/设置开关）。

**Tech Stack:** Tauri 2 + Rust + React 19 + TypeScript + Vite；实机验证走 WebView2 CDP（端口 9333）。

**设计 spec:** `docs/superpowers/specs/2026-10-21-titlebar-pnl-design.md`

---

## 关键事实（实现者必读）

1. **home 窗口默认 1100×700 可调**（tauri.conf.json）——spec 中"362 高需布局适配"不成立（那是 CDP 会话中用户手动调小的状态），去掉标题栏 34px 后仍充裕，**无需布局压缩**。
2. **vite 多入口 CSS 合并成一份**（三窗口共用）：titlebar.css 用**硬编码色值**而非 `--ycs-*` 变量（变量定义在 home.css 的 `:root`，依赖打包顺序脆弱）；背景类样式严禁写在全局选择器上（透明胶囊泄漏坑）。
3. **自定义 `#[tauri::command]` 对所有窗口可用**（不受 capability 窗口列表限制）；但 `data-tauri-drag-region` 走 `core:window:allow-start-dragging` 权限——**home 不在 capabilities/default.json 的 windows 数组里，必须补上**（settings/capsule 已在）。
4. 关闭=隐藏的恢复路径已存在：home 双击胶囊 `open_home`；settings 右键菜单 `capsule-settings`。
5. code-spec：4 空格缩进、行宽 160、UTF-8 无 BOM、全覆盖文档注释、删未用导入、末尾换行。
6. 构建验证命令见各任务；实机 CDP/打包由控制者执行（Task 5）。

---

### Task 1: Rust 配置与窗口命令

**Files:**
- Modify: `src-tauri/src/config.rs`（CapsuleConfig + Default）
- Modify: `src-tauri/src/lib.rs`（compute_capsule_size + 两个命令 + 注册）

- [ ] **Step 1: config.rs 增加 show_pnl 字段**

`CapsuleConfig` 结构体在 `show_sparkline` 字段后追加：

```rust
    /// 是否在胶囊显示当前持仓浮盈（USDT，实时未实现盈亏），旧配置缺省为 true
    #[serde(default = "default_show_pnl")]
    pub show_pnl: bool,
```

在 `impl Default for CapsuleConfig` 之前追加自由函数：

```rust
/// show_pnl 的 serde 缺省值：旧配置无此字段时默认开启
fn default_show_pnl() -> bool {
    true
}
```

`Default` 实现的 `show_sparkline: true,` 后追加 `show_pnl: true,`。

- [ ] **Step 2: lib.rs 窗口命令**

`src-tauri/src/lib.rs` 在 `fetch_symbols` 命令附近（命令定义区）追加：

```rust
/// 最小化调用方窗口（自绘标题栏按钮调用，window 参数由 Tauri 注入调用方引用）
#[tauri::command]
fn minimize_current(window: tauri::WebviewWindow) {
    let _ = window.minimize();
}

/// 隐藏调用方窗口（自绘标题栏"关闭"=隐藏：应用常驻胶囊继续监控，
/// home 双击胶囊 open_home 可再开，settings 右键菜单可再开）
#[tauri::command]
fn hide_current(window: tauri::WebviewWindow) {
    let _ = window.hide();
}
```

invoke_handler 注册列表（`fetch_tickers` 之后）追加两行：

```rust
            fetch_tickers,
            minimize_current,
            hide_current
```

- [ ] **Step 3: lib.rs 胶囊宽度计算**

`compute_capsule_size` 函数中 `if cfg.show_sparkline { ... }` 块之后追加：

```rust
    if cfg.show_pnl {
        // 盈亏字段如 "+123.45u"（约 8 字符），常开预留宽度（无仓位时字段不渲染仅留白）
        content += 66.0;
        fields += 1;
    }
```

- [ ] **Step 4: cargo check 验证**

Run: `powershell -NoProfile -Command '$env:RUSTUP_HOME="D:\develop\rust\rustup"; $env:CARGO_HOME="D:\develop\rust\cargo"; $env:PATH="D:\develop\msys2\mingw64\bin;D:\develop\rust\cargo\bin;C:\Windows\System32;C:\Windows"; Set-Location D:\ipyProject\ai-contract\src-tauri; cargo check 2>&1 | Select-Object -Last 5'`
Expected: 无 error

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/config.rs src-tauri/src/lib.rs
git commit -m "Feat CapsuleConfig.showPnl 与最小化/隐藏窗口命令"
```

---

### Task 2: TitleBar 组件 + 窗口配置

**Files:**
- Create: `src/TitleBar.tsx`
- Create: `src/styles/titlebar.css`
- Modify: `src/types.ts`（CapsuleConfig + DEFAULT_CONFIG）
- Modify: `src-tauri/tauri.conf.json`（decorations）
- Modify: `src-tauri/capabilities/default.json`（windows 加 home）

- [ ] **Step 1: types.ts**

`CapsuleConfig` 接口 `showSparkline` 后追加：

```ts
    /** 是否在胶囊显示当前持仓浮盈（USDT，实时未实现盈亏；默认 true） */
    showPnl: boolean;
```

`DEFAULT_CONFIG` 对象 `showSparkline: true,` 后追加 `showPnl: true,`。

- [ ] **Step 2: 新建 src/TitleBar.tsx**

```tsx
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
```

- [ ] **Step 3: 新建 src/styles/titlebar.css**

```css
/* ===== 深色自绘标题栏（home/settings 共享，capsule 入口不引用） ===== */

/* 色值用硬编码而非 --ycs-* 变量：变量定义在 home.css :root，settings 入口依赖合并包顺序脆弱 */
.ycs-titlebar {
    display: flex;
    align-items: stretch;
    height: 34px;
    flex-shrink: 0;
    background: #0f1626;
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
    user-select: none;
}

.ycs-titlebar__drag {
    flex: 1;
    display: flex;
    align-items: center;
    padding: 0 12px;
    min-width: 0;
}

.ycs-titlebar__title {
    color: #8a93a8;
    font-size: 12px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

.ycs-titlebar__btn {
    width: 44px;
    border: none;
    background: transparent;
    color: #8a93a8;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
}

.ycs-titlebar__btn:hover {
    background: #1a2643;
    color: #e8ecf5;
}

.ycs-titlebar__btn--close:hover {
    background: rgba(248, 113, 113, 0.18);
    color: #f87171;
}
```

- [ ] **Step 4: tauri.conf.json 与 capabilities**

settings 窗口对象 `"resizable": false,` 行后加 `"decorations": false,`；home 窗口对象 `"resizable": true,` 行后加 `"decorations": false,`。

`src-tauri/capabilities/default.json` 的 `"windows": ["capsule", "settings"]` 改为：

```json
    "windows": ["capsule", "settings", "home"],
```

（home 需要 `core:default` 里的 `core:window:allow-start-dragging` 供 data-tauri-drag-region 拖动。）

- [ ] **Step 5: 类型检查**

Run: `npx tsc --noEmit 2>&1 | head -5`
Expected: 零错误

- [ ] **Step 6: Commit**

```bash
git add src/TitleBar.tsx src/styles/titlebar.css src/types.ts src-tauri/tauri.conf.json src-tauri/capabilities/default.json
git commit -m "Feat 深色自绘标题栏组件与窗口装饰配置"
```

---

### Task 3: Home/Settings 挂载标题栏 + 滚动条主题色

**Files:**
- Modify: `src/Home.tsx`（render 包 wrap）
- Modify: `src/Settings.tsx`（容器首位插 TitleBar）
- Modify: `src/styles/home.css`（wrap 布局 + 滚动条）
- Modify: `src/styles/settings.css`（滚动条）

- [ ] **Step 1: Home.tsx**

头部 import 增加：

```tsx
import TitleBar from "./TitleBar";
```

render 最外层包一层（`return (` 之后）：

```tsx
    return (
        <div className="ycs-home-wrap">
            <TitleBar title="Taskbar Crypto Monitor" />
            <div className="ycs-home">
                {/* …原有 sidebar/main 全部内容不动… */}
            </div>
        </div>
    );
```

（原 `return (<div className="ycs-home">…` 的闭合 `</div>` 前注意配对缩进调整；内部内容一律不动。）

- [ ] **Step 2: home.css 布局适配**

`.ycs-home` 规则前追加 wrap 规则，并调整 `.ycs-home` 高度行为：

```css
/* 标题栏 + 主体 的纵向外壳 */
.ycs-home-wrap {
    display: flex;
    flex-direction: column;
    width: 100%;
    height: 100%;
    background: var(--ycs-bg);
    overflow: hidden;
}
```

`.ycs-home` 规则中 `height: 100%;` 改为 `flex: 1;` 并追加 `min-height: 0;`（背景可保留）。

文件末尾追加滚动条（作用域限定防多窗口泄漏）：

```css
/* ===== 深色滚动条（Chromium 私有前缀，作用域限定在首页防泄漏胶囊窗口） ===== */
.ycs-home ::-webkit-scrollbar {
    width: 6px;
    height: 6px;
}

.ycs-home ::-webkit-scrollbar-thumb {
    background: var(--ycs-dim);
    border-radius: 3px;
}

.ycs-home ::-webkit-scrollbar-thumb:hover {
    background: var(--ycs-muted);
}

.ycs-home ::-webkit-scrollbar-track {
    background: transparent;
}
```

- [ ] **Step 3: Settings.tsx**

先读 `src/Settings.tsx` 的 render 段（约 81-211 行）找到根容器 `div.ycs-settings`，在其**第一个子元素位置**插入：

```tsx
            <TitleBar title="设置 - Taskbar Crypto Monitor" />
```

头部 import 增加 `import TitleBar from "./TitleBar";`。

`src/styles/settings.css` 末尾追加同款滚动条（作用域换 `.ycs-settings`）：

```css
/* ===== 深色滚动条（作用域限定防多窗口泄漏） ===== */
.ycs-settings ::-webkit-scrollbar {
    width: 6px;
    height: 6px;
}

.ycs-settings ::-webkit-scrollbar-thumb {
    background: #3d475e;
    border-radius: 3px;
}

.ycs-settings ::-webkit-scrollbar-thumb:hover {
    background: #8a93a8;
}

.ycs-settings ::-webkit-scrollbar-track {
    background: transparent;
}
```

（settings.css 无 `--ycs-*` 变量，用等值硬编码。）同时确认 `.ycs-settings` 容器为纵向布局且内容区可滚动——若 TitleBar 插入后被挤压，给容器加 `flex-shrink: 0` 已由 titlebar 自身处理，无需额外改动。

- [ ] **Step 4: 构建验证**

Run: `powershell -NoProfile -Command 'Set-Location D:\ipyProject\ai-contract; npm run build 2>&1 | Select-Object -Last 6'`
Expected: tsc 零错误 + vite 构建成功

- [ ] **Step 5: Commit**

```bash
git add src/Home.tsx src/Settings.tsx src/styles/home.css src/styles/settings.css
git commit -m "Feat 首页/设置挂载深色标题栏与主题色滚动条"
```

---

### Task 4: 胶囊盈亏显示

**Files:**
- Modify: `src/App.tsx`（浮盈计算 + 渲染）
- Modify: `src/styles/capsule.css`（.ycs-pnl 样式）
- Modify: `src/Settings.tsx`（显示盈亏开关行）

- [ ] **Step 1: App.tsx**

头部 import 修改：

```tsx
import { computePosition } from "./calc";
import { DEFAULT_CONFIG, type CapsuleConfig, type Position, type TickerData } from "./types";
```

（`calc.ts` 为纯函数模块，capsule 入口引用无副作用风险。）

组件内 `const isUp = ...` 行后追加派生态：

```tsx
    /** 胶囊主合约的有效持仓（数量>0 才显示盈亏；全平/无仓位不渲染该字段） */
    const position: Position | null = config.positions.find((item) => item.symbol === config.symbol && item.quantity > 0) ?? null;
    /** 实时浮盈（USDT，与首页持仓卡"浮盈"同口径；null = 无仓位或暂无行情） */
    const pnl = position !== null && ticker !== null ? computePosition(position, ticker.price).pnl : null;
```

render 中 `showChange` 条件块之后、`showSparkline` 之前插入：

```tsx
                    {config.showPnl && pnl !== null && (
                        <span className={`ycs-pnl ${pnl >= 0 ? "ycs-pnl--up" : "ycs-pnl--down"}`}>
                            {pnl >= 0 ? "+" : ""}
                            {pnl.toFixed(2)}u
                        </span>
                    )}
```

- [ ] **Step 2: capsule.css**

文件中 `.ycs-change` 规则之后追加（色值与胶囊涨跌语义色一致，等宽数字防跳动）：

```css
.ycs-pnl {
    font-size: 12px;
    font-weight: 600;
    font-variant-numeric: tabular-nums;
}

.ycs-pnl--up {
    color: #34d399;
}

.ycs-pnl--down {
    color: #f87171;
}
```

（先读 `.ycs-change` 现有规则对齐字号/字重，若其为 11px 则同步 11px。）

- [ ] **Step 3: Settings.tsx 开关行**

读 render 段"显示字段"区（`showSparkline` 的 FieldRow 之后）追加：

```tsx
                    <FieldRow
                        label="显示盈亏"
                        description="任务栏胶囊实时显示当前持仓浮盈（USDT）"
                        checked={config.showPnl}
                        onChange={(value) => update({ showPnl: value })}
                    />
```

（`update` 为现有部分更新函数，读文件确认签名后照用。）

- [ ] **Step 4: 验证**

Run: `npx tsc --noEmit 2>&1 | head -5 && npm test -- --run 2>&1 | tail -3`
Expected: 零错误 + 33 测试全绿

- [ ] **Step 5: Commit**

```bash
git add src/App.tsx src/styles/capsule.css src/Settings.tsx
git commit -m "Feat 胶囊显示实时浮盈与设置开关"
```

---

### Task 5: CDP 实机验证 + 打包安装（控制者执行）

- [ ] **Step 1: 新建 `scripts/cdp-titlebar.mjs`**（控制者写）验证：home 有 `.ycs-titlebar`；点最小化 → selftest isiconic；重新还原；点关闭 → selftest isvis False + 胶囊仍响应；settings 同验；胶囊 `.ycs-pnl` 文本/颜色与 computePosition 推算一致；Settings 关 showPnl → 字段消失。
- [ ] **Step 2: 全量回归**：cdp-apply/cdp-sim/cdp-calc/cdp-save/cdp-interact 全绿。
- [ ] **Step 3: NSIS 打包 + 弹安装向导 + 落盘确认。**

---

### Task 6: 记忆更新 + 汇报（控制者执行）

- [ ] 更新 `taskbar-crypto-monitor.md`（TitleBar 组件/showPnl/关闭=隐藏语义）；汇报用户。

## 自审记录

- spec 覆盖：标题栏（Task 2/3）、按钮主题色（titlebar.css）、滚动条（Task 3）、胶囊盈亏+开关（Task 1/4）、关闭=隐藏（Task 1/2 命令）——全覆盖。
- 类型一致性：`showPnl`（TS）↔ `show_pnl`（Rust）camelCase 对齐；`minimize_current`/`hide_current` 命令名在 TitleBar.tsx 与 lib.rs 注册一致。
- 布局适配修正：home 默认 1100×700，无需压缩（spec 原担忧不成立）。