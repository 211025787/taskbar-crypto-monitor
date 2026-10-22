# 胶囊看门狗恢复速度精确诊断：压制后立即高频检测（无 sleep 冷启动）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts/diag-flicker.ps1
$sw = [System.Diagnostics.Stopwatch]::StartNew()
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class W32D2 {
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint flags);
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
    public static bool IsAbove(IntPtr higher, IntPtr lower) {
        IntPtr cur = lower;
        for (int i = 0; i < 512; i++) {
            cur = GetWindow(cur, 3);
            if (cur == IntPtr.Zero) return false;
            if (cur == higher) return true;
        }
        return false;
    }
}
"@
Add-Type -Namespace R2 -Name T -MemberDefinition @"
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
"@
$tray = [R2.T]::FindWindowW("Shell_TrayWnd", $null)
[W32D2]::Find("Taskbar Crypto Monitor")
$capsule = [W32D2]::Hit
if ($tray -eq [IntPtr]::Zero -or $capsule -eq [IntPtr]::Zero) { Write-Output "DIAG FAIL: 窗口未找到"; exit 1 }

# 连续 3 轮压制测试：每轮压制后立即连续读 z 序（无间隔），记录观测到"被压"的次数与最后恢复时刻
$totalPressed = 0
$lastRecoverMs = 0.0
$everSawPressed = $false
for ($round = 1; $round -le 3; $round++) {
    $ok = [W32D2]::SetWindowPos($capsule, $tray, 0, 0, 0, 0, 0x13)
    if (-not $ok) { Write-Output "DIAG FAIL: 压制失败"; exit 1 }
    $sw.Restart()
    $sawPressed = $false
    while ($sw.ElapsedMilliseconds -lt 3000) {
        $isBelow = [W32D2]::IsAbove($tray, $capsule)
        if ($isBelow) { $sawPressed = $true; $totalPressed++ } else { break }
    }
    if ($sawPressed) {
        $everSawPressed = $true
        $lastRecoverMs = $sw.ElapsedMilliseconds
        Write-Output ("DIAG round {0}: 观测到被压 {1} 次采样后恢复，耗时 {2}ms" -f $round, $totalPressed, $lastRecoverMs)
    } else {
        Write-Output ("DIAG round {0}: 首次采样已恢复（<1ms 级，看门狗即时拉回）" -f $round)
    }
    Start-Sleep -Milliseconds 300
}
if (-not $everSawPressed) {
    Write-Output "DIAG RESULT: 3 轮压制均被即时恢复（<1ms 采样粒度）——事件驱动看门狗工作正常且极快"
}