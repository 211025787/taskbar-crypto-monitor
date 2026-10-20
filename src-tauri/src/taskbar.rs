//! Windows 11 任务栏几何探测与胶囊窗口定位模块
//!
//! 原理：Win11 任务栏宿主窗口为 Explorer 进程内的 Shell_TrayWnd，
//! 通过 GetWindowRect 获取其屏幕矩形（物理像素），再将胶囊窗口
//! 以 HWND_TOPMOST 层级放置到任务栏左半区空白带，实现"覆盖在任务栏上"。

use windows_sys::Win32::Foundation::{HWND, RECT};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    FindWindowW, GetDesktopWindow, GetWindow, GetWindowLongPtrW, GetWindowRect,
    SetWindowLongPtrW, SetWindowPos, GW_CHILD, GW_HWNDNEXT, GWL_EXSTYLE, HWND_TOPMOST,
    SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW, WS_EX_NOACTIVATE,
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


/// 启动 Z 序看门狗线程：周期检测并修复被任务栏压过的胶囊窗口
///
/// Win11 的任务栏（TaskbarFrame）会在窗口激活等事件后重新断言自身置顶，
/// 看门狗以 1.2 秒间隔检测，发现胶囊被压过立即重新断言，保证持续覆盖。
pub fn spawn_zorder_watchdog(hwnd: HWND) {
    // 以 usize 形式跨线程传递窗口句柄，规避裸指针的非 Send 限制
    let hwnd_bits = hwnd as usize;
    std::thread::spawn(move || {
        let hwnd = hwnd_bits as HWND;
        loop {
            std::thread::sleep(std::time::Duration::from_millis(1200));
            if is_below_taskbar(hwnd) {
                reassert_topmost(hwnd);
            }
        }
    });
}