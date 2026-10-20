# 用 GetClassLongPtrW 读取当前运行进程窗口的类图标槽位（GCL_HICON / GCL_HICONSM）
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class PW5 {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, System.Text.StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern IntPtr GetClassLongPtrW(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hWnd, uint msg, UIntPtr wp, IntPtr lp);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lp);
}
"@
$out = @()
$targetPid = (Get-Process "taskbar-crypto-monitor" -ErrorAction Stop).Id
$out += "PID: $targetPid"
$script:out = $out
$cb = {
    param($h, $lp)
    $wpid = [uint32]0
    [PW5]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
    if ($wpid -eq $script:targetPid) {
        $sb = New-Object System.Text.StringBuilder 256
        [PW5]::GetWindowTextW($h, $sb, 256) | Out-Null
        $cb2 = New-Object System.Text.StringBuilder 256
        [PW5]::GetClassNameW($h, $cb2, 256) | Out-Null
        # GCL_HICON=-14, GCL_HICONSM=-34；WM_GETICON=0x7F, ICON_BIG=1, ICON_SMALL2=2
        $gclBig = [PW5]::GetClassLongPtrW($h, -14)
        $gclSmall = [PW5]::GetClassLongPtrW($h, -34)
        $getBig = [PW5]::SendMessageW($h, 0x7F, [UIntPtr]::new(1), [IntPtr]::Zero)
        $getSmall2 = [PW5]::SendMessageW($h, 0x7F, [UIntPtr]::new(2), [IntPtr]::Zero)
        $script:out += ("hwnd=$h 类='{0}' 标题='{1}' GCL_HICON=0x{2:X} GCL_HICONSM=0x{3:X} GETICON_BIG=0x{4:X} GETICON_SMALL2=0x{5:X}" -f $cb2.ToString(), $sb.ToString(), $gclBig.ToInt64(), $gclSmall.ToInt64(), $getBig.ToInt64(), $getSmall2.ToInt64())
    }
    return $true
}
[PW5]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
$script:out | Out-File "D:\ipyProject\ai-contract\.classicon.txt" -Encoding utf8