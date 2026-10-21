# 首页窗口实机自测工具箱（Win32 自动化：PrintWindow 截图 + SendInput 点击 + WM_CHAR 输入）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\selftest.ps1 <Action> [Window] [Arg1] [Arg2]
# Action: launch | dblclick-capsule | shot | click | type | close | rect | alive
param(
    [Parameter(Mandatory = $true)][string]$Action,
    [string]$Window = "home",
    [string]$Arg1,
    [string]$Arg2
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

# 窗口标题映射（避免命令行传中文参数的编码问题）
$Titles = @{
    capsule  = "Taskbar Crypto Monitor"
    settings = "设置 - Taskbar Crypto Monitor"
    home     = "首页 - Taskbar Crypto Monitor"
}
$ExePath = "D:\ipyProject\ai-contract\src-tauri\target\release\taskbar-crypto-monitor.exe"
$ShotDir = "D:\ipyProject\ai-contract\artifacts\selftest"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
    [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dst, int dx, int dy, int w, int ht, IntPtr src, int sx, int sy, uint rop);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public static IntPtr FindByTitle(string title, bool visibleOnly) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            if (sb.ToString() == title && (!visibleOnly || IsWindowVisible(h))) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static IntPtr FirstChild(IntPtr parent) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) { found = h; return false; }, IntPtr.Zero);
        return found;
    }
}
"@

function Get-WinRect([IntPtr]$h) {
    $r = New-Object W32+RECT
    [W32]::GetWindowRect($h, [ref]$r) | Out-Null
    return $r
}

function Wait-Window([string]$title, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $h = [W32]::FindByTitle($title, $true)
        if ($h -ne [IntPtr]::Zero) { return $h }
        Start-Sleep -Milliseconds 200
    }
    return [W32]::FindByTitle($title, $true)
}

function Save-Shot([IntPtr]$h, [string]$name) {
    $r = Get-WinRect $h
    $w = $r.Right - $r.Left
    $ht = $r.Bottom - $r.Top
    if ($w -le 0 -or $ht -le 0) { throw "窗口尺寸异常: $w x $ht" }
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [W32]::PrintWindow($h, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc)
    $g.Dispose()
    $path = Join-Path $ShotDir $name
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output ("SHOT {0} {1}x{2}" -f $path, $w, $ht)
}

function Send-Click([IntPtr]$h, [double]$fx, [double]$fy) {
    [W32]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 200
    $r = Get-WinRect $h
    $x = [int]($r.Left + ($r.Right - $r.Left) * $fx)
    $y = [int]($r.Top + ($r.Bottom - $r.Top) * $fy)
    [W32]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 150
    [W32]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [W32]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    Write-Output ("CLICK {0},{1}" -f $x, $y)
}

function Send-Type([IntPtr]$h, [string]$text) {
    $child = [W32]::FirstChild($h)
    if ($child -eq [IntPtr]::Zero) { $child = $h }
    foreach ($ch in $text.ToCharArray()) {
        [W32]::PostMessage($child, 0x0102, [IntPtr][int][char]$ch, [IntPtr]::Zero) | Out-Null
        Start-Sleep -Milliseconds 40
    }
    Write-Output ("TYPED '{0}' -> child 0x{1:X}" -f $text, $child.ToInt64())
}

New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null

switch ($Action) {
    "launch" {
        Get-Process taskbar-crypto-monitor -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 800
        Start-Process $ExePath
        $h = Wait-Window $Titles["capsule"] 20
        if ($h -eq [IntPtr]::Zero) { throw "胶囊窗口未出现" }
        Start-Sleep -Seconds 2
        $r = Get-WinRect $h
        Write-Output ("CAPSULE 0x{0:X} rect={1},{2},{3},{4}" -f $h.ToInt64(), $r.Left, $r.Top, $r.Right, $r.Bottom)
    }
    "dblclick-capsule" {
        $h = Wait-Window $Titles["capsule"] 10
        if ($h -eq [IntPtr]::Zero) { throw "胶囊窗口未找到" }
        $r = Get-WinRect $h
        $w = $r.Right - $r.Left
        $ht = $r.Bottom - $r.Top
        # 胶囊为全透明底：仅文字/曲线像素可命中。PrintWindow 扫描 alpha>240 的核心像素取中位点击
        $bmp = New-Object System.Drawing.Bitmap $w, $ht
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        [W32]::PrintWindow($h, $hdc, 2) | Out-Null
        $g.ReleaseHdc($hdc)
        $g.Dispose()
        $pts = New-Object System.Collections.Generic.List[string]
        for ($y = 0; $y -lt $ht; $y++) {
            for ($x = 0; $x -lt $w; $x++) {
                if ($bmp.GetPixel($x, $y).A -gt 240) { $pts.Add("$x,$y") }
            }
        }
        $bmp.Dispose()
        if ($pts.Count -eq 0) { throw "胶囊无可命中像素（可能处于隐藏态或未渲染）" }
        $mid = $pts[[int]($pts.Count / 2)] -split ","
        $x = $r.Left + [int]$mid[0]
        $y = $r.Top + [int]$mid[1]
        [W32]::SetCursorPos($x, $y) | Out-Null
        Start-Sleep -Milliseconds 300
        [W32]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
        [W32]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 100
        [W32]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
        [W32]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 400
        $homeWin = Wait-Window $Titles["home"] 8
        if ($homeWin -eq [IntPtr]::Zero) { Write-Output "HOME NOT FOUND" } else { Write-Output ("HOME 0x{0:X} (click at {1},{2}, opaquePts={3})" -f $homeWin.ToInt64(), $x, $y, $pts.Count) }
    }
    "shot" {
        $h = Wait-Window $Titles[$Window] 10
        if ($h -eq [IntPtr]::Zero) { throw "窗口未找到: $Window" }
        Save-Shot $h $Arg1
    }
    "click" {
        $h = Wait-Window $Titles[$Window] 10
        if ($h -eq [IntPtr]::Zero) { throw "窗口未找到: $Window" }
        Send-Click $h ([double]$Arg1) ([double]$Arg2)
    }
    "type" {
        $h = Wait-Window $Titles[$Window] 10
        if ($h -eq [IntPtr]::Zero) { throw "窗口未找到: $Window" }
        Send-Type $h $Arg1
    }
    "clickclose" {
        $h = Wait-Window $Titles[$Window] 10
        if ($h -eq [IntPtr]::Zero) { throw "窗口未找到: $Window" }
        Send-Click $h 0.978 0.026
        Start-Sleep -Seconds 2
        $vis = [W32]::FindByTitle($Titles[$Window], $true)
        $proc = Get-Process taskbar-crypto-monitor -ErrorAction SilentlyContinue
        Write-Output ("CLICKCLOSE visible={0} procAlive={1}" -f ($vis -ne [IntPtr]::Zero), ($null -ne $proc))
    }
    "close" {
        $h = Wait-Window $Titles[$Window] 10
        if ($h -eq [IntPtr]::Zero) { throw "窗口未找到: $Window" }
        [W32]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        Start-Sleep -Seconds 2
        $vis = [W32]::FindByTitle($Titles[$Window], $true)
        $proc = Get-Process taskbar-crypto-monitor -ErrorAction SilentlyContinue
        Write-Output ("CLOSED visible={0} procAlive={1}" -f ($vis -ne [IntPtr]::Zero), ($null -ne $proc))
    }
    "rect" {
        $h = [W32]::FindByTitle($Titles[$Window], $false)
        if ($h -eq [IntPtr]::Zero) { throw "窗口未找到: $Window" }
        $r = Get-WinRect $h
        Write-Output ("RECT {0},{1},{2},{3}" -f $r.Left, $r.Top, $r.Right, $r.Bottom)
    }
    "stats" {
        $name = if ($Arg1) { $Arg1 } else { $Window }
        $path = Join-Path $ShotDir $name
        if (-not (Test-Path $path)) { throw "截图不存在: $path" }
        $img = [System.Drawing.Image]::FromFile($path)
        $bmp = New-Object System.Drawing.Bitmap $img
        $img.Dispose()
        $histo = @{}
        $lums = New-Object System.Collections.Generic.List[double]
        $green = 0; $red = 0; $gold = 0; $dark = 0; $bright = 0; $opaque = 0
        $a0 = 0; $aLow = 0; $aMid = 0; $aHigh = 0
        $samples = 0
        for ($y = 0; $y -lt $bmp.Height; $y += 2) {
            for ($x = 0; $x -lt $bmp.Width; $x += 2) {
                $c = $bmp.GetPixel($x, $y)
                if ($c.A -gt 0) { $opaque++ }
                if ($c.A -eq 0) { $a0++ } elseif ($c.A -lt 128) { $aLow++ } elseif ($c.A -lt 240) { $aMid++ } else { $aHigh++ }
                $key = "{0:X2}{1:X2}{2:X2}" -f $c.R, $c.G, $c.B
                if ($histo.ContainsKey($key)) { $histo[$key]++ } else { $histo[$key] = 1 }
                $lum = ($c.R + $c.G + $c.B) / 3.0
                $lums.Add($lum)
                if ($lum -gt 200) { $bright++ }
                if ($lum -lt 40) { $dark++ }
                if ([Math]::Abs($c.R - 0x34) -lt 40 -and [Math]::Abs($c.G - 0xD3) -lt 40 -and [Math]::Abs($c.B - 0x99) -lt 40) { $green++ }
                if ([Math]::Abs($c.R - 0xF8) -lt 40 -and [Math]::Abs($c.G - 0x71) -lt 40 -and [Math]::Abs($c.B - 0x71) -lt 40) { $red++ }
                if ([Math]::Abs($c.R - 0xF5) -lt 40 -and [Math]::Abs($c.G - 0xCA) -lt 40 -and [Math]::Abs($c.B - 0x55) -lt 40) { $gold++ }
                $samples++
            }
        }
        $mean = ($lums | Measure-Object -Average).Average
        $std = [Math]::Sqrt((($lums | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Sum).Sum) / $samples)
        $top = $histo.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6 | ForEach-Object { "{0}:{1}%" -f $_.Key, [Math]::Round($_.Value * 100 / $samples, 1) }
        Write-Output ("STATS size={0}x{1} samples={2} unique={3} meanLum={4} stdLum={5}" -f $bmp.Width, $bmp.Height, $samples, $histo.Count, [Math]::Round($mean, 1), [Math]::Round($std, 1))
        Write-Output ("ALPHA a0={0}% aLow={1}% aMid={2}% aHigh={3}%" -f [Math]::Round($a0 * 100 / $samples, 1), [Math]::Round($aLow * 100 / $samples, 1), [Math]::Round($aMid * 100 / $samples, 1), [Math]::Round($aHigh * 100 / $samples, 2))
        Write-Output ("SHARES opaque={0}% bright={1}% dark={2}% green={3}% red={4}% gold={5}%" -f [Math]::Round($opaque * 100 / $samples, 1), [Math]::Round($bright * 100 / $samples, 1), [Math]::Round($dark * 100 / $samples, 1), [Math]::Round($green * 100 / $samples, 2), [Math]::Round($red * 100 / $samples, 2), [Math]::Round($gold * 100 / $samples, 2))
        Write-Output ("TOP {0}" -f ($top -join " "))
        $bmp.Dispose()
    }
    "hit" {
        $h = [W32]::FindByTitle($Titles[$Window], $false)
        if ($h -eq [IntPtr]::Zero) { throw "窗口未找到: $Window" }
        $r = Get-WinRect $h
        $x = [int](($r.Left + $r.Right) / 2)
        $y = [int](($r.Top + $r.Bottom) / 2)
        $pt = New-Object W32+POINT
        $pt.X = $x; $pt.Y = $y
        $target = [W32]::WindowFromPoint($pt)
        $sb = New-Object System.Text.StringBuilder 512
        [W32]::GetWindowText($target, $sb, 512) | Out-Null
        $ok = [W32]::SetCursorPos($x, $y)
        $gp = New-Object W32+POINT
        [W32]::GetCursorPos([ref]$gp) | Out-Null
        Write-Output ("HIT point={0},{1} target=0x{2:X} title='{3}' setpos={4} cursor={5},{6} capsule=0x{7:X}" -f $x, $y, $target.ToInt64(), $sb.ToString(), $ok, $gp.X, $gp.Y, $h.ToInt64())
    }
    "diag" {
        $h = [W32]::FindByTitle($Titles[$Window], $false)
        if ($h -eq [IntPtr]::Zero) { throw "窗口未找到: $Window" }
        $r = Get-WinRect $h
        $ex = [W32]::GetWindowLongPtr($h, -20)
        $layered = ($ex.ToInt64() -band 0x80000) -ne 0
        $transparentEx = ($ex.ToInt64() -band 0x20) -ne 0
        $topmost = ($ex.ToInt64() -band 0x8) -ne 0
        Write-Output ("DIAG hwnd=0x{0:X} rect={1},{2},{3},{4} exStyle=0x{5:X} LAYERED={6} TRANSPARENT={7} TOPMOST={8}" -f $h.ToInt64(), $r.Left, $r.Top, $r.Right, $r.Bottom, $ex.ToInt64(), $layered, $transparentEx, $topmost)
        $kids = New-Object System.Collections.Generic.List[string]
        $cb = [W32+EnumWindowsProc] {
            param($ch, $l)
            $sb2 = New-Object System.Text.StringBuilder 256
            [W32]::GetClassName($ch, $sb2, 256) | Out-Null
            $rr = New-Object W32+RECT
            [W32]::GetWindowRect($ch, [ref]$rr) | Out-Null
            $kids.Add(("{0} 0x{1:X} {2},{3},{4},{5} vis={6}" -f $sb2.ToString(), $ch.ToInt64(), $rr.Left, $rr.Top, $rr.Right, $rr.Bottom, [W32]::IsWindowVisible($ch)))
            return $true
        }
        [W32]::EnumChildWindows($h, $cb, [IntPtr]::Zero) | Out-Null
        $kids | ForEach-Object { Write-Output "CHILD $_" }
        $w = $r.Right - $r.Left
        $ht = $r.Bottom - $r.Top
        $bmp = New-Object System.Drawing.Bitmap $w, $ht
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $gDC = $g.GetHdc()
        $scrDC = [W32]::GetDC([IntPtr]::Zero)
        [W32]::BitBlt($gDC, 0, 0, $w, $ht, $scrDC, $r.Left, $r.Top, 0x00CC0020) | Out-Null
        [W32]::ReleaseDC([IntPtr]::Zero, $scrDC) | Out-Null
        $g.ReleaseHdc($gDC)
        $g.Dispose()
        $path = Join-Path $ShotDir ("diag-screen-" + $Window + ".png")
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Output ("SCREENSHOT {0}" -f $path)
    }
    "movetest" {
        $h = [W32]::FindByTitle($Titles["capsule"], $true)
        if ($h -eq [IntPtr]::Zero) { throw "胶囊窗口未找到" }
        $orig = Get-WinRect $h
        [W32]::SetWindowPos($h, [IntPtr](-1), 600, 300, 0, 0, 0x0001 -bor 0x0010 -bor 0x0040) | Out-Null
        Start-Sleep -Seconds 2
        $r = Get-WinRect $h
        $w = $r.Right - $r.Left
        $ht = $r.Bottom - $r.Top
        $bmp = New-Object System.Drawing.Bitmap $w, $ht
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $gDC = $g.GetHdc()
        $scrDC = [W32]::GetDC([IntPtr]::Zero)
        [W32]::BitBlt($gDC, 0, 0, $w, $ht, $scrDC, $r.Left, $r.Top, 0x00CC0020) | Out-Null
        [W32]::ReleaseDC([IntPtr]::Zero, $scrDC) | Out-Null
        $g.ReleaseHdc($gDC)
        $g.Dispose()
        $path = Join-Path $ShotDir "movetest-screen.png"
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Save-Shot $h "movetest-printwindow.png"
        [W32]::SetWindowPos($h, [IntPtr](-1), $orig.Left, $orig.Top, 0, 0, 0x0001 -bor 0x0010 -bor 0x0040) | Out-Null
        Write-Output ("MOVETEST moved to {0},{1} (screen shot + printwindow saved)" -f $r.Left, $r.Top)
    }
    "postclick" {
        $h = [W32]::FindByTitle($Titles["capsule"], $true)
        if ($h -eq [IntPtr]::Zero) { throw "胶囊窗口未找到" }
        $r = Get-WinRect $h
        # 目标：WebView2 输入子窗口（Chrome_WidgetWin_1）
        $inputHwnd = [IntPtr]::Zero
        $cb2 = [W32+EnumWindowsProc] {
            param($ch, $l)
            $sb3 = New-Object System.Text.StringBuilder 256
            [W32]::GetClassName($ch, $sb3, 256) | Out-Null
            if ($sb3.ToString() -eq "Chrome_WidgetWin_1" -and $inputHwnd -eq [IntPtr]::Zero) { $script:inputHwnd = $ch }
            return $true
        }
        [W32]::EnumChildWindows($h, $cb2, [IntPtr]::Zero) | Out-Null
        if ($inputHwnd -eq [IntPtr]::Zero) { throw "未找到 Chrome_WidgetWin_1" }
        $x = [int](($r.Right - $r.Left) / 2)
        $y = [int](($r.Bottom - $r.Top) / 2)
        $lparam = [IntPtr](($y -shl 16) -bor $x)
        $clicks = if ($Arg1 -eq "double") { 2 } else { 1 }
        for ($i = 0; $i -lt $clicks; $i++) {
            [W32]::PostMessage($inputHwnd, 0x0201, [IntPtr][int]1, $lparam) | Out-Null
            Start-Sleep -Milliseconds 40
            [W32]::PostMessage($inputHwnd, 0x0202, [IntPtr][int]0, $lparam) | Out-Null
            if ($clicks -eq 2) { Start-Sleep -Milliseconds 100 }
        }
        Write-Output ("POSTCLICK clicks={0} at {1},{2} -> Chrome_WidgetWin_1 0x{3:X}" -f $clicks, $x, $y, $inputHwnd.ToInt64())
    }
    "fg" {
        $h = [W32]::GetForegroundWindow()
        $sb = New-Object System.Text.StringBuilder 256
        [W32]::GetWindowText($h, $sb, 256) | Out-Null
        $r = Get-WinRect $h
        Write-Output ("FG 0x{0:X} title='{1}' rect={2},{3},{4},{5}" -f $h.ToInt64(), $sb.ToString(), $r.Left, $r.Top, $r.Right, $r.Bottom)
    }
    "isvis" {
        $h = [W32]::FindByTitle($Titles[$Window], $false)
        if ($h -eq [IntPtr]::Zero) { Write-Output "ISVIS notfound" } else { Write-Output ("ISVIS {0}" -f [W32]::IsWindowVisible($h)) }
    }
    "hidewin" {
        $h = [W32]::FindByTitle($Titles[$Window], $false)
        if ($h -eq [IntPtr]::Zero) { throw "窗口未找到: $Window" }
        [W32]::ShowWindow($h, 0) | Out-Null
        Start-Sleep -Seconds 1
        Write-Output ("HIDEWIN visible={0}" -f [W32]::IsWindowVisible($h))
    }
    "showwin" {
        $h = [W32]::FindByTitle($Titles[$Window], $false)
        if ($h -eq [IntPtr]::Zero) { throw "窗口未找到: $Window" }
        [W32]::ShowWindow($h, 5) | Out-Null
        [W32]::SetForegroundWindow($h) | Out-Null
        Start-Sleep -Seconds 3
        $vis = [W32]::IsWindowVisible($h)
        Write-Output ("SHOWWIN visible={0}" -f $vis)
    }
    "diff" {
        $p1 = Join-Path $ShotDir $Arg1
        $p2 = Join-Path $ShotDir $Arg2
        $i1 = [System.Drawing.Image]::FromFile($p1)
        $b1 = New-Object System.Drawing.Bitmap $i1
        $i1.Dispose()
        $i2 = [System.Drawing.Image]::FromFile($p2)
        $b2 = New-Object System.Drawing.Bitmap $i2
        $i2.Dispose()
        if ($b1.Width -ne $b2.Width -or $b1.Height -ne $b2.Height) { throw "尺寸不一致" }
        $diff = 0
        $total = 0
        for ($y = 0; $y -lt $b1.Height; $y++) {
            for ($x = 0; $x -lt $b1.Width; $x++) {
                $c1 = $b1.GetPixel($x, $y)
                $c2 = $b2.GetPixel($x, $y)
                if ($c1.R -ne $c2.R -or $c1.G -ne $c2.G -or $c1.B -ne $c2.B) { $diff++ }
                $total++
            }
        }
        Write-Output ("DIFF {0}/{1} = {2}%" -f $diff, $total, [Math]::Round($diff * 100 / $total, 3))
        $b1.Dispose()
        $b2.Dispose()
    }
    "alive" {
        $proc = Get-Process taskbar-crypto-monitor -ErrorAction SilentlyContinue
        Write-Output ("ALIVE {0}" -f ($null -ne $proc))
    }
    default { throw "未知动作: $Action" }
}