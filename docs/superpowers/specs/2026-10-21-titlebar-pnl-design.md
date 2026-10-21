# 标题栏深色化 + 胶囊盈亏显示 设计

日期：2026-10-21
状态：已与用户对齐（浮盈口径 / 关闭=隐藏 / settings 同步改）

## 一、需求

1. **去除首页/设置窗口的系统标题栏**（白色栏），换成深色主题自绘标题栏（品牌区 + 关闭/最小化按钮）。
2. **窗口控制按钮与主题色一致**：最小化/关闭自绘按钮走深色 token，hover 反馈（关闭 hover 红）。
3. **滚动条与主题色一致**：滚动条深色化（右栏 `.ycs-panel`、侧栏列表等），作用域限定防多窗口泄漏。
4. **胶囊显示当前盈亏（u）**：实时浮盈（未实现盈亏，与持仓卡"浮盈"口径一致），设置里可开关隐藏。

## 二、设计

### 1. 自绘标题栏（home + settings 共享组件）

- `tauri.conf.json`：home 与 settings 窗口加 `"decorations": false`（capsule 已是）。
- 新建 `src/TitleBar.tsx` 共享组件（自带 `src/styles/titlebar.css`，由组件 import，随 home/settings 两个入口打包；capsule 不引用不带）：
  - 布局：`[品牌/标题区（data-tauri-drag-region，flex:1）] [最小化按钮] [关闭按钮]`——按钮放在 drag 区之外，避免拖动与点击冲突。
  - 最小化/关闭调用 Rust 命令（见下）。
- **Rust 新增两个命令**（`src-tauri/src/lib.rs`，注入调用方窗口引用，home/settings 通用）：

```rust
#[tauri::command]
fn minimize_current(window: tauri::WebviewWindow) { let _ = window.minimize(); }

#[tauri::command]
fn hide_current(window: tauri::WebviewWindow) { let _ = window.hide(); }
```

  走 Rust 命令而非 JS window API 的原因：capabilities/default.json 的 `windows` 数组只列了 `["capsule", "settings"]`（home 不在内），JS 侧 `getCurrentWindow().minimize()/hide()` 需要窗口级权限，而 invoke 自定义命令在 home 已被大量验证可用。
- **关闭语义 = 隐藏窗口**（应用常驻胶囊继续监控，双击胶囊可再开首页；与右键"退出"分离防误退）。settings 同样隐藏。
- 样式（titlebar.css，token 与 home.css 一致）：高 34px、背景 `--ycs-side`、底边 1px 发丝线；按钮 40×34 无边框，图标用 CSS/SVG 绘制（"—"与"✕"字符即可）；hover 背景 `--ycs-surface-raised`，关闭 hover `--ycs-down` 15% 透明底 + 红色 ✕。
- settings.css 若 reset 无背景需确认 `.ycs-settings` 容器已有深色底（现状保持，标题栏只贴容器内顶部）。

### 2. 滚动条主题色

- `home.css` 追加作用域规则（`.ycs-home` 内，Chromium 前缀）：

```css
.ycs-home ::-webkit-scrollbar { width: 6px; height: 6px; }
.ycs-home ::-webkit-scrollbar-thumb { background: var(--ycs-dim); border-radius: 3px; }
.ycs-home ::-webkit-scrollbar-thumb:hover { background: var(--ycs-muted); }
.ycs-home ::-webkit-scrollbar-track { background: transparent; }
```

- `settings.css` 同款（作用域 `.ycs-settings`）。作用域限定防泄漏到胶囊窗口（胶囊无滚动条，防御性限定）。

### 3. 胶囊盈亏显示

- **数据模型**：`CapsuleConfig.showPnl: boolean`（TS + Rust `show_pnl`）。默认 **true**（用户主动要的功能）——Rust 侧 `#[serde(default = "default_show_pnl")]`（旧 config.json 无字段时开），`fn default_show_pnl() -> bool { true }`；`Default` 实现同步；`DEFAULT_CONFIG`（TS）加 `showPnl: true`。
- **胶囊渲染**（`src/App.tsx`）：
  - 浮盈 = `computePosition(position, ticker.price).pnl`（复用 `calc.ts` 纯函数；position 取 `config.positions.find(symbol === config.symbol)` 且 `quantity > 0`）。
  - 显示条件：`config.showPnl && position && ticker`；显示 `+12.34u` / `-1.92u`（`toFixed(2)`，正数带 +，颜色绿涨红跌由盈亏正负决定，独立于涨跌幅根类）。
  - 无仓位/全平/无行情：该字段不渲染（宽度由 Rust 侧同步收缩）。
  - DOM：`<span className="ycs-pnl">{...}</span>`，样式入 capsule.css（`--up/--down` 变色 + 等宽数字）。
- **胶囊宽度**（`lib.rs compute_capsule_size`）：`if cfg.show_pnl { content += 66.0; fields += 1; }`（"+123.45u" 约 8 字符估算）。JS 侧与 Rust 的显示条件无法完全同步（Rust 不知道有无仓位）——宽度按 showPnl 常开预留，无仓位时字段不渲染（胶囊右侧留少量空白可接受，与 symbol/price 占位"—"行为差异：现有字段占位显示"—"，pnl 无仓位直接消失）。
- **设置界面**（`Settings.tsx`）：显示字段开关区加一行"显示盈亏（浮盈）"ToggleRow，`update({ showPnl: value })`。
- **联动**：config-changed 事件已广播（保存路径复用），胶囊自动刷新；仓位由首页"应用到仓位"更新后同样经 save_config → config-changed 生效。

## 三、错误处理

| 场景 | 行为 |
|---|---|
| 旧 config.json 无 showPnl | serde default → true |
| 胶囊无行情/无仓位 | 盈亏字段不渲染 |
| 最小化/隐藏命令失败 | `let _ =` 静默（窗口引用注入必然有效） |
| 标题栏拖动 | drag-region 属性由 Tauri 处理 |

## 四、测试

1. 单测：无新增纯函数（computePosition 已覆盖）；DEFAULT_CONFIG 字段由 tsc 保证。
2. CDP 实测：
   - 标题栏存在且按钮可点（点最小化 → 窗口 IsIconic；点关闭 → 窗口隐藏、胶囊仍活）
   - 滚动条样式 getComputedStyle/伪元素不可直接读——以 CSS 规则存在 + 截图肉眼确认
   - 胶囊盈亏：造仓位 + 等 ticker → `.ycs-pnl` 文本与 computePosition 期望一致、颜色类正确；Settings 关闭开关 → 字段消失、宽度变化
3. 回归：cdp-apply/cdp-sim/cdp-interact 全绿（新标题栏使视口高度 -34px，零滚动断言须仍成立——marketbar 34px + body 298px 在 362-34=328px 可用高度内将溢出！**home 窗口高度需从 362 调到 396 或 body 压缩**）——见下方"布局适配"。

### 布局适配（关键）

home 窗口现 1081×362（tauri.conf.json）。去掉系统标题栏后 WebView 全高可用，自绘标题栏占 34px。两选一：
- **A（采纳）**：窗口高度维持 362，主区可用高度 = 362-34 = 328px：marketbar 34 + gap 8 + body 286px。body 内 K 线 canvas 自适应、右栏 `.ycs-panel` 300px 宽不变、高度 286px 时持仓卡+模拟卡需内部滚动（`.ycs-panel` 已有 overflow-y: auto，天然支持；实际此前 298px 高也常滚动）。
- B：窗口加高到 396。改变用户习惯窗口尺寸，不采纳。

## 五、不做（YAGNI）

- 不做标题栏双击最大化（home 固定布局无最大化态；settings 亦固定尺寸）。
- 不做盈亏点击交互（弹窗/跳转）。
- 不做 settings 窗口 resizable 调整（保持现状）。
- 胶囊不做已实现盈亏显示（口径已定浮盈）。