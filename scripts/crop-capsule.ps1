# 裁剪胶囊区域并 4 倍放大保存，供 OCR 验证
Add-Type -AssemblyName System.Drawing

$src = [System.Drawing.Image]::FromFile("D:\ipyProject\ai-contract\docs\screenshots\prototype-final.png")

# 胶囊在截图中的区域：屏幕 (43,1021)-(415,1065)，截图顶边 = 屏幕 767
$crop = New-Object System.Drawing.Bitmap(372, 44)
$g = [System.Drawing.Graphics]::FromImage($crop)
$g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, 372, 44)), (New-Object System.Drawing.Rectangle(43, 254, 372, 44)), [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()

# 4 倍最近邻放大便于 OCR 识别小号文本
$zw = 372 * 4
$zh = 44 * 4
$zoom = New-Object System.Drawing.Bitmap($zw, $zh)
$gz = [System.Drawing.Graphics]::FromImage($zoom)
$gz.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$gz.DrawImage($crop, 0, 0, $zw, $zh)
$gz.Dispose()

$zoom.Save("D:\ipyProject\ai-contract\docs\screenshots\capsule-crop-zoom.png", [System.Drawing.Imaging.ImageFormat]::Png)
$src.Dispose()
$crop.Dispose()
$zoom.Dispose()
Write-Output "CROP_SAVED"