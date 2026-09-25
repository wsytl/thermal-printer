#!/usr/bin/env python3
"""标定「浓度 → 走纸速度」：为按浓度补偿纵向比例提供数据。

每张内容：顶部一个浓度数字 + 一根 120 点宽 × 400 行的竖条
（黑度约 21%，接近文字的平均黑度）。

量法：量竖条长度(mm)。
  行距 p = 长度 / 400；要让它变成 0.084mm/行（与横向一致）需预拉伸 0.084/p 倍。
  浓度 1 预期约 400×0.084 = 33.6mm（比例正常）；浓度越高应越短。

用法：python3 probe_density_rate.py [地址] [浓度列表]
"""
import asyncio
import sys
from PIL import Image, ImageDraw, ImageFont
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
DENSITIES = [int(x) for x in sys.argv[2].split(",")] if len(sys.argv) > 2 else [1, 2, 3, 4, 5]

WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WB, WIDTH = 72, 576
TOP, BOTTOM = 60, 260
BAR_W, BAR_H = 120, 400
HDR = 120

ENABLE = bytes([0x10, 0xFF, 0xF1, 0x03])
STOP = bytes([0x10, 0xFF, 0xF1, 0x45])
AWAKE = bytes(1024)


def font(size):
    for p in ("/System/Library/Fonts/Helvetica.ttc",
              "/System/Library/Fonts/Supplemental/Arial Bold.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()


def job(density: int) -> bytes:
    rows = HDR + BAR_H
    img = Image.new("L", (WIDTH, rows), 255)
    d = ImageDraw.Draw(img)
    f = font(80)
    d.text((16, 10), f"D{density}", fill=0, font=f)
    # 竖条：左对齐，120 点宽
    d.rectangle([0, HDR, BAR_W - 1, HDR + BAR_H - 1], fill=0)
    r = bytearray(WB * rows)
    px = img.load()
    for y in range(rows):
        for x in range(WIDTH):
            if px[x, y] < 128:
                r[y * WB + x // 8] |= 1 << (7 - x % 8)
    total = TOP + rows + BOTTOM
    seq = bytearray()
    seq += ENABLE + AWAKE + bytes([0x10, 0xFF, 0x10, 0x00, density & 0xFF])
    seq += bytes([0x1D, 0x76, 0x30, 0x00, WB & 0xFF, WB >> 8, total & 0xFF, total >> 8])
    seq += bytes(WB * TOP) + bytes(r) + bytes(WB * BOTTOM)
    seq += STOP
    return bytes(seq)


async def main():
    done = asyncio.Event()
    async with BleakClient(ADDR, timeout=20) as c:
        await c.start_notify(WRITE_UUID, lambda ch, d: done.set() if d == b"\xaa" else None)
        await asyncio.sleep(0.5)
        for dens in DENSITIES:
            seq = job(dens)
            print(f"打印浓度 {dens} 的标定条（{len(seq)} 字节，竖条 400 行）…")
            done.clear()
            for i in range(0, len(seq), 180):
                await c.write_gatt_char(WRITE_UUID, seq[i:i + 180], response=True)
            try:
                await asyncio.wait_for(done.wait(), timeout=60); print("  ✓ AA")
            except asyncio.TimeoutError: print("  ⚠️ 无 AA")
            await asyncio.sleep(1.5)

asyncio.run(main())
