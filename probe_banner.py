#!/usr/bin/env python3
"""定位"J扫J"引导页触发条件：打 6 个带编号的小标签，每个用不同命令组合。

编号含义（看哪张纸上有"J扫J"）：
  1 = 完整序列（当前 App 用的，对照组）
  2 = 只有 enable + stop（完全没有图像数据）
  3 = 去掉 enable（awake + lineDots + 图像 + lineDots + stop）
  4 = 去掉 awake（enable + lineDots + 图像 + lineDots + stop）
  5 = 官方完整序列（加 setPrintThickness + GS v 0 用加密 m 值）
  6 = 去掉 lineDots（enable + awake + 图像 + stop）
"""
import asyncio, sys
from PIL import Image, ImageDraw, ImageFont
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WB = 72
WIDTH = 576
TOP = 60
BOTTOM = 260
DELAY = 0.015

ENABLE = bytes([0x10, 0xFF, 0xF1, 0x03])
STOP   = bytes([0x10, 0xFF, 0xF1, 0x45])
AWAKE  = bytes(1024)
LD_TOP = bytes([0x0F, 0x4A, 0x0A, 0x00])
LD_BOT = bytes([0x0F, 0x4A, 0x96, 0x00])
THICK  = bytes([0x10, 0xFF, 0x10, 0x00, 0x01])


def label_raster(num: int, rows: int = 120) -> bytes:
    """渲染大号数字作为标签内容"""
    img = Image.new("L", (WIDTH, rows), 255)
    d = ImageDraw.Draw(img)
    font = None
    for path in ("/System/Library/Fonts/Helvetica.ttc",
                 "/System/Library/Fonts/Supplemental/Arial Bold.ttf"):
        try:
            font = ImageFont.truetype(path, 90)
            break
        except OSError:
            continue
    text = str(num)
    bb = d.textbbox((0, 0), text, font=font)
    d.text(((WIDTH - (bb[2] - bb[0])) // 2 - bb[0], (rows - (bb[3] - bb[1])) // 2 - bb[1]),
           text, fill=0, font=font)
    r = bytearray(WB * rows)
    px = img.load()
    for y in range(rows):
        for x in range(WIDTH):
            if px[x, y] < 128:
                r[y * WB + x // 8] |= 1 << (7 - x % 8)
    return bytes(r)


def gsv0(raster: bytes, total_rows: int, m: int = 0) -> bytes:
    return bytes([0x1D, 0x76, 0x30, m, WB & 0xFF, WB >> 8,
                  total_rows & 0xFF, total_rows >> 8]) + raster


def cipher_m(rows: int, bytes_per_row: int = WB) -> int:
    """官方 printEncrypt 算法：i5 = rows>>4, i6 = bytesPerRow & 15"""
    i5 = rows >> 4
    i6 = bytes_per_row & 15
    return (((i6 & i5) | ((i5 | i6) << 4)) & 0xFF)


def build(num: int) -> bytes:
    body = label_raster(num)
    total = TOP + len(body) // WB + BOTTOM
    full = bytes(WB * TOP) + body + bytes(WB * BOTTOM)
    if num == 1:
        return ENABLE + AWAKE + LD_TOP + gsv0(full, total) + LD_BOT + STOP
    if num == 2:
        return ENABLE + AWAKE + LD_TOP + LD_BOT + STOP
    if num == 3:
        return AWAKE + LD_TOP + gsv0(full, total) + LD_BOT + STOP
    if num == 4:
        return ENABLE + LD_TOP + gsv0(full, total) + LD_BOT + STOP
    if num == 5:
        m = cipher_m(total)
        print(f"    标签5: 加密 m = {m:#04x}（总行数 {total}）")
        return ENABLE + AWAKE + THICK + LD_TOP + gsv0(full, total, m) + LD_BOT + STOP
    if num == 6:
        return ENABLE + AWAKE + gsv0(full, total) + STOP
    raise ValueError(num)


async def main():
    done = asyncio.Event()

    async with BleakClient(ADDR) as client:
        def on_notify(char, data):
            if data == b"\xaa":
                done.set()

        await client.start_notify(WRITE_UUID, on_notify)
        await asyncio.sleep(0.5)
        for num in range(1, 7):
            seq = build(num)
            print(f"打印标签 {num}（{len(seq)} 字节）…")
            done.clear()
            for i in range(0, len(seq), 100):
                await client.write_gatt_char(WRITE_UUID, seq[i:i + 100], response=False)
                await asyncio.sleep(DELAY)
            try:
                await asyncio.wait_for(done.wait(), timeout=40)
                print(f"  标签 {num} 完成 ✓")
            except asyncio.TimeoutError:
                print(f"  标签 {num} 未收到完成信号 ⚠️")
            await asyncio.sleep(1.5)

asyncio.run(main())
