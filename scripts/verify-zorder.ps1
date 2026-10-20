# Z 序决定性验证：按从顶到底枚举顶层窗口，确认胶囊与任务栏的实际遮挡关系
# 同时验证 WindowFromPoint 命中的 explorer 窗口究竟是什么
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;

public static class ZOrderCheck {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder className, int count);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public static List<string> Results = new List<string>();

    public static bool Callback(IntPtr hWnd, IntPtr lParam) {
        if (!IsWindowVisible(hWnd)) return true;
        var rect = new RECT();
        GetWindowRect(hWnd, out rect);
        // 仅保留覆盖任务栏区域（屏幕底部 48px 带）的可见窗口
        if (rect.Top < 1019) return true;
        uint pid = 0;
        GetWindowThreadProcessId(hWnd, out pid);
        var title = new StringBuilder(256);
        GetWindowText(hWnd, title, 256);
        var cls = new StringBuilder(256);
        GetClassName(hWnd, cls, 256);
        Results.Add(string.Format("PID={0} CLASS={1} TITLE={2} RECT=({3},{4})-({5},{6})",
            pid, cls, title, rect.Left, rect.Top, rect.Right, rect.Bottom));
        return true;
    }

    public static List<string> Run() {
        Results.Clear();
        EnumWindows(Callback, IntPtr.Zero);
        return Results;
    }
}
'@

# 从顶到底枚举覆盖任务栏带的所有可见窗口
$zorderList = [ZOrderCheck]::Run()

Write-Output "===== 任务栏区域（Y>=1019）可见窗口按 Z 序从顶到底 ====="
$i = 0
foreach ($line in [ZOrderCheck]::Results) {
    Write-Output "[$i] $line"
    $i++
}