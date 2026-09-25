#!/usr/bin/env python3
"""打印二维码（576 点宽，单张 + 等待 0xAA 完成信号）。

点阵来自 qr_raster.bin（qr_test_big.png 生成，OpenCV 验证可解码）。
"""
import asyncio
import sys
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
SERVICE_UUID = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"

WIDTH_DOTS = 576
DENSITY = int(__import__('os').environ.get('DENSITY', '3'))  # 打印浓度 1-5
TOP_BLANK_ROWS = 60      # 顶部空白（实测顶部实际略偏大）
BOTTOM_BLANK_ROWS = 260  # 底部空白 ≈ 1cm（实测 lineDots 不走纸，必须用位图空白行走纸）


def build_sequence(raster: bytes, width: int, height: int,
                   top_blank: int = 0, bottom_blank: int = 0) -> bytes:
    wb = (width + 7) // 8
    total_height = height + top_blank + bottom_blank
    seq = bytearray()
    seq += bytes([0x10, 0xFF, 0xF1, 0x03])        # enable
    seq += bytes(1024)                             # awake（官方序列，实测不引发问题）
    seq += bytes([0x10, 0xFF, 0x10, 0x00, DENSITY])  # 打印浓度
    seq += bytes([0x1D, 0x76, 0x30, 0x00,          # GS v 0 (m=0，已验证可用)
                  wb & 0xFF, wb >> 8,
                  total_height & 0xFF, total_height >> 8])
    seq += bytes(wb * top_blank)                   # 顶部空白行（走纸）
    seq += raster                                  # 图案
    seq += bytes(wb * bottom_blank)                # 底部空白行（走纸，保证图案完全出纸）
    seq += bytes([0x10, 0xFF, 0xF1, 0x45])         # stop
    return bytes(seq)


def pick_delay(nbytes: int) -> float:
    """速率分档：≤50KB → 15ms/片；>50KB → 25ms/片（打印机消化 ≈4KB/s，过快会丢尾部数据）"""
    return 0.015 if nbytes <= 50_000 else 0.025


async def send_chunked(client, char_uuid, data, chunk=100, delay=0.015, response=False):
    total = (len(data) + chunk - 1) // chunk
    for i in range(0, len(data), chunk):
        await client.write_gatt_char(char_uuid, data[i:i + chunk], response=response)
        await asyncio.sleep(delay)
    print(f"发送完成：{len(data)} 字节 / {total} 片（{chunk}B/片）")


async def main():
    raster = open("qr_raster.bin", "rb").read()
    height = len(raster) // (WIDTH_DOTS // 8)
    done = asyncio.Event()

    def on_notify(char, data):
        print(f"  [通知 {char.uuid[:8]}] {data.hex(' ')}")
        if data == b"\xaa":
            done.set()

    async with BleakClient(ADDR) as client:
        print(f"已连接 {ADDR}")
        await client.start_notify(WRITE_UUID, on_notify)
        await asyncio.sleep(0.5)  # 连接稳定期

        # 握手：先发查询命令（App 连接后第一步），再打印
        print("握手：发送查询MAC命令...")
        await client.write_gatt_char(WRITE_UUID, bytes([0x10, 0xFF, 0x30, 0x12]), response=True)
        await asyncio.sleep(1.0)

        seq = build_sequence(raster, WIDTH_DOTS, height, TOP_BLANK_ROWS, BOTTOM_BLANK_ROWS)
        print(f"发送打印序列 {len(seq)} 字节...")
        await send_chunked(client, WRITE_UUID, seq, delay=pick_delay(len(seq)))
        print("等待 0xAA 完成信号...")
        try:
            await asyncio.wait_for(done.wait(), timeout=15)
            print("✅ 收到 0xAA，打印完成")
        except asyncio.TimeoutError:
            print("⚠️ 15 秒内未收到 0xAA（可能仍在打印）")


asyncio.run(main())
