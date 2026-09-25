#!/usr/bin/env python3
"""生成 App 图标（macOS 风格圆角方块 + 热敏纸小票）。

设计：
  · 圆角方块背景（Apple 风格圆角：半径 ≈ 22.37% 边长），蓝→青渐变
  · 中间一张白色小票纸：顶部圆角、底边锯齿（撕纸口）
  · 纸上：几行深色文字条 + 一个二维码图案 + 一条分割线
  · 纸上轻投影，让层次更像实体

产物：
  ThermalPrinter/Assets.xcassets/AppIcon.appiconset/   （各尺寸 PNG + Contents.json）
  dist/icon-preview.png                                （1024 预览，便于肉眼确认）

用法：python3 make_icon.py
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024                       # 主图尺寸
INSET = 100                    # 图标内容内缩（macOS 图标四周留白）
TILE = S - INSET * 2           # 方块边长 824
RADIUS = int(TILE * 0.2237)    # Apple 圆角比例

ASSET_DIR = "ThermalPrinter/Assets.xcassets/AppIcon.appiconset"


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def make_master() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # ---- 背景渐变（对角：深蓝 → 青）----
    top, bottom = (38, 84, 168), (28, 170, 178)
    grad = Image.new("RGB", (TILE, TILE))
    gd = ImageDraw.Draw(grad)
    for y in range(TILE):
        for_x_t = y / (TILE - 1)
        gd.line([(0, y), (TILE, y)], fill=lerp(top, bottom, for_x_t))
    # 再叠一层横向渐变，让左上更亮
    horiz = Image.new("L", (TILE, TILE))
    hd = ImageDraw.Draw(horiz)
    for x in range(TILE):
        hd.line([(x, 0), (x, TILE)], fill=int(70 * (1 - x / (TILE - 1))))
    grad = Image.composite(Image.new("RGB", (TILE, TILE), (255, 255, 255)), grad,
                           horiz.point(lambda v: v)) if False else grad

    tile = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    tile.paste(grad, (0, 0))
    tile.putalpha(rounded_mask(TILE, RADIUS))
    img.paste(tile, (INSET, INSET), tile)

    d = ImageDraw.Draw(img)

    # ---- 小票纸（含投影）----
    PW, PH = 470, 560
    px0 = (S - PW) // 2
    py0 = INSET + 150
    TEETH = 22          # 锯齿数量
    tooth_h = 26        # 锯齿高度

    paper = Image.new("RGBA", (PW, PH + tooth_h), (0, 0, 0, 0))
    pd = ImageDraw.Draw(paper)
    pd.rounded_rectangle([0, 0, PW - 1, PH], radius=26, fill=(255, 255, 255, 255))
    # 底边锯齿：挖掉三角
    step = PW / TEETH
    for i in range(TEETH):
        x0 = i * step
        pd.polygon([(x0, PH), (x0 + step, PH), (x0 + step / 2, PH + tooth_h)],
                   fill=(0, 0, 0, 0))

    # 投影
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (px0 + 6, py0 + 16), paper)
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    img.alpha_composite(shadow)
    img.alpha_composite(paper, (px0, py0))

    # ---- 纸面内容 ----
    ink = (44, 52, 66)
    pad = 54
    y = py0 + 66

    # 顶部二维码图案（21x21 风格：定位角 + 随机模块）
    qr_size = 150
    qx = px0 + pad
    qy = y
    cell = qr_size // 9
    for r in range(9):
        for c in range(9):
            fill = False
            if (r < 3 and c < 3) or (r < 3 and c > 5) or (r > 5 and c < 3):
                # 定位方块（外框实心 + 内部中空）
                edge = r in (0, 2, 6, 8) or c in (0, 2, 6, 8)
                inner = r in (1, 7) and c in (1, 7)
                fill = edge or inner
            else:
                fill = (r * 7 + c * 5) % 3 == 0
            if fill:
                d.rectangle([qx + c * cell, qy + r * cell,
                             qx + c * cell + cell - 2, qy + r * cell + cell - 2], fill=ink)

    # 右侧几行文字条（粗细不一，像小票文本）
    tx = qx + qr_size + 34
    tw_max = px0 + PW - pad - tx
    for i, frac in enumerate((1.0, 0.72, 0.88)):
        ly = qy + 12 + i * 46
        d.rounded_rectangle([tx, ly, tx + tw_max * frac, ly + 20], radius=10, fill=ink)

    # 分割虚线
    dy = qy + qr_size + 48
    x = px0 + pad
    while x < px0 + PW - pad:
        d.rounded_rectangle([x, dy, x + 16, dy + 6], radius=3, fill=(190, 198, 210))
        x += 28

    # 下方文字条
    for i, frac in enumerate((0.94, 0.66, 0.84, 0.5)):
        ly = dy + 40 + i * 44
        d.rounded_rectangle([px0 + pad, ly, px0 + pad + (PW - pad * 2) * frac, ly + 22],
                            radius=11, fill=ink)

    return img


def main():
    master = make_master()
    os.makedirs(ASSET_DIR, exist_ok=True)
    os.makedirs("dist", exist_ok=True)

    # macOS 图标各尺寸（1x/2x）
    sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
    images = []
    for pt, scale in sizes:
        px = pt * scale
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        master.resize((px, px), Image.LANCZOS).save(os.path.join(ASSET_DIR, name))
        images.append({"size": f"{pt}x{pt}", "idiom": "mac", "filename": name, "scale": f"{scale}x"})

    with open(os.path.join(ASSET_DIR, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)

    with open("ThermalPrinter/Assets.xcassets/Contents.json", "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)

    master.save("dist/icon-preview.png")
    print(f"✅ 生成 {len(images)} 个尺寸 → {ASSET_DIR}")
    print("   预览图：dist/icon-preview.png")


if __name__ == "__main__":
    main()
