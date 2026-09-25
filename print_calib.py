#!/usr/bin/env python3
"""打印校准图：实心黑方块（500x500 点，宽 = 500/12 = 41.7mm）。
若打印机纵横分辨率一致，方块打印出来就是正方形（宽 = 高 ≈ 41.7mm）。
用户用尺子量方块的实际 宽(W) 和 高(H)，据此算出纵向修正系数。
"""
import asyncio
import sys
from PIL import Image
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
SERVICE_UUID = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"

WIDTH_DOTS = 576
DENSITY = int(__import__('os').environ.get('DENSITY', '3'))  # 打印浓度 1-5
TOP_BLANK_ROWS = 60
BOTTOM_BLANK_ROWS = 260
SIDE = int(sys.argv[2]) if len(sys.argv) > 2 else 500  # 方块边长（点）

img = Image.new("L", (WIDTH_DOTS, SIDE), 255)
for y in range(SIDE):
    for x in range((WIDTH_DOTS - SIDE) // 2, (WIDTH_DOTS + SIDE) // 2):
        img.putpixel((x, y), 0)

wb = WIDTH_DOTS // 8
height = SIDE
raster = bytearray(wb * height)
for y in range(height):
    for x in range(WIDTH_DOTS):
        if img.getpixel((x, y)) < 128:
            raster[y * wb + x // 8] |= 1 << (7 - x % 8)

total_height = height + TOP_BLANK_ROWS + BOTTOM_BLANK_ROWS
seq = bytearray()
seq += bytes([0x10, 0xFF, 0xF1, 0x03])        # enable
seq += bytes(1024)                             # awake
seq += bytes([0x10, 0xFF, 0x10, 0x00, DENSITY])  # 打印浓度
seq += bytes([0x1D, 0x76, 0x30, 0x00,
              wb & 0xFF, wb >> 8,
              total_height & 0xFF, total_height >> 8])
seq += bytes(wb * TOP_BLANK_ROWS)
seq += bytes(raster)
seq += bytes(wb * BOTTOM_BLANK_ROWS)
seq += bytes([0x10, 0xFF, 0xF1, 0x45])         # stop
SEQ = bytes(seq)

done = asyncio.Event()


def pick_delay(nbytes: int) -> float:
    """速率分档：≤50KB 用 15ms/片；>50KB 用 25ms/片。
    打印机消化速度 ≈4KB/s，发太快会丢尾部数据（表现为收不到 0xAA、图案截断）。"""
    return 0.015 if nbytes <= 50_000 else 0.025


async def main():
    async with BleakClient(ADDR) as client:
        print(f"已连接 {ADDR}")

        def on_notify(char, data):
            print(f"  [通知 {char.uuid[:8]}] {data.hex(' ')}")
            if data == b"\xaa":
                done.set()

        await client.start_notify(WRITE_UUID, on_notify)
        await asyncio.sleep(0.5)
        await client.write_gatt_char(WRITE_UUID, bytes([0x10, 0xFF, 0x30, 0x12]), response=True)
        await asyncio.sleep(1.0)

        print(f"发送校准图 {len(SEQ)} 字节...")
        for i in range(0, len(SEQ), 100):
            await client.write_gatt_char(WRITE_UUID, SEQ[i:i + 100], response=False)
            await asyncio.sleep(pick_delay(len(SEQ)))
        try:
            await asyncio.wait_for(done.wait(), timeout=15)
            print("✅ 打印完成。请用尺子量方块的宽和高（mm），告诉我两个数字。")
        except asyncio.TimeoutError:
            print("⚠️ 未收到 0xAA")


asyncio.run(main())
