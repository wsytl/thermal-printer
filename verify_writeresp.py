#!/usr/bin/env python3
"""验证「带响应写入（write with response）」能否消除丢数据。

对比思路：同样内容用两种写入方式各打一张，量长度。
  - 满宽黑条 1000 行：按实测行距 0.086mm/行，完整应为约 86mm
  - withoutResponse（旧方式）此前只打出 55~59mm（丢 30%+）
  - withResponse（官方方式）应打出约 86mm

用法：python3 verify_writeresp.py [地址] [rows]
"""
import asyncio
import sys
from PIL import Image, ImageDraw, ImageFont
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
ROWS = int(sys.argv[2]) if len(sys.argv) > 2 else 1000

WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WB, WIDTH = 72, 576
TOP, BOTTOM = 60, 260
CHUNK = 180          # 带响应写入可以用更大分片（减少往返）

ENABLE = bytes([0x10, 0xFF, 0xF1, 0x03])
STOP = bytes([0x10, 0xFF, 0xF1, 0x45])
AWAKE = bytes(1024)
THICK = bytes([0x10, 0xFF, 0x10, 0x00, 0x03])


def font(size):
    for p in ("/System/Library/Fonts/Helvetica.ttc",
              "/System/Library/Fonts/Supplemental/Arial Bold.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()


def bar_job(rows: int, label: str) -> bytes:
    img = Image.new("L", (WIDTH, rows), 255)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, WIDTH - 1, rows - 1], fill=0)
    f = font(110)
    bb = d.textbbox((0, 0), label, font=f)
    d.text(((WIDTH - (bb[2] - bb[0])) // 2 - bb[0], (rows - (bb[3] - bb[1])) // 2 - bb[1]),
           label, fill=255, font=f)
    r = bytearray(WB * rows)
    px = img.load()
    for y in range(rows):
        for x in range(WIDTH):
            if px[x, y] < 128:
                r[y * WB + x // 8] |= 1 << (7 - x % 8)
    total = TOP + rows + BOTTOM
    seq = bytearray()
    seq += ENABLE + AWAKE + THICK
    seq += bytes([0x1D, 0x76, 0x30, 0x00, WB & 0xFF, WB >> 8, total & 0xFF, total >> 8])
    seq += bytes(WB * TOP) + bytes(r) + bytes(WB * BOTTOM)
    seq += STOP
    return bytes(seq)


async def main():
    done = asyncio.Event()
    async with BleakClient(ADDR, timeout=20) as client:
        def on_notify(char, data):
            if data == b"\xaa":
                done.set()

        # 打印特征属性，确认是否支持带响应写入
        for s in client.services:
            for c in s.characteristics:
                if c.uuid.lower().startswith("bef8d6c9"):
                    print(f"特征属性: {sorted(c.properties)}")
                    print(f"  支持 write-with-response: {'write' in c.properties}")
                    print(f"  支持 write-without-response: {'write-without-response' in c.properties}")

        await client.start_notify(WRITE_UUID, on_notify)
        await asyncio.sleep(0.5)
        seq = bar_job(ROWS, "W")
        print(f"带响应写入发送 {len(seq)} 字节（{ROWS} 行满宽黑条，分片 {CHUNK}B，无人工延时）…")
        t0 = asyncio.get_event_loop().time()
        for i in range(0, len(seq), CHUNK):
            await client.write_gatt_char(WRITE_UUID, seq[i:i + CHUNK], response=True)
        dt = asyncio.get_event_loop().time() - t0
        print(f"  发送耗时 {dt:.1f}s（≈{len(seq)/dt/1024:.1f}KB/s，由打印机应答节流）")
        try:
            await asyncio.wait_for(done.wait(), timeout=120)
            print("  ✓ 收到 0xAA")
        except asyncio.TimeoutError:
            print("  ⚠️ 未收到 0xAA")

asyncio.run(main())
