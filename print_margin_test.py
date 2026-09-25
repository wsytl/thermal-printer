#!/usr/bin/env python3
"""底部边距诊断：方块(500x500) + 118空白行 + 1行全宽黑线 + 10空白行。
若黑线出现在方块下方约1cm处 → 底部空白行正常走纸（用户看到"没边距"是别的原因）
若黑线紧贴方块下方 → 打印机跳过尾部空白行，需改用其他方式留底部边距。
"""
import asyncio, sys
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
SERVICE_UUID = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WIDTH_DOTS = 576
DENSITY = int(__import__('os').environ.get('DENSITY', '3'))  # 打印浓度 1-5
TOP_BLANK_ROWS = 60
SIDE = 500
BOTTOM_BLANK = 118
MARKER = 1
TAIL = 10

wb = WIDTH_DOTS // 8
content_h = SIDE + BOTTOM_BLANK + MARKER + TAIL
raster = bytearray(wb * content_h)

def set_row(y, x0, x1, v):
    for x in range(x0, x1):
        if v:
            raster[y * wb + x // 8] |= 1 << (7 - x % 8)
        else:
            raster[y * wb + x // 8] &= ~(1 << (7 - x % 8))

# 方块
for y in range(SIDE):
    set_row(y, (WIDTH_DOTS - SIDE) // 2, (WIDTH_DOTS + SIDE) // 2, 1)
# BOTTOM_BLANK 行空白（默认全 0）
# 标记线（全宽黑线）
set_row(SIDE + BOTTOM_BLANK, 0, WIDTH_DOTS, 1)
# TAIL 行空白

total = content_h + TOP_BLANK_ROWS
seq = bytearray()
seq += bytes([0x10, 0xFF, 0xF1, 0x03])
seq += bytes(1024)                             # awake
seq += bytes([0x10, 0xFF, 0x10, 0x00, DENSITY])  # 打印浓度
seq += bytes([0x1D, 0x76, 0x30, 0x00, wb & 0xFF, wb >> 8, total & 0xFF, total >> 8])
seq += bytes(wb * TOP_BLANK_ROWS)
seq += bytes(raster)
seq += bytes([0x10, 0xFF, 0xF1, 0x45])
SEQ = bytes(seq)
print(f"序列 {len(SEQ)} 字节，方块{content_h}行")

done = asyncio.Event()

async def main():
    async with BleakClient(ADDR) as client:
        def on_notify(char, data):
            print(f"  [通知] {data.hex(' ')}")
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
            await asyncio.wait_for(done.wait(), timeout=40)
            print("✅ AA 收到")
        except asyncio.TimeoutError:
            print("⚠️ 未收到 AA")

asyncio.run(main())
