# 对照实验：显示设置窗口（不透明 WebView2 窗口）验证屏幕合成是否正常
# 设置可见 → 胶囊透明配置是问题；设置也不可见 → 系统 WebView2/DComp 合成问题
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class SettingsTest {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int max);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$settings = [SettingsTest]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
if ($settings -eq [IntPtr]::Zero) { Write-Output "FATAL: 设置窗口未找到"; exit 1 }

$rect = New-Object SettingsTest+RECT
[void][SettingsTest]::GetWindowRect($settings, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
Write-Output ("设置窗口 hwnd={0} rect=({1},{2})-({3},{4}) {5}x{6}" -f $settings, $rect.Left, $rect.Top, $rect.Right, $rect.Bottom, $w, $h)

[void][SettingsTest]::ShowWindow($settings, 5)  # SW_SHOW
[void][SettingsTest]::SetForegroundWindow($settings)
Start-Sleep -Seconds 2

# 屏幕捕获设置窗口区域
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
$g.Dispose()
$bright = 0; $dark = 0; $mid = 0
for ($x = 0; $x -lt $w; $x += 3) {
    for ($y = 0; $y -lt $h; $y += 3) {
        $p = $bmp.GetPixel($x, $y)
        $s = $p.R + $p.G + $p.B
        if ($s -gt 300) { $bright++ } elseif ($s -lt 90) { $dark++ } else { $mid++ }
    }
}
$bmp.Save("D:\ipyProject\ai-contract\docs\screenshots\diag-settings-on-screen.png", [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ("设置窗口屏幕捕获: 高亮={0} 中间调={1} 暗={2}" -f $bright, $mid, $dark)
if ($bright -gt 500) { Write-Output "SETTINGS_VERDICT: PASS - 设置窗口在屏幕上正常渲染（WebView2 合成正常）" }
else { Write-Output "SETTINGS_VERDICT: FAIL - 设置窗口也不可见（系统级合成问题）" }

# --- 附：Z 序最顶层窗口列表（前 12 个）---
Write-Output "--- Z 序顶部窗口 ---"
$cur = [SettingsTest]::GetWindow([IntPtr]::Zero, 0)  # GetDesktopWindow
$cur = [SettingsTest]::GetWindow($cur, 5)  # GW_CHILD = Z 序最高
$i = 0
while ($cur -ne [IntPtr]::Zero -and $i -lt 12) {
    $sb = New-Object System.Text.StringBuilder 256
    [void][SettingsTest]::GetClassNameW($cur, $sb, 256)
    $ex = [SettingsTest]::GetWindowLong($cur, -20)
    $r = New-Object SettingsTest+RECT
    [void][SettingsTest]::GetWindowRect($cur, [ref]$r)
    Write-Output ("{0}: class={1} ex=0x{2:X8} rect=({3},{4})-({5},{6})" -f $i, $sb.ToString(), $ex, $r.Left, $r.Top, $r.Right, $r.Bottom)
    $cur = [SettingsTest]::GetWindow($cur, 2)  # GW_HWNDNEXT
    $i++
}