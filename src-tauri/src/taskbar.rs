//! Windows 11 任务栏几何探测与胶囊窗口定位模块
//!
//! 原理：Win11 任务栏宿主窗口为 Explorer 进程内的 Shell_TrayWnd，
//! 通过 GetWindowRect 获取其屏幕矩形（物理像素），再将胶囊窗口
//! 以 HWND_TOPMOST 层级放置到任务栏左半区空白带，实现"覆盖在任务栏上"。

use windows_sys::Win32::Foundation::{HWND, POINT, RECT};
use windows_sys::Win32::Graphics::Gdi::{
    BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CreateBitmap, CreateDIBSection, DeleteObject, DIB_RGB_COLORS, RGBQUAD,
};
use windows_sys::Win32::UI::Accessibility::{SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateIconIndirect, DispatchMessageW, FindWindowW, GetDesktopWindow, GetMessageW, GetWindow, GetWindowLongPtrW,
    GetWindowRect, ICONINFO, ICON_BIG, ICON_SMALL2, SendMessageW, SetClassLongPtrW, SetTimer, SetWindowLongPtrW,
    SetWindowPos, TranslateMessage, EVENT_OBJECT_REORDER, EVENT_SYSTEM_FOREGROUND, GCL_HICON, GCL_HICONSM, GW_CHILD,
    GW_HWNDNEXT, GWL_EXSTYLE, HWND_TOPMOST, MSG, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW, WM_SETICON,
    WINEVENT_OUTOFCONTEXT, WS_EX_NOACTIVATE,
};

/// 任务栏几何信息（屏幕物理像素坐标）
pub struct TaskbarGeometry {
    /// 左边界 X 坐标（物理像素）
    pub left: i32,
    /// 顶边界 Y 坐标（物理像素）
    pub top: i32,
    /// 右边界 X 坐标（物理像素）
    pub right: i32,
    /// 底边界 Y 坐标（物理像素）
    pub bottom: i32,
}

/// 将 &str 编码为以 NUL 结尾的 UTF-16 宽字符串（Win32 API 入参格式）
fn to_wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 为窗口补设任务栏按钮使用的大图标（ICON_BIG）与类图标
///
/// wry 的 set_window_icon 仅设置 ICON_SMALL/ICON_SMALL2，而任务栏按钮与
/// Alt-Tab 取 ICON_BIG，缺失时回退 exe 资源图标——该路径受系统图标缓存
/// 影响可能长期显示旧图。此函数用原始 RGBA 数据直接构造 HICON 显式
/// 下发，绕开图标缓存。
pub fn set_taskbar_icon(hwnd: HWND, rgba: &[u8], width: i32, height: i32) {
    unsafe {
        // 32bpp ARGB 自顶向下 DIB：biHeight 取负值
        let bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                biHeight: -height,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB,
                biSizeImage: 0,
                biXPelsPerMeter: 0,
                biYPelsPerMeter: 0,
                biClrUsed: 0,
                biClrImportant: 0,
            },
            bmiColors: [RGBQUAD { rgbBlue: 0, rgbGreen: 0, rgbRed: 0, rgbReserved: 0 }],
        };
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let color = CreateDIBSection(
            std::ptr::null_mut(),
            &bmi,
            DIB_RGB_COLORS,
            &mut bits,
            std::ptr::null_mut(),
            0,
        );
        if color.is_null() || bits.is_null() {
            return;
        }
        // RGBA → BGRA 逐像素换序写入 DIB（GDI 32bpp 位图字节序为 BGRA）
        let pixels = bits as *mut u8;
        for i in 0..(width as usize * height as usize) {
            let src = &rgba[i * 4..i * 4 + 4];
            *pixels.add(i * 4) = src[2];
            *pixels.add(i * 4 + 1) = src[1];
            *pixels.add(i * 4 + 2) = src[0];
            *pixels.add(i * 4 + 3) = src[3];
        }
        // 单色空掩码：32bpp 图标的透明度全部由 alpha 通道承载
        let mask = CreateBitmap(width, height, 1, 1, std::ptr::null());
        let info = ICONINFO { fIcon: 1, xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color };
        let hicon = CreateIconIndirect(&info);
        // CreateIconIndirect 内部复制位图资源，输入位图立即释放
        DeleteObject(color);
        DeleteObject(mask);
        if hicon.is_null() {
            return;
        }
        // ICON_BIG：任务栏按钮与 Alt-Tab；ICON_SMALL2：任务栏备用小尺寸
        SendMessageW(hwnd, WM_SETICON, ICON_BIG as usize, hicon as isize);
        SendMessageW(hwnd, WM_SETICON, ICON_SMALL2 as usize, hicon as isize);
        // 类图标兜底：窗口未响应 WM_GETICON 时系统回退使用的图标槽位
        SetClassLongPtrW(hwnd, GCL_HICON as i32, hicon as isize);
        SetClassLongPtrW(hwnd, GCL_HICONSM as i32, hicon as isize);
        // HICON 所有权已移交窗口与窗口类，无需 DestroyIcon
    }
}

/// 探测主任务栏（Shell_TrayWnd）的屏幕矩形；任务栏不可见或探测失败时返回 None
pub fn query_taskbar_geometry() -> Option<TaskbarGeometry> {
    unsafe {
        let class_name = to_wide("Shell_TrayWnd");
        // Shell_TrayWnd 为 Win11 主任务栏窗口，主显示器仅存在一个实例
        let taskbar_hwnd = FindWindowW(class_name.as_ptr(), std::ptr::null());
        if taskbar_hwnd.is_null() {
            return None;
        }
        let mut rect = RECT { left: 0, top: 0, right: 0, bottom: 0 };
        if GetWindowRect(taskbar_hwnd, &mut rect) == 0 {
            return None;
        }
        Some(TaskbarGeometry { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom })
    }
}

/// 为窗口追加 WS_EX_NOACTIVATE 扩展样式：点击胶囊时不抢占前台焦点
pub fn apply_no_activate_style(hwnd: HWND) {
    unsafe {
        let style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style | WS_EX_NOACTIVATE as isize);
    }
}

/// 将胶囊窗口定位到任务栏上方（左半区空白带），保持置顶层级
///
/// 参数：
/// - hwnd：胶囊窗口句柄
/// - width / height：胶囊窗口尺寸（物理像素）
///
/// 返回：定位是否成功
pub fn place_capsule_over_taskbar(hwnd: HWND, width: i32, height: i32) -> bool {
    let Some(geo) = query_taskbar_geometry() else {
        return false;
    };
    // Win11 任务栏固定于屏幕底部：在任务栏高度内垂直居中放置胶囊
    let bar_height = geo.bottom - geo.top;
    // 左侧偏移 64 物理像素，避开开始/搜索按钮区域
    let x = geo.left + 64;
    // 右边界钳制：胶囊右沿不得超出任务栏右沿（保留 8px 安全边距，任务栏过窄时退化为左对齐）
    let max_x = geo.right - width - 8;
    let x = x.min(max_x.max(geo.left));
    let y = geo.top + ((bar_height - height) / 2).max(0);
    unsafe {
        // HWND_TOPMOST 保证覆盖在任务栏之上；NOACTIVATE 避免抢焦点
        SetWindowPos(hwnd, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW) != 0
    }
}
/// 检测胶囊窗口当前是否位于任务栏之下（Z 序低于 Shell_TrayWnd）
///
/// 原理：从桌面首个子窗口（Z 序最高）向下遍历，先遇到谁谁在上。
/// Win11 任务栏会周期性重新断言自身置顶层级，把胶囊压到其下方，需检测后重新断言。
pub fn is_below_taskbar(hwnd: HWND) -> bool {
    unsafe {
        let class_name = to_wide("Shell_TrayWnd");
        let taskbar_hwnd = FindWindowW(class_name.as_ptr(), std::ptr::null());
        // 任务栏不存在时无从比较，视为不需要修复
        if taskbar_hwnd.is_null() {
            return false;
        }
        // GW_CHILD 返回 Z 序最高的顶层窗口，GW_HWNDNEXT 依次向下走
        let mut current = GetWindow(GetDesktopWindow(), GW_CHILD);
        while !current.is_null() {
            if current == hwnd {
                // 先遍历到胶囊：胶囊在任务栏之上
                return false;
            }
            if current == taskbar_hwnd {
                // 先遍历到任务栏：胶囊被压在下方
                return true;
            }
            current = GetWindow(current, GW_HWNDNEXT);
        }
        false
    }
}

/// 重新断言胶囊的 TOPMOST 层级（不移动、不改尺寸、不抢焦点）
pub fn reassert_topmost(hwnd: HWND) {
    unsafe {
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
    }
}


/// 上次 Z 序重断言事件处理的时间戳（毫秒，Unix 基准），用于去抖门槛比较
static LAST_REASSERT_MS: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(0);

/// 胶囊窗口句柄的线程共享（看门狗 FFI 回调读取；usize 规避裸指针非 Send）
static CAPSULE_HWND: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// 兜底定时器周期（毫秒）：钩子失效场景下的低频周期检测
const WATCHDOG_FALLBACK_MS: u32 = 3000;

/// WinEvent 回调去抖间隔（毫秒）：合并任务栏重排伴随密集连发的多个事件
const WIN_EVENT_DEBOUNCE_MS: i64 = 50;

/// 当前 Unix 时间戳（毫秒），作为去抖门槛的比较基准
fn unix_time_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

/// WinEvent 回调：前台切换 / Z 序重排事件驱动的即时重断言入口（FFI 系统调用约定）
///
/// 主路径：SetWinEventHook 以 [EVENT_SYSTEM_FOREGROUND, EVENT_OBJECT_REORDER] 闭区间
/// 监听系统事件，任务栏重新断言自身置顶把胶囊压下的瞬间即触发本回调，经 50ms
/// 去抖后立即 reassert_topmost——取代旧版 1.2 秒轮询，消除窗口期内的可见闪烁。
unsafe extern "system" fn on_win_event(
    _hook: HWINEVENTHOOK,
    _event: u32,
    _hwnd: HWND,
    _id_object: i32,
    _id_child: i32,
    _id_thread: u32,
    _event_time: u32,
) {
    let capsule = CAPSULE_HWND.load(std::sync::atomic::Ordering::Relaxed) as HWND;
    if capsule.is_null() {
        return;
    }
    let now = unix_time_ms();
    // 50ms 去抖：任务栏重排通常伴随多个事件连发，合并为一次重断言避免抖动
    if now - LAST_REASSERT_MS.load(std::sync::atomic::Ordering::Relaxed) < WIN_EVENT_DEBOUNCE_MS {
        return;
    }
    LAST_REASSERT_MS.store(now, std::sync::atomic::Ordering::Relaxed);
    reassert_topmost(capsule);
}

/// 兜底定时器回调：WinEvent 钩子静默失效场景下的低频周期检测（FFI 系统调用约定）
///
/// WM_TIMER 消息由消息泵 DispatchMessageW 分发进入本回调（SetTimer 的 NULL-hwnd
/// 形态下系统直接调用 TIMERPROC 而非投递窗口过程），语义与旧版轮询看门狗一致：
/// 仅当胶囊确实被压到任务栏之下才重断言，避免无谓的 SetWindowPos 抖动。
unsafe extern "system" fn on_fallback_timer(_hwnd: HWND, _msg: u32, _timer_id: usize, _time: u32) {
    let capsule = CAPSULE_HWND.load(std::sync::atomic::Ordering::Relaxed) as HWND;
    if capsule.is_null() {
        return;
    }
    if is_below_taskbar(capsule) {
        reassert_topmost(capsule);
    }
}

/// 启动 Z 序看门狗线程：事件驱动重断言 + 3 秒兜底 + 钩子失败退回轮询
///
/// 三层防线：
/// 1. 主路径——SetWinEventHook 监听 [EVENT_SYSTEM_FOREGROUND, EVENT_OBJECT_REORDER]
///    闭区间事件（前台切换 / Z 序重排），回调 50ms 去抖后即时重断言，消除旧版
///    1.2 秒轮询窗口期内"点击任务栏图标 → 胶囊被压下 → 最长 1.2 秒后捞回"的可见闪烁；
/// 2. 兜底——3 秒 SetTimer 周期检测，覆盖钩子静默失效场景；
/// 3. 退路——钩子安装失败时回退旧版 1.2 秒 sleep 轮询循环，行为不劣化。
pub fn spawn_zorder_watchdog(hwnd: HWND) {
    // 以 usize 形式跨线程共享窗口句柄供 FFI 回调读取；规避裸指针的非 Send 限制
    CAPSULE_HWND.store(hwnd as usize, std::sync::atomic::Ordering::Relaxed);
    // 闭包不捕获裸指针句柄：线程内一律经 CAPSULE_HWND 原子读取
    std::thread::spawn(|| unsafe {
        // 事件范围为闭区间 [min, max]：前台切换(3) 起、Z 序重排(0x8004) 止
        let hook = SetWinEventHook(
            EVENT_SYSTEM_FOREGROUND,
            EVENT_OBJECT_REORDER,
            std::ptr::null_mut(),
            Some(on_win_event),
            0,
            0,
            WINEVENT_OUTOFCONTEXT,
        );
        // 钩子句柄无效即安装失败：退回旧版 1.2 秒 sleep 轮询，兜底行为不劣化
        if hook.is_null() {
            let capsule = CAPSULE_HWND.load(std::sync::atomic::Ordering::Relaxed) as HWND;
            loop {
                std::thread::sleep(std::time::Duration::from_millis(1200));
                if is_below_taskbar(capsule) {
                    reassert_topmost(capsule);
                }
            }
        }
        // 兜底定时器融入消息循环（NULL-hwnd 形态）：失败仅损失兜底周期，主路径不受影响
        SetTimer(std::ptr::null_mut(), 1, WATCHDOG_FALLBACK_MS, Some(on_fallback_timer));
        // WINEVENT_OUTOFCONTEXT 回调经本线程消息队列分发：驻留 GetMessage 消息泵
        let mut msg = MSG {
            hwnd: std::ptr::null_mut(),
            message: 0,
            wParam: 0,
            lParam: 0,
            time: 0,
            pt: POINT { x: 0, y: 0 },
        };
        loop {
            // 返回值：0 = WM_QUIT、-1 = 错误，两者均终止消息泵
            let ret = GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0);
            if ret <= 0 {
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        // 消息泵退出后卸载事件钩子，避免回调悬挂于已死线程
        UnhookWinEvent(hook);
    });
}