# 决定性对照：记事本窗口缩小到 175x44，测屏幕可见性（判定系统级 vs Tauri 级问题）
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class NotepadTest {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string className, string windowName);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@

# 启动记事本
Start-Process notepad.exe
Start-Sleep -Seconds 2

# Win11 记事本类名 Notepad（旧版）或 Windows.UI.Core.CoreWindow？先试主窗口
$notepad = [IntPtr]::Zero
foreach ($cls in @("Notepad", "Windows.UI.Core.CoreWindow")) {
    $notepad = [NotepadTest]::FindWindowW($cls, $null)
    if ($notepad -ne [IntPtr]::Zero) { Write-Output "记事本窗口: class=$cls hwnd=$notepad"; break }
}
if ($notepad -eq [IntPtr]::Zero) { Write-Output "FATAL: 记事本窗口未找到"; exit 1 }

[void][NotepadTest]::SetForegroundWindow($notepad)
Start-Sleep -Milliseconds 500

function Test-Np([int]$cw, [int]$ch, [string]$label) {
    [void][NotepadTest]::SetWindowPos($notepad, [IntPtr](-1), 400, 200, $cw, $ch, 0x10)
    Start-Sleep -Milliseconds 1500
    $r = New-Object NotepadTest+RECT
    [void][NotepadTest]::GetWindowRect($notepad, [ref]$r)
    $rw = $r.Right - $r.Left; $rh = $r.Bottom - $r.Top
    $sc = New-Object System.Drawing.Bitmap($rw, $rh)
    $g = [System.Drawing.Graphics]::FromImage($sc)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($rw, $rh)))
    $g.Dispose()
    $pw = New-Object System.Drawing.Bitmap($rw, $rh)
    $g2 = [System.Drawing.Graphics]::FromImage($pw)
    $hdc = $g2.GetHdc()
    [void][NotepadTest]::PrintWindow($notepad, $hdc, 2)
    $g2.ReleaseHdc($hdc)
    $g2.Dispose()
    $sb = 0; $pb = 0
    for ($x = 0; $x -lt $rw; $x += 3) {
        for ($y = 0; $y -lt $rh; $y += 3) {
            $ps = $sc.GetPixel($x, $y); $pp = $pw.GetPixel($x, $y)
            if (($ps.R + $ps.G + $ps.B) -gt 300) { $sb++ }
            if (($pp.R + $pp.G + $pp.B) -gt 300) { $pb++ }
        }
    }
    $sc.Dispose(); $pw.Dispose()
    $visRatio = if ($pb -gt 0) { [Math]::Round(100.0 * $sb / $pb) } else { -1 }
    $verdict = if ($visRatio -gt 40) { "可见" } else { "不可见" }
    Write-Output ("记事本 {0,-10} 实际{1}x{2} 屏幕亮={3,-5} PW亮={4,-5} 可见率={5}% {6}" -f $label, $rw, $rh, $sb, $pb, $visRatio, $verdict)
}

Test-Np 800 600 "800x600"
Test-Np 384 527 "384x527"
Test-Np 175 44 "175x44"
Test-Np 384 100 "384x100"
Test-Np 300 44 "300x44"

# 关闭记事本（不保存）
Stop-Process -Name "Notepad" -Force -ErrorAction SilentlyContinue
Write-Output "记事本已关闭"