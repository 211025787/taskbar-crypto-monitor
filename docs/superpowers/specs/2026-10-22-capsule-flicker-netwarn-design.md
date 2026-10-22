# 胶囊闪烁修复 + 网络异常警示 设计

日期：2026-10-22
状态：已与用户对齐（叠加警示式：保留旧价格 + 警示图标）

## 一、问题与根因

### 1. 点击任务栏其他图标时胶囊闪一下
- **根因**：`taskbar.rs` 的 Z 序看门狗为 **1.2 秒轮询**。点击任务栏图标 → Win11 TaskbarFrame 重新断言自身置顶 → 胶囊瞬间被压到任务栏之下（视觉消失）→ 看门狗最长 1.2 秒后 `reassert_topmost` 捞回 → 表现为"闪一下"。
- **修复**：事件驱动化——看门狗线程安装 `SetWinEventHook(EVENT_OBJECT_REORDER, WINEVENT_OUTOFCONTEXT)` 并运行 `GetMessage` 消息循环；系统 z-order 变化回调触发时 30ms 去抖后立即 `reassert_topmost`；保留 3 秒周期兜底轮询（防钩子失效场景）。

### 2. 网络异常断开时胶囊显示警示
- **现状**：`market.rs` 已广播 `ws-status`（WS 断流 → state=reconnecting；REST 降级 → state=polling），但胶囊前端未监听；REST 轮询模式下持续失败（如 FlClash 关闭）无任何信号。
- **方案（叠加警示式，用户已选）**：网络异常时**保留旧价格**（最后生效数据）并在胶囊上**追加警示图标**（黄色 ⚠，轻微脉动动画），行情恢复后警示自动消失。

## 二、实现设计

### 1. taskbar.rs 看门狗事件驱动化

- `spawn_zorder_watchdog` 改造：
  - 安装 `SetWinEventHook`：事件 `EVENT_OBJECT_REORDER`（z-order 变化，含任务栏重排）+ `EVENT_SYSTEM_FOREGROUND`（前台切换，点击任务栏图标激活窗口的伴随事件），作用域 `WINEVENT_OUTOFCONTEXT`。
  - 线程主循环改为 `GetMessageW` 消息循环（WinEventHook 回调依赖线程消息泵）。
  - 回调内 30ms 去抖（合并密集触发）后调 `reassert_topmost`。
  - 兜底：消息循环空闲时以 `MsgWaitForMultipleObjects`/超时方式维持 3 秒周期检测（原 1.2s 降为 3s，主路径已事件化）。
- `windows-sys` 需追加导入：`SetWinEventHook`/`UnhookWinEvent`/`GetMessageW`/`MSG`/`SetTimer`/`TranslateMessage`/`DispatchMessageW` 等（视实现方式取舍，优先用 `SetTimer` 实现周期兜底，融入消息循环最简）。

### 2. market.rs 轮询失败信号

- `run_polling` 增加连续失败计数：≥3 次（约 4.5 秒无数据）→ emit `ws-status` state="reconnecting"、detail="轮询失败，网络异常"；后续恢复成功 → emit state="polling" 复位。
- WS 路径补一处：连接成功收流时 emit state="connected"（前端恢复判据之一）。

### 3. 前端 App.tsx 警示渲染

- 新增 state `netWarning: boolean`（默认 false）。
- `listen<WsStatus>("ws-status")`：state === "reconnecting" → true；state === "connected" || "polling" → false。
- `ticker-update` 处理器追加：收到行情即 false（双保险）。
- 渲染：`netWarning === true` 时在字段区**末尾**追加警示图标 `<span className="ycs-netwarn" title="当前网络异常">⚠</span>`；旧价格/涨跌/盈亏保留显示（失效数据）。
- capsule.css：`.ycs-netwarn` 黄色 `#f5ca55`、12px、带 `@keyframes` 轻微脉动（opacity 0.6↔1，1.5s 循环，克制不扰民）。

## 三、错误处理

| 场景 | 行为 |
|---|---|
| WinEventHook 安装失败 | 回退纯周期兜底（现状行为不劣化） |
| 消息循环异常退出 | 线程结束前打日志；兜底周期仍在消息循环内则同退——故兜底用 SetTimer 融入循环，钩子失败时仍需独立 sleep 循环路径 |
| ws-status 事件丢失 | ticker-update 兜底清警示 |
| 警示期间用户切合约 | switch_symbol 触发 connecting → 保持警示直至新数据到达 |

## 四、测试

1. 单测：无新增纯函数（Rust 侧为系统交互，不引入单测）。
2. CDP 实测：
   - **网络异常**：模拟断网（关闭 FlClash 由用户配合/或 Rust 侧无直接开关——用 CDP evaluate 无法直接断网；方案：临时把 ws-status 事件由 CDP `__TAURI_INTERNALS__.event.emit` 触发？前端 listen 走真实事件总线，可用 Rust 侧 emit 测试钩子不可行。改为验证：关代理实测一次 + 代码走查）→ 断言 `.ycs-netwarn` 出现、旧价格保留；恢复网络 → 警示消失。
   - **闪烁**：无直接 CDP 断言（z-order 属 Win32 层）；验证看门狗消息循环存活（日志）+ 用户肉眼确认点击任务栏图标不再闪。
3. 回归：cdp-titlebar / cdp-interact 全绿。

## 五、不做（YAGNI）

- 不做网络延迟指标显示（仅异常/正常两态）。
- 不做多合约独立网络状态（单流单状态）。
- 警示不做点击交互。