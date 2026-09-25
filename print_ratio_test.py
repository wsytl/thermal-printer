#!/usr/bin/env python3
"""纵向分辨率判定：同一次打印两个 400 宽的黑块——A 高 400 行、B 高 700 行。
A/B 打印高度比 = 400/700 = 0.571；若打印后测得的比值不是 0.571，说明纵向行距与行数非线性。"""
import asyncio, sys
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
SERVICE_UUID = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WIDTH_DOTS = 576
DENSITY = int(__import__('os').environ.get('DENSITY', '3'))  # 打印浓度 1-5
TOP_BLANK_ROWS = 60
BOTTOM_BLANK_ROWS = 260
BLOCK_W = 400
A_H, B_H = 400, 700
GAP = 40

wb = WIDTH_DOTS // 8
content_h = A_H + GAP + B_H
raster = bytearray(wb * content_h)

def fill(x0, x1, y0, y1):
    for y in range(y0, y1):
        for x in range(x0, x1):
            raster[y * wb + x // 8] |= 1 << (7 - x % 8)

# 两个黑块，左对齐（x: 0..400），A 高 400，B 高 700
fill(0, BLOCK_W, 0, A_H)
fill(0, BLOCK_W, A_H + GAP, A_H + GAP + B_H)

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
print(f"序列 {len(SEQ)} 字节；块A 400行 + 间隙 + 块B 700行（若行距恒定，A高:B高 = 0.571）")

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
            print("✅ AA 收到")
        except asyncio.TimeoutError:
            print("⚠️ 未收到 AA")

asyncio.run(main())
