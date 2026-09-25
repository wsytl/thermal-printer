#!/usr/bin/env python3
"""浓度（打印深浅）对照实验：打 5 个标签，浓度值 1-5。

命令：setPrintThickness = 10 FF 10 00 <级别>
每个标签含：大号级别数字 + 实心黑条 + 灰度渐变 + 细字，便于对比深浅与细节保留。
"""
import asyncio, sys
from PIL import Image, ImageDraw, ImageFont
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
LEVELS = [int(x) for x in sys.argv[2].split(",")] if len(sys.argv) > 2 else [1, 2, 3, 4, 5]

WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WB, WIDTH = 72, 576
TOP, BOTTOM = 60, 260
DELAY = 0.015

ENABLE = bytes([0x10, 0xFF, 0xF1, 0x03])
STOP = bytes([0x10, 0xFF, 0xF1, 0x45])
AWAKE = bytes(1024)


def font(size):
    for p in ("/System/Library/Fonts/Helvetica.ttc",
              "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
              "/System/Library/Fonts/PingFang.ttc"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()


def make_label(level: int) -> bytes:
    """级别数字 + 实心黑条 + 渐变 + 细字 + 中文"""
    rows = 260
    img = Image.new("L", (WIDTH, rows), 255)
    d = ImageDraw.Draw(img)
    # 大号级别
    f_big = font(84)
    d.text((20, 6), f"L{level}", fill=0, font=f_big)
    # 右侧中文
    d.text((300, 30), "浓度测试", fill=0, font=font(40))
    # 实心黑条
    d.rectangle([0, 100, WIDTH - 1, 128], fill=0)
    # 灰度渐变条（看网点/抖动表现）
    for x in range(WIDTH):
        v = int(255 * (1 - x / (WIDTH - 1)))
        d.line([(x, 140), (x, 180)], fill=v)
    # 细字（看高浓度是否糊）
    d.text((10, 190), "细字测试 fine print 0123456789 abcdefg", fill=0, font=font(22))
    d.text((10, 216), "■■■ 三毫米方块细节 ■■■", fill=0, font=font(20))

    r = bytearray(WB * rows)
    px = img.load()
    for y in range(rows):
        for x in range(WIDTH):
            if px[x, y] < 128:
                r[y * WB + x // 8] |= 1 << (7 - x % 8)
    body = bytes(r)
    total = TOP + rows + BOTTOM
    full = bytes(WB * TOP) + body + bytes(WB * BOTTOM)
    seq = bytearray()
    seq += ENABLE
    seq += AWAKE
    seq += bytes([0x10, 0xFF, 0x10, 0x00, level & 0xFF])       # setPrintThickness
    seq += bytes([0x1D, 0x76, 0x30, 0x00, WB & 0xFF, WB >> 8,
                  total & 0xFF, total >> 8])
    seq += full
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
        for lv in LEVELS:
            seq = make_label(lv)
            print(f"打印浓度 {lv} 的标签（{len(seq)} 字节）…")
            done.clear()
            for i in range(0, len(seq), 100):
                await client.write_gatt_char(WRITE_UUID, seq[i:i + 100], response=False)
                await asyncio.sleep(DELAY)
            try:
                await asyncio.wait_for(done.wait(), timeout=40)
                print(f"  浓度 {lv} 完成 ✓")
            except asyncio.TimeoutError:
                print(f"  浓度 {lv} 未收到完成信号 ⚠️")
            await asyncio.sleep(1.5)

asyncio.run(main())
