# 实验：移动胶囊到屏幕中央测试可见性 + 窗口树/区域/命中测试取证
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CenterTest {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int max);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT pt);

    [DllImport("user32.dll")]
    public static extern int GetWindowRgn(IntPtr hWnd, IntPtr hRgn);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRectRgn(int x1, int y1, int x2, int y2);

    [DllImport("gdi32.dll")]
    public static extern int GetRgnBox(IntPtr hRgn, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }
}
'@

$capsule = [CenterTest]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
if ($capsule -eq [IntPtr]::Zero) { Write-Output "FATAL: 胶囊未找到"; exit 1 }

function Count-RedAt([int]$x, [int]$y, [int]$cw, [int]$ch) {
    $bmp = New-Object System.Drawing.Bitmap($cw, $ch)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($cw, $ch)))
    $g.Dispose()
    $red = 0
    for ($ix = 0; $ix -lt $cw; $ix += 2) {
        for ($iy = 0; $iy -lt $ch; $iy += 2) {
            $p = $bmp.GetPixel($ix, $iy)
            if ($p.R -gt 200 -and $p.G -lt 80 -and $p.B -lt 80) { $red++ }
        }
    }
    $bmp.Dispose()
    return $red
}

# --- 1. 屏幕中央测试 ---
$origRect = New-Object CenterTest+RECT
[void][CenterTest]::GetWindowRect($capsule, [ref]$origRect)
$w = $origRect.Right - $origRect.Left; $h = $origRect.Bottom - $origRect.Top
Write-Output ("原始位置=({0},{1}) {2}x{3}" -f $origRect.Left, $origRect.Top, $w, $h)

# HWND_TOPMOST=-1; SWP_NOACTIVATE=0x10 SWP_SHOWWINDOW=0x40
[void][CenterTest]::SetWindowPos($capsule, [IntPtr](-1), 600, 400, $w, $h, 0x10 -bor 0x40)
Start-Sleep -Milliseconds 1000
$newRect = New-Object CenterTest+RECT
[void][CenterTest]::GetWindowRect($capsule, [ref]$newRect)
Write-Output ("中央位置=({0},{1})" -f $newRect.Left, $newRect.Top)
$redCenter = Count-RedAt $newRect.Left $newRect.Top $w $h
Write-Output "屏幕中央红色采样: $redCenter"
if ($redCenter -gt 100) { Write-Output "CENTER_VERDICT: 现形！问题与任务栏区域相关" }
else { Write-Output "CENTER_VERDICT: 中央也不可见，窗口自身合成问题" }

# --- 2. 命中测试：中央位置中心点属于谁 ---
$pt = New-Object CenterTest+POINT
$pt.X = $newRect.Left + [int]($w/2); $pt.Y = $newRect.Top + [int]($h/2)
$hit = [CenterTest]::WindowFromPoint($pt)
$sb = New-Object System.Text.StringBuilder 256
[void][CenterTest]::GetClassNameW($hit, $sb, 256)
Write-Output ("WindowFromPoint(中心)={0} class={1} (胶囊={2})" -f $hit, $sb.ToString(), ($hit -eq $capsule))

# --- 3. 窗口区域检查 ---
$rgn = [CenterTest]::CreateRectRgn(0, 0, 0, 0)
$rgnType = [CenterTest]::GetWindowRgn($capsule, $rgn)
Write-Output ("GetWindowRgn 返回={0} (0=ERROR 无区域 1=NULLREGION 2=SimplEREGION)" -f $rgnType)

# --- 4. 窗口树（父+子链）---
Write-Output "--- 窗口树 ---"
$node = $capsule
$depth = 0
while ($node -ne [IntPtr]::Zero -and $depth -lt 5) {
    $sb2 = New-Object System.Text.StringBuilder 256
    [void][CenterTest]::GetClassNameW($node, $sb2, 256)
    $style = [CenterTest]::GetWindowLong($node, -16)
    $ex = [CenterTest]::GetWindowLong($node, -20)
    $r = New-Object CenterTest+RECT
    [void][CenterTest]::GetWindowRect($node, [ref]$r)
    Write-Output ("[{0}] hwnd={1} class={2} style=0x{3:X8} ex=0x{4:X8} rect=({5},{6})-({7},{8})" -f $depth, $node, $sb2.ToString(), $style, $ex, $r.Left, $r.Top, $r.Right, $r.Bottom)
    $node = [CenterTest]::GetWindow($node, 5)  # GW_CHILD = 5
    $depth++
}

# --- 5. 移回任务栏原位 ---
[void][CenterTest]::SetWindowPos($capsule, [IntPtr](-1), $origRect.Left, $origRect.Top, $w, $h, 0x10 -bor 0x40)
Write-Output "已移回任务栏原位"