# 胶囊闪烁修复 + 网络异常警示 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 看门狗事件驱动化消除点击任务栏图标时胶囊闪烁；网络异常时胶囊叠加黄色警示图标（保留旧价格）。

**Architecture:** taskbar.rs 看门狗从 1.2s 轮询改为 `SetWinEventHook`（EVENT_OBJECT_REORDER/ EVENT_SYSTEM_FOREGROUND）+ `GetMessageW` 消息循环 + `SetTimer` 3s 兜底；market.rs 轮询连续失败 ≥3 次广播 reconnecting 状态、恢复时广播 polling 复位、WS 收流成功广播 connected；App.tsx 监听 ws-status 渲染 `.ycs-netwarn` 脉动图标。

**Tech Stack:** Tauri 2 + Rust（windows-sys 0.59 需追加 `Win32_UI_Accessibility` feature）+ React 19 + TS；验证走 CDP（9333）+ 用户肉眼。

**设计 spec:** `docs/superpowers/specs/2026-10-22-capsule-flicker-netwarn-design.md`

---

## 关键事实（实现者必读）

1. **windows-sys feature**：`SetWinEventHook`/`UnhookWinEvent` 在 `Win32_UI_Accessibility` 模块；`GetMessageW`/`SetTimer`/`TranslateMessage`/`DispatchMessageW`/`MSG`/`WM_TIMER` 在已有的 `Win32_UI_WindowsAndMessaging`。Cargo.toml 需追加 `"Win32_UI_Accessibility"`。
2. **WinEventHook 回调运行在安装线程**（OUTOFCONTEXT 上下文），该线程必须有消息循环（GetMessageW 泵）；回调签名 `unsafe extern "system" fn(hWinEventHook, event, hwnd, idObject, idChild, idEventThread, dwmsEventTime)`。
3. **去抖用 SetTimer 实现**：回调内不直接 reassert（密集触发会风暴），而是每次触发 `SetTimer(hwnd_null, 1, 30ms, None)` 重置定时器——注意 SetTimer 需要窗口句柄或用 `SetTimer(0, ...)`（NULL hwnd 定时器派发到调用线程消息队列）。NULL-hwnd SetTimer 的 WM_TIMER 经由 GetMessageW 取到后 Dispatch 即触发（无窗口过程）——**简化**：回调内直接用原子时间戳记录 last-trigger，消息循环里用 `MsgWaitForMultipleObjectsEx` 带 30ms+3s 双周期判定更复杂；**最终方案（简单可靠）**：回调里直接 `reassert_topmost`（SetWindowPos NOACTIVATE|NOMOVE|NOSIZE 本身极轻，z-order 事件频率有限即几百 ms 一档，可接受），去抖改为回调内 50ms 时间戳门槛（`AtomicI64` 比较）。
4. market.rs 现有 `WsStatus { state, detail }` 序列化 camelCase；前端 types.ts 已有对应 `WsStatus` 接口（Home.tsx 在用，klineStatus 是另一路事件 `kline-status`——勿混淆）。
5. code-spec：4 空格缩进、行宽 160、全覆盖 `///` 与 JSDoc 注释、UTF-8 无 BOM、末尾换行。
6. 构建/CDP/打包由控制者执行；Rust 验证命令：cargo check（PowerShell 原生环境模板见各任务）。

---

### Task 1: 看门狗事件驱动化（taskbar.rs + Cargo.toml）

**Files:**
- Modify: `src-tauri/Cargo.toml:33-38`（windows-sys features）
- Modify: `src-tauri/src/taskbar.rs:186-205`（spawn_zorder_watchdog 重写）

- [ ] **Step 1: Cargo.toml 追加 feature**

```toml
windows-sys = { version = "0.59", features = [
    "Win32_Foundation",
    "Win32_UI_WindowsAndMessaging",
    "Win32_UI_Accessibility",
    "Win32_Graphics_Gdi",
] }
```

（注释行补一句：Accessibility 提供 SetWinEventHook 供 z-order 看门狗事件驱动。）

- [ ] **Step 2: taskbar.rs 头部 use 追加**

```rust
use windows_sys::Win32::UI::Accessibility::SetWinEventHook;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, GetMessageW, SetTimer, TranslateMessage, EVENT_OBJECT_REORDER, EVENT_SYSTEM_FOREGROUND,
    MSG, WM_TIMER, WINEVENT_OUTOFCONTEXT,
};
```

（按实际模块路径核对：`EVENT_OBJECT_REORDER`/`EVENT_SYSTEM_FOREGROUND`/`WINEVENT_OUTOFCONTEXT` 常量位于 `Win32::UI::WindowsAndMessaging`；`SetWinEventHook` 位于 `Win32::UI::Accessibility`。若编译报路径不符，以 windows-sys 0.59 实际导出为准修正并在报告说明。）

- [ ] **Step 3: 重写 spawn_zorder_watchdog**

替换现有函数（保留函数签名与文档注释骨架，更新描述为事件驱动）：

```rust
/// 上次 z-order 事件处理的时间戳（毫秒，std::time 基准），用于 50ms 去抖门槛
static LAST_REASSERT_MS: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);

/// WinEvent 回调：z-order 变化/前台切换瞬间去抖后立即重新断言胶囊置顶
unsafe extern "system" fn on_win_event(
    _hook: HWINEVENTHOOK,
    _event: u32,
    _hwnd: HWND,
    _id_object: i32,
    _id_child: i32,
    _thread: u32,
    _time: u32,
) {
    // 以 usize 形式读取安装线程存下的胶囊句柄（跨 FFI 边界的惯例做法）
    let hwnd = CAPSULE_HWND.load(std::sync::atomic::Ordering::SeqCst) as HWND;
    if hwnd as usize == 0 {
        return;
    }
    // 50ms 去抖：密集 z-order 事件风暴只触发一次重断言
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let last = LAST_REASSERT_MS.load(std::sync::atomic::Ordering::SeqCst);
    if now - last < 50 {
        return;
    }
    LAST_REASSERT_MS.store(now, std::sync::atomic::Ordering::SeqCst);
    reassert_topmost(hwnd);
}

/// 胶囊窗口句柄的线程共享（看门狗线程 FFI 回调读取；usize 规避裸指针非 Send）
static CAPSULE_HWND: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// 兜底定时器周期（毫秒）：钩子失效场景下的低频周期检测
const WATCHDOG_FALLBACK_MS: u32 = 3000;

/// 启动 Z 序看门狗线程：事件驱动（SetWinEventHook）+ 低频兜底定时器
///
/// Win11 的任务栏（TaskbarFrame）会在窗口激活等事件后重新断言自身置顶。
/// 主路径：监听系统 z-order 变化/前台切换（EVENT_OBJECT_REORDER / EVENT_SYSTEM_FOREGROUND），
/// 变化瞬间 50ms 去抖后立即重断言，消除原 1.2s 轮询的可见闪烁。
/// 兜底：3 秒 SetTimer 周期检测（钩子安装失败或事件丢失时仍能恢复）。
pub fn spawn_zorder_watchdog(hwnd: HWND) {
    let hwnd_bits = hwnd as usize;
    CAPSULE_HWND.store(hwnd_bits, std::sync::atomic::Ordering::SeqCst);
    std::thread::spawn(move || {
        let hwnd = hwnd_bits as HWND;
        // 安装 z-order/前台变化钩子（OUTOFCONTEXT：回调在本线程消息循环中执行）
        let hook = unsafe {
            SetWinEventHook(
                EVENT_SYSTEM_FOREGROUND,
                EVENT_OBJECT_REORDER,
                None,
                Some(on_win_event),
                0,
                0,
                WINEVENT_OUTOFCONTEXT,
            )
        };
        if hook.is_invalid() {
            // 钩子不可用：退回纯周期模式（1.2s 轮询，行为与旧版一致）
            println!("[taskbar] WinEventHook 安装失败，退回周期看门狗");
            loop {
                std::thread::sleep(std::time::Duration::from_millis(1200));
                if is_below_taskbar(hwnd) {
                    reassert_topmost(hwnd);
                }
            }
        }
        // 消息泵：WinEventHook 回调与 SetTimer 兜底都经由本线程消息队列分发
        unsafe { SetTimer(None, 1, WATCHDOG_FALLBACK_MS, Some(on_fallback_timer)) };
        println!("[taskbar] z-order 看门狗已事件驱动化（兜底 {WATCHDOG_FALLBACK_MS}ms）");
        let mut msg: MSG = std::mem::zeroed();
        loop {
            let ret = unsafe { GetMessageW(&mut msg, None, 0, 0) };
            if ret <= 0 {
                // GetMessage 返回 0（WM_QUIT）或 -1（错误）：退出并卸载钩子
                break;
            }
            unsafe {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        unsafe { windows_sys::Win32::UI::Accessibility::UnhookWinEvent(hook) };
    });
}

/// 兜底定时器回调：低频检测胶囊是否被压到任务栏之下（钩子失效场景的最后防线）
unsafe extern "system" fn on_fallback_timer(hwnd: HWND, _msg: u32, _id: usize, _time: u32) {
    let capsule = CAPSULE_HWND.load(std::sync::atomic::Ordering::SeqCst) as HWND;
    if capsule as usize != 0 && is_below_taskbar(capsule) {
        reassert_topmost(capsule);
    }
}
```

**实现要点（照抄时按编译器反馈微调并报告）：**
- `HWINEVENTHOOK` 类型从 `Win32::UI::Accessibility` 导入；`is_invalid()` 判断钩子失败（windows-sys 里是 `IsBadHwineventhook`？——0.59 中 HWINEVENTHOOK 是裸指针类型，判空用 `hook.is_null()`，按实际类型修正）。
- `SetTimer` 第一个参数 NULL-hwnd 时第四参数回调签名是 `TIMERPROC`（`Option<unsafe extern "system" fn(hwnd, msg, wp, lp)>`）；NULL-hwnd timer 的 WM_TIMER 直接经 GetMessageW 返回（lp = timer id），**Dispatch 到无窗口过程仍会调 TIMERPROC**——若编译/行为不符，替代方案：消息循环里识别 `msg.message == WM_TIMER` 直接调 `on_fallback_timer` 逻辑（`TranslateMessage`/`DispatchMessageW` 保留无害）。
- `GetMessageW` 返回 i32；`None` 表示不过滤窗口。
- 事件范围参数：`SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_OBJECT_REORDER, ...)` 的范围起止取值按 windows-sys 常量实际数值排序（3 ≤ event ≤ 0x8004，范围参数语义为 [min, max]）——两个常量数值顺序若反了则交换传参。

- [ ] **Step 4: cargo check 验证**

Run: `powershell -NoProfile -Command '$env:RUSTUP_HOME="D:\develop\rust\rustup"; $env:CARGO_HOME="D:\develop\rust\cargo"; $env:PATH="D:\develop\msys2\mingw64\bin;D:\develop\rust\cargo\bin;C:\Windows\System32;C:\Windows"; Set-Location D:\ipyProject\ai-contract\src-tauri; cargo check 2>&1 | Select-Object -Last 6'`
Expected: 无 error

- [ ] **Step 5: Commit**

```bash
git add src-tauri/Cargo.toml src-tauri/src/taskbar.rs
git commit -m "Feat 看门狗事件驱动化消除胶囊闪烁"
```

---

### Task 2: market.rs 网络状态信号补强

**Files:**
- Modify: `src-tauri/src/market.rs`（run_polling 失败计数 + WS connected 广播）

- [ ] **Step 1: run_stream 广播 connected**

`run_stream` 中 `Ok((ws, _)) =>` 分支的 `println!("[market] WebSocket 已连接: {symbol}");` 之后追加：

```rust
                let _ = app.emit("ws-status", WsStatus { state: "connected".to_string(), detail: String::new() });
```

- [ ] **Step 2: run_polling 失败计数与异常信号**

`run_polling` 的 `println!("[market] 进入 REST 轮询模式: {symbol}");` 之后初始化计数，循环体改造（完整替换 run_polling 函数）：

```rust
/// REST 轮询模式：按固定间隔拉取 24hr ticker 并广播，直到订阅过期
///
/// 适用于推送流不可用的网络环境（数据可用性与 WS 等价，延迟略高）。
/// 连续失败 3 次（约 4.5 秒无数据）广播 reconnecting 异常态，前端据此显示网络警示；
/// 恢复成功后广播 polling 复位。
async fn run_polling(app: AppHandle, symbol: String, generation: u64) {
    println!("[market] 进入 REST 轮询模式: {symbol}");
    let _ = app.emit(
        "ws-status",
        WsStatus { state: "polling".to_string(), detail: "推送流不可用，已切换轮询模式".to_string() },
    );
    // 连续失败计数：达到阈值后置为 0 之外的大值避免重复广播（首次广播时归位）
    let mut consecutive_failures: u32 = 0;
    loop {
        // 订阅已被更新取代：退出轮询
        if SUBSCRIPTION.load(Ordering::SeqCst) != generation {
            println!("[market] 订阅已过期，轮询任务退出: {symbol}");
            return;
        }
        // ureq 为同步客户端：放阻塞线程池执行，避免占用异步工作线程
        let fetch_symbol = symbol.clone();
        let result = tauri::async_runtime::spawn_blocking(move || fetch_rest_ticker(&fetch_symbol)).await;
        match result {
            Ok(Ok(ticker)) => {
                let _ = app.emit("ticker-update", &ticker);
                // 恢复成功：若此前处于异常广播态则复位轮询状态
                if consecutive_failures >= 3 {
                    let _ = app.emit(
                        "ws-status",
                        WsStatus { state: "polling".to_string(), detail: "推送流不可用，已切换轮询模式".to_string() },
                    );
                }
                consecutive_failures = 0;
            }
            // 单次拉取失败（网络抖动等）：静默跳过，下一轮重试
            Ok(Err(e)) => {
                println!("[market] REST 轮询失败: {e}");
                consecutive_failures += 1;
                // 连续 3 次失败（约 4.5s 无数据）：广播网络异常，前端显示警示
                if consecutive_failures == 3 {
                    let _ = app.emit(
                        "ws-status",
                        WsStatus { state: "reconnecting".to_string(), detail: "轮询失败，网络异常".to_string() },
                    );
                }
            }
            Err(e) => {
                println!("[market] REST 轮询任务异常: {e}");
            }
        }
        tokio::time::sleep(Duration::from_millis(POLL_INTERVAL_MS)).await;
    }
}
```

- [ ] **Step 3: cargo check 验证**

同 Task 1 Step 4 命令。Expected: 无 error

- [ ] **Step 4: Commit**

```bash
git add src-tauri/src/market.rs
git commit -m "Feat 轮询失败网络异常信号与 WS connected 状态广播"
```

---

### Task 3: 前端警示渲染（App.tsx + capsule.css）

**Files:**
- Modify: `src/App.tsx`（netWarning state + ws-status 监听 + 渲染）
- Modify: `src/styles/capsule.css`（.ycs-netwarn 样式与脉动动画）

- [ ] **Step 1: App.tsx 监听与渲染**

① types.ts 若无 `WsStatus` 接口则末尾追加（先读文件确认——Home.tsx 已在用 kline-status 的 KlineStatus，ws-status 的接口可能缺失）：

```ts
/** 行情流连接状态（ws-status 事件载荷） */
export interface WsStatus {
    /** 状态：connecting / connected / reconnecting / polling */
    state: string;
    /** 状态补充说明（如重连等待秒数、网络异常提示） */
    detail: string;
}
```

② App.tsx：import 区追加 `type WsStatus`；state 区（`hidden` 附近）追加：

```tsx
    /** 网络异常警示：行情流断开或轮询连续失败时置 true，收到行情自动复位 */
    const [netWarning, setNetWarning] = useState(false);
```

③ 事件 effect 内（`listen<TickerData>("ticker-update"...)` 旁边）追加：

```tsx
        // 行情流状态：reconnecting 视为网络异常（含轮询连续失败）；connected/polling 复位
        const unlistenWs = listen<WsStatus>("ws-status", (event) => {
            setNetWarning(event.payload.state === "reconnecting");
        }).catch(() => undefined);
```

注意现有 listen 返回 Promise 的处理模式（读文件：现有 `listen<CapsuleConfig>(...)` 直接赋值 `unlistenConfig` 然后在 cleanup 里 `.then(fn => fn())`——照抄同款；上面 `.catch` 写法若与现有模式不一致则以现有模式为准）。

④ `ticker-update` 处理器内（setTicker 处）追加一行 `setNetWarning(false);`（收到行情即复位，双保险）。

⑤ cleanup 区追加 `unlistenWs` 的取消订阅（照现有模式）。

⑥ render：字段区（`showSparkline` 块之后、`</>` 之前）追加：

```tsx
                    {netWarning && <span className="ycs-netwarn" title="当前网络异常">⚠</span>}
```

（`hidden` 态整体不渲染时警示也隐藏——嵌在现有 `!hidden && (<>...</>)` 内。）

- [ ] **Step 2: capsule.css 追加样式**

```css
/* 网络异常警示图标：黄色轻脉动（克制不扰民，恢复后随状态卸载） */
.ycs-netwarn {
    font-size: calc(11px * var(--ycs-scale, 1));
    color: #f5ca55;
    animation: ycs-netwarn-pulse 1.5s ease-in-out infinite;
}

@keyframes ycs-netwarn-pulse {
    0%,
    100% {
        opacity: 1;
    }

    50% {
        opacity: 0.55;
    }
}
```

（先读 `.ycs-change` 对齐缩放形式。）

- [ ] **Step 3: 验证**

Run: `npx tsc --noEmit 2>&1 | head -5 && npm test -- --run 2>&1 | tail -3`
Expected: 零错误 + 33 全绿

- [ ] **Step 4: Commit**

```bash
git add src/App.tsx src/styles/capsule.css src/types.ts
git commit -m "Feat 胶囊网络异常警示图标（保留旧价格叠加显示）"
```

---

### Task 4: 实机验证 + 打包（控制者执行）

- [ ] **Step 1:** CDP 验证：重启实例 → 正常态无 `.ycs-netwarn`；通过 Rust 侧无法直接注事件——**用真实断网**：请用户关 FlClash → 等 5s 断言 `.ycs-netwarn` 出现且旧价格保留 → 开 FlClash → 断言警示消失；看门狗日志确认（`[taskbar] z-order 看门狗已事件驱动化`）+ 用户肉眼点击任务栏图标确认不闪。
- [ ] **Step 2:** 回归：cdp-titlebar / cdp-interact 全绿。
- [ ] **Step 3:** NSIS 打包 + 弹安装向导 + 落盘确认 + 记忆更新 + 汇报。

## 自审记录

- spec 覆盖：闪烁（Task 1）、网络警示（Task 2/3）、叠加式形态（Task 3 渲染在字段区末尾不替换旧价格）——全覆盖。
- 类型一致性：`WsStatus` 接口前端两处消费（App.tsx 新增；Home.tsx 若已用同名则共享——Task 3 Step 1 ①已处理缺失情况）；Rust `WsStatus` 结构未变。
- Task 1 FFI 细节已标注按编译器反馈微调的授权点（HWINEVENTHOOK 判空/SetTimer 回调路径/事件常量顺序）。