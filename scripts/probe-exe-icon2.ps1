# 用 SHGetFileInfo（Explorer 读 exe 图标的真实路径）提取图标 + GetDIBits 读像素（含 mask 兜底）
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class IconProbe2 {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct SHFILEINFOW { public IntPtr hIcon; public int iIcon; public uint dwAttributes; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string szDisplayName; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=80)] public string szTypeName; }

    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr SHGetFileInfoW(string path, uint attrs, ref SHFILEINFOW info, uint cb, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct ICONINFO { public bool fIcon; public uint xHotspot; public uint yHotspot; public IntPtr hbmMask; public IntPtr hbmColor; }

    [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr hIcon, out ICONINFO info);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr h);
    [DllImport("gdi32.dll")] public static extern int GetDIBits(IntPtr hdc, IntPtr bmp, uint start, uint lines, byte[] bits, ref BMI bmi, uint usage);

    [StructLayout(LayoutKind.Sequential)]
    public struct BMIH { public uint size; public int width; public int height; public ushort planes, bpp; public uint compression, sizeImage; public int xpels, ypels; public uint clrUsed, clrImportant; }
    [StructLayout(LayoutKind.Sequential)]
    public struct BMI { public BMIH h; [MarshalAs(UnmanagedType.ByValArray, SizeConst=1)] public uint[] colors; }

    public static byte[] GetPixels(IntPtr hbmp, ref int w, ref int h) {
        if (hbmp == IntPtr.Zero) return null;
        IntPtr hdc = CreateCompatibleDC(IntPtr.Zero);
        BMI bmi = new BMI();
        bmi.h.size = (uint)Marshal.SizeOf(typeof(BMIH));
        int ret = GetDIBits(hdc, hbmp, 0, 0, null, ref bmi, 0);
        if (ret == 0) { DeleteDC(hdc); return null; }
        w = bmi.h.width; h = Math.Abs(bmi.h.height);
        if (w <= 0 || h <= 0 || w > 512 || h > 512) { DeleteDC(hdc); return null; }
        byte[] bits = new byte[w * h * 4];
        bmi.h.height = -h; bmi.h.bpp = 32; bmi.h.compression = 0;
        ret = GetDIBits(hdc, hbmp, 0, (uint)h, bits, ref bmi, 0);
        DeleteDC(hdc);
        if (ret == 0) return null;
        return bits;
    }

    public static string AnalyzeIcon(IntPtr hicon) {
        ICONINFO info;
        if (!GetIconInfo(hicon, out info)) return "GetIconInfo 失败";
        try {
            int w = 0, h = 0;
            byte[] bits = GetPixels(info.hbmColor, ref w, ref h);
            if (bits == null) {
                bits = GetPixels(info.hbmMask, ref w, ref h);
                if (bits == null) return "像素读取失败";
                return "仅掩码位图 " + w + "x" + h;
            }
            int total = w * h, dark = 0, blue = 0, transp = 0;
            for (int i = 0; i < total; i++) {
                byte b = bits[i*4], g = bits[i*4+1], r = bits[i*4+2], a = bits[i*4+3];
                if (a < 10) { transp++; continue; }
                if (r + g + b < 100) dark++;
                if (b > r + 25 && b > 60) blue++;
            }
            return w + "x" + h + " 总" + total + " 暗" + dark + "(" + dark*100/total + "%) 蓝" + blue + "(" + blue*100/total + "%) 透明" + transp + "(" + transp*100/total + "%)";
        } finally {
            if (info.hbmColor != IntPtr.Zero) DeleteObject(info.hbmColor);
            if (info.hbmMask != IntPtr.Zero) DeleteObject(info.hbmMask);
        }
    }
}
"@
$out = @()
$exes = @(
    "D:\ipyProject\ai-contract\src-tauri\target\release\taskbar-crypto-monitor.exe",
    "C:\Users\wu211\AppData\Local\Taskbar Crypto Monitor\taskbar-crypto-monitor.exe"
)
# SHGFI_ICON=0x100, SHGFI_LARGEICON=0x0, SHGFI_SMALLICON=0x1, SHGFI_USEFILEATTRIBUTES=0x10
foreach ($exe in $exes) {
    $out += "=== $exe ==="
    foreach ($flagSet in @(
        @{ name = "LARGE(32)"; flags = 0x100 },
        @{ name = "SMALL(16)"; flags = 0x100 -bor 0x1 }
    )) {
        $info = New-Object IconProbe2+SHFILEINFOW
        $hr = [IconProbe2]::SHGetFileInfoW($exe, 0x80, [ref]$info, [System.Runtime.InteropServices.Marshal]::SizeOf($info), $flagSet.flags)
        if ($info.hIcon -ne [IntPtr]::Zero) {
            $result = [IconProbe2]::AnalyzeIcon($info.hIcon)
            [IconProbe2]::DestroyIcon($info.hIcon) | Out-Null
            $out += "$($flagSet.name): $result"
        } else {
            $out += "$($flagSet.name): SHGetFileInfo 未返回图标"
        }
    }
}
$out | Out-File "D:\ipyProject\ai-contract\.exeicon2.txt" -Encoding utf8