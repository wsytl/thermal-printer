#!/usr/bin/env python3
"""标定「打印浓度 → 纵向行距」的关系。

每张标签内容：
  - 大号数字：该张的浓度值（0 = 不发送浓度命令，即旧默认行为）
  - 水平参考条：576 点宽 × 30 行（宽度恒为 48.4mm，用作参照）
  - 竖条 A：40 点宽 × 250 行
  - 竖条 B：40 点宽 × 500 行

量法：量两根竖条的长度(mm)。行距 = 长度/行数；修正系数 = 0.084 / 行距。
（若行距恒定，B 的长度应正好是 A 的 2 倍）

用法：python3 probe_density_vscale.py            # 默认打印 0,1,2,3,4,5
     python3 probe_density_vscale.py <地址> 1,3  # 只打指定浓度
"""
import asyncio
import sys
from PIL import Image, ImageDraw, ImageFont
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
DENSITIES = ([int(x) for x in sys.argv[2].split(",")] if len(sys.argv) > 2
             else [0, 1, 2, 3, 4, 5])   # 0 = 不发送浓度命令

WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WB, WIDTH = 72, 576
TOP, BOTTOM = 60, 260
DELAY = 0.015

ENABLE = bytes([0x10, 0xFF, 0xF1, 0x03])
STOP = bytes([0x10, 0xFF, 0xF1, 0x45])
AWAKE = bytes(1024)

HDR_ROWS = 110      # 数字区
BAR_ROWS = 30       # 水平参考条
BAR_W = 40          # 竖条宽（点）
A_H, B_H = 250, 500
GAP = 25


def font(size):
    for p in ("/System/Library/Fonts/Helvetica.ttc",
              "/System/Library/Fonts/Supplemental/Arial Bold.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()


def make_raster(density: int) -> bytes:
    rows = HDR_ROWS + BAR_ROWS + GAP + A_H + GAP + B_H
    img = Image.new("L", (WIDTH, rows), 255)
    d = ImageDraw.Draw(img)
    # 数字区
    label = f"D{density}" if density else "DEF"
    f = font(76)
    bb = d.textbbox((0, 0), label, font=f)
    d.text(((WIDTH - (bb[2] - bb[0])) // 2 - bb[0], 8), label, fill=0, font=f)
    # 水平参考条（整幅宽 × 30 行）
    y = HDR_ROWS
    d.rectangle([0, y, WIDTH - 1, y + BAR_ROWS - 1], fill=0)
    y += BAR_ROWS + GAP
    # 竖条 A / B（左对齐，宽 40 点）
    d.rectangle([0, y, BAR_W - 1, y + A_H - 1], fill=0)
    y += A_H + GAP
    d.rectangle([0, y, BAR_W - 1, y + B_H - 1], fill=0)

    r = bytearray(WB * rows)
    px = img.load()
    for yy in range(rows):
        for xx in range(WIDTH):
            if px[xx, yy] < 128:
                r[yy * WB + xx // 8] |= 1 << (7 - xx % 8)
    body = bytes(r)
    total = TOP + rows + BOTTOM
    seq = bytearray()
    seq += ENABLE
    seq += AWAKE
    if density:                                     # 0 表示不发浓度命令
        seq += bytes([0x10, 0xFF, 0x10, 0x00, density & 0xFF])
    seq += bytes([0x1D, 0x76, 0x30, 0x00, WB & 0xFF, WB >> 8,
                  total & 0xFF, total >> 8])
    seq += bytes(WB * TOP) + body + bytes(WB * BOTTOM)
    seq += STOP
    return bytes(seq)


async def main():
    done = asyncio.Event()
    async with BleakClient(ADDR) as client:
        def on_notify(char, data):
            if data == b"\xaa":
                done.set()

        await client.start_notify(WRITE_UUID, on_notify)
        await asyncio.sleep(0.5)
        for dens in DENSITIES:
            seq = make_raster(dens)
            print(f"打印浓度 {dens if dens else '默认(不发命令)'} 的标定标签（{len(seq)} 字节）…")
            done.clear()
            for i in range(0, len(seq), 100):
                await client.write_gatt_char(WRITE_UUID, seq[i:i + 100], response=False)
                await asyncio.sleep(DELAY)
            try:
                await asyncio.wait_for(done.wait(), timeout=40)
                print(f"  ✓ 完成")
            except asyncio.TimeoutError:
                print(f"  ⚠️ 未收到完成信号")
            await asyncio.sleep(1.5)

asyncio.run(main())
