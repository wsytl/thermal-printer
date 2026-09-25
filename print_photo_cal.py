#!/usr/bin/env python3
"""照片测量校准图：3 个已知点阵尺寸的图形（供用户拍照后我用 OpenCV 精确测量）。
- 全宽黑条：576 x 200 行
- 方块 B：400 x 400
- 方块 C：300 x 300
"""
import asyncio, sys
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
SERVICE_UUID = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WIDTH_DOTS = 576
DENSITY = int(__import__('os').environ.get('DENSITY', '3'))  # 打印浓度 1-5
TOP_BLANK_ROWS = 60
BOTTOM_BLANK_ROWS = 260
GAP = 40

wb = WIDTH_DOTS // 8
BAR_W, BAR_H = 576, 200
SQ_B = 400
SQ_C = 300
content_h = BAR_H + GAP + SQ_B + GAP + SQ_C
raster = bytearray(wb * content_h)

def fill(x0, x1, y0, y1):
    for y in range(y0, y1):
        for x in range(x0, x1):
            raster[y * wb + x // 8] |= 1 << (7 - x % 8)

y = 0
fill(0, BAR_W, y, y + BAR_H); y += BAR_H + GAP          # 全宽黑条
fill((WIDTH_DOTS - SQ_B) // 2, (WIDTH_DOTS + SQ_B) // 2, y, y + SQ_B); y += SQ_B + GAP  # 400方块
fill((WIDTH_DOTS - SQ_C) // 2, (WIDTH_DOTS + SQ_C) // 2, y, y + SQ_C)                   # 300方块

total = content_h + TOP_BLANK_ROWS + BOTTOM_BLANK_ROWS
seq = bytearray()
seq += bytes([0x10, 0xFF, 0xF1, 0x03])
seq += bytes(1024)                             # awake
seq += bytes([0x10, 0xFF, 0x10, 0x00, DENSITY])  # 打印浓度
seq += bytes([0x1D, 0x76, 0x30, 0x00, wb & 0xFF, wb >> 8, total & 0xFF, total >> 8])
seq += bytes(wb * TOP_BLANK_ROWS)
seq += bytes(raster)
seq += bytes(wb * BOTTOM_BLANK_ROWS)
seq += bytes([0x10, 0xFF, 0xF1, 0x45])
SEQ = bytes(seq)
print(f"序列 {len(SEQ)} 字节，图案 {content_h} 行")

done = asyncio.Event()

async def main():
    async with BleakClient(ADDR) as client:
        def on_notify(char, data):
            if data == b"\xaa":
                done.set()
        await client.start_notify(WRITE_UUID, on_notify)
        await asyncio.sleep(0.5)
        await client.write_gatt_char(WRITE_UUID, bytes([0x10, 0xFF, 0x30, 0x12]), response=True)
        await asyncio.sleep(1.0)
        for i in range(0, len(SEQ), 100):
            await client.write_gatt_char(WRITE_UUID, SEQ[i:i + 100], response=False)
            await asyncio.sleep(0.025)
        print("发送完毕，等待 AA...")
        try:
            await asyncio.wait_for(done.wait(), timeout=60)
            print("✅ AA 收到。请拍照：整张纸平放，旁边放一把尺子（要拍清刻度）")
        except asyncio.TimeoutError:
            print("⚠️ 未收到 AA")

asyncio.run(main())
