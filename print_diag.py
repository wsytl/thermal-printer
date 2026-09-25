#!/usr/bin/env python3
"""打印诊断图：
1. 全宽黑条（576 点宽 × 80 行）—— 看打印机实际可打印区域的左右边界
2. 500x500 实心方块 —— 量宽/高，验证纵横比例
3. 底部 118 行留白 —— 验证底部边距
等待 0xAA 最长 40 秒。
"""
import asyncio
import sys
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
SERVICE_UUID = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"

WIDTH_DOTS = 576
DENSITY = int(__import__('os').environ.get('DENSITY', '3'))  # 打印浓度 1-5
TOP_BLANK_ROWS = 60
BOTTOM_BLANK_ROWS = 260
BAR_ROWS = 80
GAP_ROWS = 40
SIDE = 500

wb = WIDTH_DOTS // 8

# 图案：黑条 + 间隙 + 方块
height = BAR_ROWS + GAP_ROWS + SIDE
raster = bytearray(wb * height)

def fill_rect(y0, y1, x0, x1):
    for y in range(y0, y1):
        for x in range(x0, x1):
            raster[y * wb + x // 8] |= 1 << (7 - x % 8)

fill_rect(0, BAR_ROWS, 0, WIDTH_DOTS)                      # 全宽黑条
fill_rect(BAR_ROWS + GAP_ROWS, BAR_ROWS + GAP_ROWS + SIDE,  # 方块
          (WIDTH_DOTS - SIDE) // 2, (WIDTH_DOTS + SIDE) // 2)

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

        print(f"发送诊断图 {len(SEQ)} 字节（{height} 行图案 + 边距）...")
        for i in range(0, len(SEQ), 100):
            await client.write_gatt_char(WRITE_UUID, SEQ[i:i + 100], response=False)
            await asyncio.sleep(pick_delay(len(SEQ)))
        print("发送完毕，等待 0xAA（最长 40 秒）...")
        try:
            await asyncio.wait_for(done.wait(), timeout=40)
            print("✅ 收到 0xAA，任务完成")
        except asyncio.TimeoutError:
            print("⚠️ 40 秒内未收到 0xAA")
        # 查询打印机状态确认在线
        try:
            await client.write_gatt_char(WRITE_UUID, bytes([0x10, 0xFF, 0x40, 0x00]), response=True)
            await asyncio.sleep(1.0)
            print("已发状态查询")
        except Exception as e:
            print(f"状态查询失败: {e}")


asyncio.run(main())
