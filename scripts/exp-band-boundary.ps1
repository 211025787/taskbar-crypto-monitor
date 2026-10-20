# 精确刻画底部不可见条带：设置窗口放 y=700（与任务栏部分重叠），按 10px 行带分析亮度
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class BandTest {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$settings = [BandTest]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
if ($settings -eq [IntPtr]::Zero) { Write-Output "FATAL: 设置窗口未找到"; exit 1 }

# 放到 (300,700)：窗口主体 700..1227，屏幕内可见 700..1066（950~1018 桌面区 + 1019~1066 任务栏区）
[void][BandTest]::SetWindowPos($settings, [IntPtr](-1), 300, 700, 0, 0, 0x10 -bor 0x1)
Start-Sleep -Milliseconds 800

# 捕获整个底部区域 (300,700)-(684,1066)
$bmp = New-Object System.Drawing.Bitmap(384, 366)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(300, 700, 0, 0, (New-Object System.Drawing.Size(384, 366)))
$g.Dispose()
$bmp.Save("D:\ipyProject\ai-contract\docs\screenshots\diag-band-analysis.png", [System.Drawing.Imaging.ImageFormat]::Png)

# 按 10px 行带统计平均亮度
Write-Output "行带亮度分布（y=700..1066，每带10px，设置窗口浅色内容应高亮）："
for ($band = 0; $band -lt 36; $band++) {
    $y0 = $band * 10
    $sum = 0; $n = 0
    for ($x = 0; $x -lt 384; $x += 6) {
        for ($y = $y0; $y -lt ($y0 + 10); $y += 3) {
            $p = $bmp.GetPixel($x, $y)
            $sum += ($p.R + $p.G + $p.B); $n++
        }
    }
    $avg = [Math]::Round($sum / $n)
    $bar = "#" * [Math]::Min(60, [int]($avg / 12))
    Write-Output ("y={0}-{1}: avg={2} {3}" -f (700 + $y0), (700 + $y0 + 9), $avg, $bar)
}
$bmp.Dispose()

# 恢复
[void][BandTest]::SetWindowPos($settings, [IntPtr](-1), 656, 244, 0, 0, 0x10 -bor 0x1)
Write-Output "设置窗口已移回原位"