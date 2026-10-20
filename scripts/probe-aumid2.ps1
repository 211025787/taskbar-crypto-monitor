# 修正版 AUMID 探测：窗口 IPropertyStore（修正 vtable 签名）+ 开始菜单 lnk 的 AUMID
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Aumid2 {
    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit)]
    public struct PROPVARIANT {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDA1AADDCD93"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        void GetCount(out uint cProps);
        void GetAt(uint i, out PROPERTYKEY pkey);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, out IPropertyStore ps);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr pbc, uint flags, ref Guid iid, out IPropertyStore ps);

    public static string ReadAumid(IPropertyStore ps) {
        try {
            PROPERTYKEY key = new PROPERTYKEY();
            key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE4D4E0");
            key.pid = 5;
            PROPVARIANT pv;
            ps.GetValue(ref key, out pv);
            if (pv.vt == 31 && pv.pointerValue != IntPtr.Zero) {
                return Marshal.PtrToStringUni(pv.pointerValue);
            }
            return "VT=" + pv.vt + "(空)";
        } catch (Exception e) { return "ERR:" + e.Message; }
    }

    public static string GetWindowAumid(IntPtr hwnd) {
        Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDA1AADDCD93");
        IPropertyStore ps;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref iid, out ps);
        if (hr != 0) return "HR=0x" + hr.ToString("X");
        try { return ReadAumid(ps); }
        finally { Marshal.ReleaseComObject(ps); }
    }

    public static string GetFileAumid(string path) {
        Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDA1AADDCD93");
        IPropertyStore ps;
        int hr = SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 0, ref iid, out ps);
        if (hr != 0) return "HR=0x" + hr.ToString("X");
        try { return ReadAumid(ps); }
        finally { Marshal.ReleaseComObject(ps); }
    }
}
"@
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PW4 {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lp);
}
"@
$out = @()
$proc = Get-Process "taskbar-crypto-monitor" -ErrorAction Stop
$targetPid = $proc.Id
$out += "PID: $targetPid"
$script:out = $out
$cb = {
    param($h, $lp)
    $wpid = [uint32]0
    [PW4]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
    if ($wpid -eq $script:targetPid) {
        $sb = New-Object System.Text.StringBuilder 256
        [PW4]::GetWindowTextW($h, $sb, 256) | Out-Null
        $title = $sb.ToString()
        $cb2 = New-Object System.Text.StringBuilder 256
        [PW4]::GetClassNameW($h, $cb2, 256) | Out-Null
        $cls = $cb2.ToString()
        $vis = [PW4]::IsWindowVisible($h)
        $aumid = [Aumid2]::GetWindowAumid($h)
        $script:out += "hwnd=$h 可见=$vis 类='$cls' 标题='$title' AUMID='$aumid'"
    }
    return $true
}
[PW4]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
$out = $script:out
$out += "--- lnk AUMID ---"
$out += "开始菜单 lnk: " + [Aumid2]::GetFileAumid("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Taskbar Crypto Monitor.lnk")
# AppID 注册表
$out += "--- HKCU AppID 注册表 ---"
$apid = Get-ChildItem "HKCU:\Software\Classes\AppID" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "taskbar|crypto" }
if ($apid) { foreach ($a in $apid) { $out += "  AppID 键: $($a.PSChildName)" } } else { $out += "  无 taskbar/crypto 相关 AppID 键" }
$out | Out-File "D:\ipyProject\ai-contract\.aumid2.txt" -Encoding utf8