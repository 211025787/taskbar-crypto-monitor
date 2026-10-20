# 原型验证脚本：客观验证胶囊窗口已覆盖在任务栏上
# 验证项：
#   V1 胶囊窗口与 Shell_TrayWnd（任务栏）矩形重叠
#   V2 任务栏区域顶点命中测试返回胶囊窗口（Z 序在其上方）
#   V3 胶囊窗口具备 TOPMOST 置顶属性
#   V4 截图像素采样：胶囊区域呈现深色玻璃底色（而非任务栏本色）
Add-Type -AssemblyName System.Drawing

$signature = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Win32Verify {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByClass(string className, IntPtr windowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindowByTitle(IntPtr className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT pt);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int index);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }
}
'@
Add-Type -TypeDefinition $signature

$WS_EX_TOPMOST = 0x8
$results = @()

# 定位任务栏与胶囊窗口
$tray = [Win32Verify]::FindWindowByClass("Shell_TrayWnd", [IntPtr]::Zero)
$capsule = [Win32Verify]::FindWindowByTitle([IntPtr]::Zero, "Taskbar Crypto Monitor")

if ($tray -eq [IntPtr]::Zero -or $capsule -eq [IntPtr]::Zero) {
    Write-Output "FATAL: 窗口未找到 tray=$tray capsule=$capsule"
    exit 1
}

$trayRect = New-Object Win32Verify+RECT
$capsuleRect = New-Object Win32Verify+RECT
[void][Win32Verify]::GetWindowRect($tray, [ref]$trayRect)
[void][Win32Verify]::GetWindowRect($capsule, [ref]$capsuleRect)

Write-Output "任务栏矩形: L=$($trayRect.Left) T=$($trayRect.Top) R=$($trayRect.Right) B=$($trayRect.Bottom) (H=$($trayRect.Bottom - $trayRect.Top))"
Write-Output "胶囊矩形:   L=$($capsuleRect.Left) T=$($capsuleRect.Top) R=$($capsuleRect.Right) B=$($capsuleRect.Bottom) (H=$($capsuleRect.Bottom - $capsuleRect.Top))"

# V1 矩形重叠检测
$overlapX = [Math]::Min($trayRect.Right, $capsuleRect.Right) - [Math]::Max($trayRect.Left, $capsuleRect.Left)
$overlapY = [Math]::Min($trayRect.Bottom, $capsuleRect.Bottom) - [Math]::Max($trayRect.Top, $capsuleRect.Top)
$v1 = ($overlapX -gt 0) -and ($overlapY -gt 0)
$results += "V1 矩形重叠(宽=$overlapX 高=$overlapY): $(if ($v1) {'PASS'} else {'FAIL'})"

# V2 任务栏内中心点命中测试：命中的窗口（含 WebView 子窗口）应属于本应用进程
$probeX = [int](($capsuleRect.Left + $capsuleRect.Right) / 2)
$probeY = [int](($capsuleRect.Top + $capsuleRect.Bottom) / 2)
$pt = New-Object Win32Verify+POINT
$pt.X = $probeX; $pt.Y = $probeY
$hit = [Win32Verify]::WindowFromPoint($pt)
$hitPid = 0
[void][Win32Verify]::GetWindowThreadProcessId($hit, [ref]$hitPid)
$ourPid = (Get-Process taskbar-crypto-monitor).Id
$v2 = ($hitPid -eq $ourPid)
$results += "V2 顶点($probeX,$probeY)命中窗口(PID=$hitPid)属于本应用(PID=$ourPid): $(if ($v2) {'PASS'} else {'FAIL'})"

# V3 TOPMOST 属性检测
$exStyle = [Win32Verify]::GetWindowLong($capsule, -20)
$v3 = (($exStyle -band $WS_EX_TOPMOST) -ne 0)
$results += "V3 TOPMOST 置顶属性: $(if ($v3) {'PASS'} else {'FAIL'})"

# V4 截图像素采样：胶囊中心应显著深于任务栏本色（玻璃深色底）
$img = [System.Drawing.Image]::FromFile("D:\ipyProject\ai-contract\docs\screenshots\prototype-taskbar-area.png")
# 截图顶边对应屏幕 Y = 任务栏底边 - 300（截图脚本以屏幕底部 300px 为窗口）
$sx = $probeX
$sy = $probeY - ($trayRect.Bottom - 300)
if ($sx -ge 0 -and $sx -lt $img.Width -and $sy -ge 0 -and $sy -lt $img.Height) {
    $px = $img.GetPixel($sx, $sy)
    $brightness = ($px.R + $px.G + $px.B) / 3
    $results += "V4 胶囊中心像素 RGB=($($px.R),$($px.G),$($px.B)) 亮度=$([Math]::Round($brightness,1)): $(if ($brightness -lt 80) {'PASS(深色玻璃底)'} else {'WARN(偏亮，可能为浅色主题任务栏)'})"
} else {
    $results += "V4 像素采样越界 sx=$sx sy=$sy"
}
$img.Dispose()

Write-Output ""
Write-Output "===== 验证结果汇总 ====="
$results | ForEach-Object { Write-Output $_ }