#!/usr/bin/env python3
"""生成应用图标源图（1024x1024 RGBA PNG）。

设计语言与胶囊 UI 呼应：深蓝渐变圆角方块背景、绿色发光上升趋势折线、
末端白色亮点，在 16px 小尺寸下仍保持高对比可读。
产物：docs/icon-source.png（供 `npx tauri icon` 生成全套尺寸）
"""

from PIL import Image, ImageDraw, ImageFilter

# 画布与圆角（Windows 11 squircle 风格，约 22.5% 圆角率）
SIZE = 1024
RADIUS = 230

# 趋势折线关键点：先回调蓄势再强劲上攻，形似 K 线走势
POINTS = [(150, 680), (330, 555), (470, 625), (620, 395), (760, 465), (880, 245)]
LINE_COLOR = (74, 222, 128)  # #4ade80 与胶囊上涨色一致
LINE_WIDTH = 96

# 背景渐变端点色：小尺寸下须保持可辨识的蓝色调（过暗会在 32px 下近似黑色）
BG_TOP = (30, 44, 84)  # #1e2c54
BG_BOTTOM = (62, 108, 192)  # #3e6cc0


def build_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    """生成对角线渐变图：小尺寸逐像素计算后放大，兼顾速度与平滑。"""
    small = 256
    grad = Image.new("RGBA", (small, small))
    px = grad.load()
    for y in range(small):
        for x in range(small):
            # t 沿对角线 (x+y) 线性插值
            t = (x + y) / (2 * (small - 1))
            color = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
            px[x, y] = color
    return grad.resize((size, size), Image.BICUBIC)


def build_round_mask(size: int, radius: int) -> Image.Image:
    """圆角矩形蒙版：控制渐变背景的外轮廓。"""
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def build_area_fill(size: int, points: list, line_width: int) -> Image.Image:
    """折线下方的垂直渐变面积（上浓下透明），模拟 Sparkline 的 area 填充。"""
    # 渐变填充层：顶部 alpha 90（约 0.35）到底部 0
    grad = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gp = grad.load()
    for y in range(size):
        alpha = max(0, round(90 * (1 - y / size)))
        for x in range(size):
            gp[x, y] = LINE_COLOR + (alpha,)
    # 面积蒙版：折线路径下沿 + 两侧落底围成的多边形
    mask = Image.new("L", (size, size), 0)
    bottom = size - int(size * 0.18)  # 面积底边略高于画布底，留出呼吸空间
    polygon = [points[0]] + [points[-1], (points[-1][0], bottom), (points[0][0], bottom)]
    ImageDraw.Draw(mask).polygon(polygon, fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out


def build_glow(size: int, points: list, line_width: int) -> Image.Image:
    """趋势线发光层：粗线高斯模糊叠加两次，营造霓虹光晕。"""
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(glow)
    d.line(points, fill=LINE_COLOR + (255,), width=line_width + 60, joint="curve")
    for p in points:
        d.ellipse([p[0] - (line_width + 60) // 2, p[1] - (line_width + 60) // 2,
                   p[0] + (line_width + 60) // 2, p[1] + (line_width + 60) // 2],
                  fill=LINE_COLOR + (255,))
    glow = glow.filter(ImageFilter.GaussianBlur(38))
    # 叠加第二层提升光晕亮度
    return Image.alpha_composite(glow, glow)


def main() -> None:
    """合成图标：背景渐变 → 面积填充 → 发光 → 主线 → 末端亮点。"""
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # 背景渐变按圆角蒙版贴入
    bg = build_gradient(SIZE, BG_TOP, BG_BOTTOM)
    canvas.paste(bg, (0, 0), build_round_mask(SIZE, RADIUS))

    # 体积感：右下内侧微弱亮边（半径更大的圆角描边，浅色低透明）
    edge = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        [10, 10, SIZE - 11, SIZE - 11], radius=RADIUS - 8,
        outline=(120, 190, 255, 36), width=6)
    canvas = Image.alpha_composite(canvas, edge)

    # 面积填充裁剪到圆角内
    area = build_area_fill(SIZE, POINTS, LINE_WIDTH)
    area_masked = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    area_masked.paste(area, (0, 0), build_round_mask(SIZE, RADIUS))
    canvas = Image.alpha_composite(canvas, area_masked)

    # 发光层（同样裁剪到圆角内）
    glow = build_glow(SIZE, POINTS, LINE_WIDTH)
    glow_masked = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    glow_masked.paste(glow, (0, 0), build_round_mask(SIZE, RADIUS))
    canvas = Image.alpha_composite(canvas, glow_masked)

    # 主趋势线：圆头圆角连接
    line_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(line_layer)
    d.line(POINTS, fill=LINE_COLOR + (255,), width=LINE_WIDTH, joint="curve")
    for p in POINTS:
        r = LINE_WIDTH // 2
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=LINE_COLOR + (255,))
    canvas = Image.alpha_composite(canvas, line_layer)

    # 末端亮点：绿色光晕 + 白色核心，标记"最新价"
    end = POINTS[-1]
    halo = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse([end[0] - 78, end[1] - 78, end[0] + 78, end[1] + 78],
                                 fill=LINE_COLOR + (160,))
    halo = halo.filter(ImageFilter.GaussianBlur(18))
    canvas = Image.alpha_composite(canvas, halo)
    dot = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(dot).ellipse([end[0] - 40, end[1] - 40, end[0] + 40, end[1] + 40],
                                fill=(255, 255, 255, 255))
    canvas = Image.alpha_composite(canvas, dot)

    canvas.save("docs/icon-source.png")
    print("已生成 docs/icon-source.png", canvas.size)


if __name__ == "__main__":
    main()