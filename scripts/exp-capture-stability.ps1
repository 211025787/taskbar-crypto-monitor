# 捕获稳定性测试：同区域连续 6 次捕获，检测 CopyFromScreen 是否间歇性返回坏帧
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class StabTest {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

$settings = [StabTest]::FindWindowByTitle([IntPtr]::Zero, "设置 - Taskbar Crypto Monitor")
if ($settings -eq [IntPtr]::Zero) { Write-Output "FATAL: 设置窗口未找到"; exit 1 }
$rect = New-Object StabTest+RECT
[void][StabTest]::GetWindowRect($settings, [ref]$rect)
$w = $rect.Right - $rect.Left; $h = $rect.Bottom - $rect.Top
Write-Output ("设置窗口当前 rect=({0},{1}) {2}x{3}" -f $rect.Left, $rect.Top, $w, $h)

# 连续 6 次捕获设置窗口区域，间隔 500ms
$results = @()
for ($i = 0; $i -lt 6; $i++) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    $g.Dispose()
    $b = 0
    for ($x = 0; $x -lt $w; $x += 4) {
        for ($y = 0; $y -lt $h; $y += 4) {
            $p = $bmp.GetPixel($x, $y)
            if (($p.R + $p.G + $p.B) -gt 300) { $b++ }
        }
    }
    $results += $b
    $bmp.Dispose()
    Start-Sleep -Milliseconds 500
}
Write-Output ("6 次捕获高亮采样序列: {0}" -f ($results -join ", "))
$stable = ($results | Measure-Object -Minimum).Maximum - ($results | Measure-Object -Minimum).Minimum
if ((($results | Measure-Object -Average).Average) -gt 1500 -and $stable -lt 800) {
    Write-Output "STAB_VERDICT: 捕获基本稳定，设置窗口持续可见"
} elseif ((($results | Measure-Object -Average).Average) -lt 300) {
    Write-Output "STAB_VERDICT: 设置窗口当前整体不可见（先前可见→状态已漂移）"
} else {
    Write-Output "STAB_VERDICT: 结果剧烈波动，捕获或合成不稳定"
}