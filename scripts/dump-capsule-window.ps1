# 直接抓取胶囊窗口自身渲染内容（PrintWindow），分离 WebView 渲染与 DWM 屏幕合成两类问题
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class CapsuleDump {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$capsule = [CapsuleDump]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")
if ($capsule -eq [IntPtr]::Zero) {
    Write-Output "FATAL: 胶囊窗口未找到（进程可能已退出）"
    exit 1
}

$rect = New-Object CapsuleDump+RECT
[void][CapsuleDump]::GetWindowRect($capsule, [ref]$rect)
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
Write-Output "胶囊窗口: HWND=$capsule RECT=($($rect.Left),$($rect.Top))-($($rect.Right),$($rect.Bottom)) 尺寸 ${w}x${h}"

# PW_RENDERFULLCONTENT = 2：要求 DWM 渲染完整内容（含 DirectComposition/WebView2）
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [CapsuleDump]::PrintWindow($capsule, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()
Write-Output "PrintWindow(PW_RENDERFULLCONTENT): $ok"

$bmp.Save("D:\ipyProject\ai-contract\docs\screenshots\capsule-printwindow.png", [System.Drawing.Imaging.ImageFormat]::Png)

# 采样输出图像的几个点判断是否有内容
$samples = @(
    @(10, [int]($h / 2), "窗口左端"),
    @([int]($w / 2), [int]($h / 2), "窗口中心"),
    @($w - 10, [int]($h / 2), "窗口右端")
)
foreach ($s in $samples) {
    $p = $bmp.GetPixel($s[0], $s[1])
    Write-Output ("{0}({1},{2}): RGB=({3},{4},{5}) A={6}" -f $s[3 - 1], $s[0], $s[1], $p.R, $p.G, $p.B, $p.A)
}
$bmp.Dispose()