# 取证 LockScreenBackstopFrame：根父窗口链、样式、可见性、cloak 状态
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class LbfDiag {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByClass(string className, IntPtr windowName);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder sb, int max);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int max);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int val, int size);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$lbf = [LbfDiag]::FindWindowByClass("LockScreenBackstopFrame", [IntPtr]::Zero)
if ($lbf -eq [IntPtr]::Zero) { Write-Output "LockScreenBackstopFrame 未找到"; exit 0 }

function Dump([IntPtr]$h, [string]$label) {
    $sb = New-Object System.Text.StringBuilder 256
    [void][LbfDiag]::GetClassNameW($h, $sb, 256)
    $sbT = New-Object System.Text.StringBuilder 256
    [void][LbfDiag]::GetWindowTextW($h, $sbT, 256)
    $style = [LbfDiag]::GetWindowLong($h, -16)
    $ex = [LbfDiag]::GetWindowLong($h, -20)
    $vis = [LbfDiag]::IsWindowVisible($h)
    $r = New-Object LbfDiag+RECT
    [void][LbfDiag]::GetWindowRect($h, [ref]$r)
    $cloaked = 0
    [void][LbfDiag]::DwmGetWindowAttribute($h, 14, [ref]$cloaked, 4)
    $pid2 = 0
    Write-Output ("{0}: hwnd={1} class={2} title='{3}' style=0x{4:X8} ex=0x{5:X8} visible={6} cloaked={7} rect=({8},{9})-({10},{11})" -f $label, $h, $sb.ToString(), $sbT.ToString(), $style, $ex, $vis, $cloaked, $r.Left, $r.Top, $r.Right, $r.Bottom)
}

Dump $lbf "LBF 自身"
# GA_PARENT=1 GA_ROOT=2 GA_ROOTOWNER=3
$root = [LbfDiag]::GetAncestor($lbf, 2)
Dump $root "LBF 根(GA_ROOT)"
$rootOwner = [LbfDiag]::GetAncestor($lbf, 3)
if ($rootOwner -ne $root) { Dump $rootOwner "LBF 根属主(GA_ROOTOWNER)" }
$parent = [LbfDiag]::GetParent($lbf)
if ($parent -ne [IntPtr]::Zero) { Dump $parent "LBF 父(GetParent)" }