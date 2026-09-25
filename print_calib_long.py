#!/usr/bin/env python3
"""打印 500 点黑方块，等 AA 最长 240 秒，记录时间。验证热敏头散热暂停假设。"""
import asyncio
import sys
import time
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
SERVICE_UUID = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WIDTH_DOTS = 576
DENSITY = int(__import__('os').environ.get('DENSITY', '3'))  # 打印浓度 1-5
TOP_BLANK_ROWS = 60
BOTTOM_BLANK_ROWS = 260
ROWS = int(sys.argv[2]) if len(sys.argv) > 2 else 500   # 黑色行数
delay = float(sys.argv[3]) if len(sys.argv) > 3 else 0.012  # 片间延时（秒）
SIDE = 500        # 黑色块宽度（点）固定 500
SIDE_H = ROWS     # 黑色块高度（行）

img = bytearray((WIDTH_DOTS // 8) * SIDE_H)
wb = WIDTH_DOTS // 8
for y in range(SIDE_H):
    for x in range((WIDTH_DOTS - SIDE) // 2, (WIDTH_DOTS + SIDE) // 2):
        img[y * wb + x // 8] |= 1 << (7 - x % 8)

total_height = SIDE_H + TOP_BLANK_ROWS + BOTTOM_BLANK_ROWS
seq = bytearray()
seq += bytes([0x10, 0xFF, 0xF1, 0x03])
seq += bytes(1024)                             # awake
seq += bytes([0x10, 0xFF, 0x10, 0x00, DENSITY])  # 打印浓度
seq += bytes([0x1D, 0x76, 0x30, 0x00, wb & 0xFF, wb >> 8,
              total_height & 0xFF, total_height >> 8])
seq += bytes(wb * TOP_BLANK_ROWS)
seq += bytes(img)
seq += bytes(wb * BOTTOM_BLANK_ROWS)
seq += bytes([0x10, 0xFF, 0xF1, 0x45])
SEQ = bytes(seq)

done = asyncio.Event()
t0 = time.time()


async def main():
    async with BleakClient(ADDR) as client:
        print(f"已连接 {ADDR}")

        def on_notify(char, data):
            dt = time.time() - t0
            print(f"  [{dt:6.1f}s] 通知 {data.hex(' ')}")
            if data == b"\xaa":
                done.set()

        await client.start_notify(WRITE_UUID, on_notify)
        await asyncio.sleep(0.5)
        await client.write_gatt_char(WRITE_UUID, bytes([0x10, 0xFF, 0x30, 0x12]), response=True)
        await asyncio.sleep(1.0)

        print(f"发送 {len(SEQ)} 字节（100B/片，{delay*1000:.0f}ms/片）...")
        for i in range(0, len(SEQ), 100):
            await client.write_gatt_char(WRITE_UUID, SEQ[i:i + 100], response=False)
            await asyncio.sleep(delay)
        print(f"发送完毕 [{time.time()-t0:.1f}s]，等待 AA 最长 240 秒...")
        try:
            await asyncio.wait_for(done.wait(), timeout=240)
            print(f"✅ 收到 AA，耗时 {time.time()-t0:.1f} 秒")
        except asyncio.TimeoutError:
            print("⚠️ 240 秒内未收到 AA")


asyncio.run(main())
