# 枚举应用窗口并读取设置窗口的图标位图主色（验证 set_icon 是否生效）
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class IconProbe {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr GetClassLongPtrW(IntPtr hWnd, int nIndex);
}
"@
Add-Type -AssemblyName System.Drawing

$target = (Get-Process -Name taskbar-crypto-monitor).Id
$wins = @()
$cb = {
    param($h, $l)
    $wpid = 0
    [IconProbe]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
    if ($wpid -eq $target) {
        $sb = New-Object System.Text.StringBuilder 256
        [IconProbe]::GetWindowTextW($h, $sb, 256) | Out-Null
        $script:wins += [pscustomobject]@{ Hwnd = $h; Title = $sb.ToString() }
    }
    return $true
}
[IconProbe]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null

$out = @()
foreach ($w in $wins) {
    $out += "窗口: [$($w.Title)] HWND=$($w.Hwnd)"
    # WM_GETICON: 2=ICON_SMALL2, 0=ICON_SMALL, 1=ICON_BIG；GCL: -14=HICONSM, -12=HICON
    $handles = @(
        @{ Name = "GETICON_SMALL2"; H = [IconProbe]::SendMessageW($w.Hwnd, 0x7F, [IntPtr]2, [IntPtr]::Zero) },
        @{ Name = "GETICON_SMALL";  H = [IconProbe]::SendMessageW($w.Hwnd, 0x7F, [IntPtr]0, [IntPtr]::Zero) },
        @{ Name = "GETICON_BIG";    H = [IconProbe]::SendMessageW($w.Hwnd, 0x7F, [IntPtr]1, [IntPtr]::Zero) },
        @{ Name = "CLASS_HICONSM";  H = [IconProbe]::GetClassLongPtrW($w.Hwnd, -14) },
        @{ Name = "CLASS_HICON";    H = [IconProbe]::GetClassLongPtrW($w.Hwnd, -12) }
    )
    foreach ($item in $handles) {
        if ($item.H -ne [IntPtr]::Zero) {
            try {
                $icon = [System.Drawing.Icon]::FromHandle($item.H)
                $bmp = $icon.ToBitmap()
                # 统计主色：排除完全透明像素
                $blue = 0; $green = 0; $dark = 0; $total = 0
                for ($x = 0; $x -lt $bmp.Width; $x += 2) {
                    for ($y = 0; $y -lt $bmp.Height; $y += 2) {
                        $p = $bmp.GetPixel($x, $y)
                        if ($p.A -gt 200) {
                            $total++
                            if ($p.B -gt $p.R + 20 -and $p.B -gt 50) { $blue++ }
                            if ($p.G -gt $p.B + 30 -and $p.G -gt 140) { $green++ }
                            if (($p.R + $p.G + $p.B) -lt 90) { $dark++ }
                        }
                    }
                }
                $out += "  $($item.Name): $($bmp.Width)x$($bmp.Height) 蓝${blue}/${total} 绿${green}/${total} 暗${dark}/${total}"
            } catch {
                $out += "  $($item.Name): 解析失败 $($_.Exception.Message)"
            }
        } else {
            $out += "  $($item.Name): 0（未设置）"
        }
    }
}
$out | Out-File "D:\ipyProject\ai-contract\.icon-probe.txt" -Encoding utf8