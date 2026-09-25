#!/usr/bin/env python3
"""发送速率 → 打印完整性 标定。

同样内容（600 行满宽黑条 + 上下留白 ≈ 67KB），用不同片间延时各打一张，
每张黑条上用白字挖空标出该张的延时（如 "12" = 12ms/片）。
判断标准：**底部是否留出空白边距**（被截尾的批次没有边距）。

用法：python3 probe_sendrate.py [地址] [延时列表，默认 12,18,20,25]
"""
import asyncio
import sys
from PIL import Image, ImageDraw, ImageFont
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
DELAYS = [int(x) for x in sys.argv[2].split(",")] if len(sys.argv) > 2 else [12, 18, 20, 25]

WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WB, WIDTH = 72, 576
TOP, BOTTOM = 60, 260
ROWS = 600

ENABLE = bytes([0x10, 0xFF, 0xF1, 0x03])
STOP = bytes([0x10, 0xFF, 0xF1, 0x45])
AWAKE = bytes(1024)
THICK = bytes([0x10, 0xFF, 0x10, 0x00, 0x03])   # 浓度 3


def font(size):
    for p in ("/System/Library/Fonts/Helvetica.ttc",
              "/System/Library/Fonts/Supplemental/Arial Bold.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()


def job(delay_ms: int) -> bytes:
    img = Image.new("L", (WIDTH, ROWS), 255)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, WIDTH - 1, ROWS - 1], fill=0)
    f = font(120)
    label = str(delay_ms)
    bb = d.textbbox((0, 0), label, font=f)
    d.text(((WIDTH - (bb[2] - bb[0])) // 2 - bb[0], (ROWS - (bb[3] - bb[1])) // 2 - bb[1]),
           label, fill=255, font=f)          # 白字挖空
    r = bytearray(WB * ROWS)
    px = img.load()
    for y in range(ROWS):
        for x in range(WIDTH):
            if px[x, y] < 128:
                r[y * WB + x // 8] |= 1 << (7 - x % 8)
    total = TOP + ROWS + BOTTOM
    seq = bytearray()
    seq += ENABLE + AWAKE + THICK
    seq += bytes([0x1D, 0x76, 0x30, 0x00, WB & 0xFF, WB >> 8, total & 0xFF, total >> 8])
    seq += bytes(WB * TOP) + bytes(r) + bytes(WB * BOTTOM)
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
        for ms in DELAYS:
            seq = job(ms)
            delay = ms / 1000
            print(f"打印标着「{ms}」的黑条（{len(seq)} 字节，{ms}ms/片 ≈ {100/delay/1024:.1f}KB/s）…")
            done.clear()
            for i in range(0, len(seq), 100):
                await client.write_gatt_char(WRITE_UUID, seq[i:i + 100], response=False)
                await asyncio.sleep(delay)
            try:
                await asyncio.wait_for(done.wait(), timeout=120)
                print("  ✓ 收到 0xAA")
            except asyncio.TimeoutError:
                print("  ⚠️ 未收到 0xAA")
            await asyncio.sleep(2.0)

asyncio.run(main())
