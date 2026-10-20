# 探测窗口 AUMID（IPropertyStore + PKEY_AppUserModel_ID）+ 查 Explorer 图标缓存注册表
Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Aumid {
    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit)]
    public struct PROPVARIANT {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDA1AADDCD93"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        uint GetCount();
        void GetAt(uint i, ref PROPERTYKEY pkey);
        void GetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, out IPropertyStore ps);

    public static string GetWindowAumid(IntPtr hwnd) {
        Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDA1AADDCD93");
        IPropertyStore ps;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref iid, out ps);
        if (hr != 0) return "HR=0x" + hr.ToString("X");
        try {
            PROPERTYKEY key = new PROPERTYKEY();
            key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE4D4E0");
            key.pid = 5;
            PROPVARIANT pv = new PROPVARIANT();
            ps.GetValue(ref key, ref pv);
            if (pv.vt == 31 && pv.pointerValue != IntPtr.Zero) {
                return Marshal.PtrToStringUni(pv.pointerValue);
            }
            return "VT=" + pv.vt;
        } finally { Marshal.ReleaseComObject(ps); }
    }
}
"@
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PW3 {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder sb, int max);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lp);
}
"@
$out = @()
$targetPid = (Get-Process "taskbar-crypto-monitor" -ErrorAction Stop).Id
$out += "目标进程 PID: $targetPid"
$cb = {
    param($h, $lp)
    $wpid = 0
    [PW3]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
    if ($wpid -eq $script:targetPid) {
        $sb = New-Object System.Text.StringBuilder 256
        [PW3]::GetWindowTextW($h, $sb, 256) | Out-Null
        $title = $sb.ToString()
        $cb2 = New-Object System.Text.StringBuilder 256
        [PW3]::GetClassNameW($h, $cb2, 256) | Out-Null
        $cls = $cb2.ToString()
        if ($title -or $cls -notmatch "^Windows\.") {
            $aumid = [Aumid]::GetWindowAumid($h)
            $script:out += "窗口 hwnd=$h 类='$cls' 标题='$title' AUMID='$aumid'"
        }
    }
    return $true
}
$out2 = @()
$script:out = $out2
[PW3]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
$out += $script:out

# 注册表缓存检查
$out += "--- Taskband 注册表 ---"
$tb = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" -ErrorAction SilentlyContinue
if ($tb) { $out += "Taskband 键存在，值: " + (($tb.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" } | ForEach-Object { $_.Name }) -join ", ") }
$tic = Get-ChildItem "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\TrayIconCache" -ErrorAction SilentlyContinue
$out += "TrayIconCache 子键数: $(($tic | Measure-Object).Count)"
foreach ($k in $tic) {
    $name = $k.PSChildName
    $vals = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
    $size = 0
    if ($vals.IconStream) { $size = $vals.IconStream.Length }
    $out += "  '$name' IconStream=$size 字节"
}
# 快捷方式检查
$out += "--- 快捷方式 ---"
$lnks = @(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Taskbar Crypto Monitor.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Taskbar Crypto Monitor\Taskbar Crypto Monitor.lnk",
    "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Taskbar Crypto Monitor.lnk"
)
foreach ($l in $lnks) { $out += "  $(Test-Path $l) : $l" }
$out | Out-File "D:\ipyProject\ai-contract\.aumid.txt" -Encoding utf8