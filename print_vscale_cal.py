#!/usr/bin/env python3
"""纵向修正系数校准：576 宽 × 1008 行全宽黑块。
若修正系数 1.75 正确（纵向行距 21 行/mm），打印应为 48mm 宽 × 48mm 高正方形。
用户量高度：=48mm → 系数正确；≠48mm → 按 48/实测 修正系数。
"""
import asyncio, sys
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
SERVICE_UUID = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WIDTH_DOTS = 576
DENSITY = int(__import__('os').environ.get('DENSITY', '3'))  # 打印浓度 1-5
ROWS = 1008   # 576 × 1.75
TOP_BLANK_ROWS = 60
BOTTOM_BLANK_ROWS = 260

wb = WIDTH_DOTS // 8
raster = bytearray(wb * ROWS)
for y in range(ROWS):
    for x in range(WIDTH_DOTS):
        raster[y * wb + x // 8] |= 1 << (7 - x % 8)

total = ROWS + TOP_BLANK_ROWS + BOTTOM_BLANK_ROWS
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
print(f"序列 {len(SEQ)} 字节（1008 行，25ms/片）")

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
            print("✅ AA 收到。请量黑块高度（预期 48mm）")
        except asyncio.TimeoutError:
            print("⚠️ 未收到 AA")

asyncio.run(main())
