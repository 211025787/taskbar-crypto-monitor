# 闪烁位置对照实验：把胶囊临时挪到屏幕中央（脱离任务栏区域），观察点击任务栏图标是否仍闪
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts/move-capsule-test.ps1 center|restore
param(
    [Parameter(Mandatory = $true)][ValidateSet("center", "restore")][string]$Mode
)
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W32M {
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfoW(uint action, uint param, out RECT pv, uint init);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public static IntPtr Hit;
    public static void Find(string title) {
        Hit = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            if (sb.ToString() == title) { Hit = h; return false; }
            return true;
        }, IntPtr.Zero);
    }
}
"@
# 工作区尺寸（SPI_GETWORKAREA=48）
$work = New-Object W32M+RECT
[W32M]::SystemParametersInfoW(48, 0, [ref]$work, 0) | Out-Null
[W32M]::Find("Taskbar Crypto Monitor")
$capsule = [W32M]::Hit
if ($capsule -eq [IntPtr]::Zero) { Write-Output "MOVE FAIL: 胶囊未找到"; exit 1 }
$rect = New-Object W32M+RECT
[W32M]::GetWindowRect($capsule, [ref]$rect) | Out-Null
$w = $rect.R - $rect.L
$ht = $rect.B - $rect.T
if ($Mode -eq "center") {
    # 屏幕工作区中央（远离任务栏与所有边缘）；flags 仅 NOSIZE(1)|NOACTIVATE(0x10)，不带 NOMOVE 才能真正移动
    $x = $work.L + (($work.R - $work.L - $w) / 2)
    $y = $work.T + (($work.B - $work.T - $ht) / 2)
    [W32M]::SetWindowPos($capsule, [IntPtr](-1), $x, $y, 0, 0, 0x11) | Out-Null
    Write-Output ("MOVE center: 胶囊已挪到屏幕中央 ({0},{1})——请点击任务栏图标观察是否仍闪" -f $x, $y)
} else {
    # 还原到任务栏（由应用的看门狗/重放置逻辑接管；这里仅移回原坐标）
    $x = $rect.L
    $y = $rect.T
    [W32M]::SetWindowPos($capsule, [IntPtr](-1), $x, $y, 0, 0, 0x11) | Out-Null
    Write-Output "MOVE restore: 已触发（实际位置由应用自身逻辑接管，重启应用最稳妥）"
}