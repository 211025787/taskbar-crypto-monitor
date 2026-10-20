# 用 PrivateExtractIconsW 从 exe 提取各尺寸内嵌图标，转像素统计颜色（验证 exe 资源段是否有黑色档）
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class IconExtract {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern uint PrivateExtractIconsW(string path, int index, int cx, int cy, IntPtr[] hicon, uint[] ids, uint numIcons, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct ICONINFO { public bool fIcon; public uint xHotspot; public uint yHotspot; public IntPtr hbmMask; public IntPtr hbmColor; }

    [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr hIcon, out ICONINFO info);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hgdiobj);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern int GetDIBits(IntPtr hdc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BITMAPINFO bmi, uint usage);

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER { public uint size; public int width; public int height; public ushort planes, bpp; public uint compression, sizeImage; public int xpels, ypels; public uint clrUsed, clrImportant; }
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFO { public BITMAPINFOHEADER header; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1)] public uint[] colors; }

    public static byte[] GetIconPixels(IntPtr hicon, ref int w, ref int h) {
        ICONINFO info;
        if (!GetIconInfo(hicon, out info)) return null;
        IntPtr hdc = CreateCompatibleDC(IntPtr.Zero);
        BITMAPINFO bmi = new BITMAPINFO();
        bmi.header.size = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
        bmi.header.width = 0; bmi.header.height = 0; bmi.header.bpp = 32; bmi.header.compression = 0;
        // 先取尺寸（bits=null 会填充 header）
        GetDIBits(hdc, info.hbmColor, 0, 0, null, ref bmi, 0);
        w = bmi.header.width; h = Math.Abs(bmi.header.height);
        if (w <= 0 || h <= 0) { DeleteObject(info.hbmColor); DeleteObject(info.hbmMask); DeleteDC(hdc); return null; }
        byte[] bits = new byte[w * h * 4];
        bmi.header.height = -h; bmi.header.bpp = 32; bmi.header.compression = 0;
        GetDIBits(hdc, info.hbmColor, 0, (uint)h, bits, ref bmi, 0);
        DeleteObject(info.hbmColor); DeleteObject(info.hbmMask); DeleteDC(hdc);
        return bits;
    }
}
"@
$out = @()
$exes = @(
    "D:\ipyProject\ai-contract\src-tauri\target\release\taskbar-crypto-monitor.exe",
    "C:\Users\wu211\AppData\Local\Taskbar Crypto Monitor\taskbar-crypto-monitor.exe"
)
foreach ($exe in $exes) {
    $out += "=== $exe ==="
    foreach ($size in @(16, 20, 24, 32, 48, 64, 256)) {
        $hicons = New-Object 'IntPtr[]' 1
        $ids = New-Object 'uint32[]' 1
        $n = [IconExtract]::PrivateExtractIconsW($exe, 0, $size, $size, $hicons, $ids, 1, 0)
        if ($n -gt 0 -and $hicons[0] -ne [IntPtr]::Zero) {
            $w = 0; $h = 0
            $bits = [IconExtract]::GetIconPixels($hicons[0], [ref]$w, [ref]$h)
            [IconExtract]::DestroyIcon($hicons[0]) | Out-Null
            if ($bits) {
                $total = $w * $h
                $dark = 0; $blue = 0; $transparent = 0
                for ($i = 0; $i -lt $total; $i++) {
                    $b = $bits[$i*4]; $g = $bits[$i*4+1]; $r = $bits[$i*4+2]; $a = $bits[$i*4+3]
                    if ($a -lt 10) { $transparent++; continue }
                    if ($r + $g + $b -lt 100) { $dark++ }
                    if ($b -gt $r + 25 -and $b -gt 60) { $blue++ }
                }
                $out += ("请求{0} 实际{1}x{2}: 总{3} 暗{4}({5}%) 蓝{6}({7}%) 透明{8}({9}%)" -f $size, $w, $h, $total, $dark, [int]($dark*100/$total), $blue, [int]($blue*100/$total), $transparent, [int]($transparent*100/$total))
            } else {
                $out += "请求$size 像素读取失败"
            }
        } else {
            $out += "请求$size 提取失败 n=$n"
        }
    }
}
$out | Out-File "D:\ipyProject\ai-contract\.exeicon.txt" -Encoding utf8