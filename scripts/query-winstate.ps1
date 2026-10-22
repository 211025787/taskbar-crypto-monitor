# 查询 Tauri 窗口的 IsIconic/样式位（诊断 settings 最小化态）
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W32Q {
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public static IntPtr Found = IntPtr.Zero;
    public static bool TitleIs(IntPtr h, string title) {
        var sb = new StringBuilder(512);
        GetWindowText(h, sb, 512);
        return sb.ToString() == title;
    }
}
"@
$title = "设置 - Taskbar Crypto Monitor"
$found = [IntPtr]::Zero
[System.IntPtr]$dummy = 0
Get-Process taskbar-crypto-monitor -ErrorAction SilentlyContinue | ForEach-Object {
    # 用 .NET 枚举所有窗口句柄（通过主窗口句柄与线程窗口）
}
# 直接走 EnumWindows 用 C# 侧静态回调
$code = @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class W32Scan {
    public static IntPtr Hit;
    public static void Scan(string title) {
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            if (sb.ToString() == title) { Hit = h; return false; }
            return true;
        }, IntPtr.Zero);
    }
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
}
"@
Add-Type -TypeDefinition $code
[W32Scan]::Scan($title)
$h = [W32Scan]::Hit
if ($h -eq [IntPtr]::Zero) { Write-Output "NOT FOUND"; exit 1 }
$r = New-Object W32Q+RECT
[W32Q]::GetWindowRect($h, [ref]$r) | Out-Null
Write-Output ("hwnd={0} iconic={1} visible={2} rect={3},{4},{5},{6}" -f $h, [W32Q]::IsIconic($h), [W32Q]::IsWindowVisible($h), $r.L, $r.T, $r.R, $r.B)