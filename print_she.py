#!/usr/bin/env python3
"""用 Python 打印 she.jpg（应用 EXIF + 缩放到 576 宽），验证 App 与打印机哪个环节比例不对。"""
import asyncio, sys
from PIL import Image, ImageOps
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
SERVICE_UUID = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WIDTH_DOTS = 576
DENSITY = int(__import__('os').environ.get('DENSITY', '3'))  # 打印浓度 1-5
TOP_BLANK_ROWS = 60
BOTTOM_BLANK_ROWS = 260
DELAY = 0.025   # >50KB 长任务，4KB/s

# 加载 + 应用 EXIF + 缩放到 576 宽 + 纵向预拉伸 1.75（打印机纵向行距约 21 行/mm，比横向密 1.75 倍）
img = Image.open("she.jpg")
img = ImageOps.exif_transpose(img).convert("L")
w, h = img.size
scale = WIDTH_DOTS / w
new_h = max(1, round(h * scale * 1.75))
img = img.resize((WIDTH_DOTS, new_h), Image.LANCZOS)
print(f"源 {w}x{h} → 点阵 {WIDTH_DOTS}x{new_h}（打印应约 48 x {new_h*0.047:.0f} mm，比例 {WIDTH_DOTS/new_h:.3f}）")

wb = WIDTH_DOTS // 8
raster = bytearray(wb * new_h)
pix = img.load()
for y in range(new_h):
    for x in range(WIDTH_DOTS):
        if pix[x, y] < 128:
            raster[y * wb + x // 8] |= 1 << (7 - x % 8)

total = new_h + TOP_BLANK_ROWS + BOTTOM_BLANK_ROWS
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
print(f"序列 {len(SEQ)} 字节，发送速率 {1/(0.100*DELAY):.1f}KB/s")

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
            await asyncio.sleep(DELAY)
        print("发送完毕，等待 AA...")
        try:
            await asyncio.wait_for(done.wait(), timeout=60)
            print("✅ AA 收到，任务完成")
        except asyncio.TimeoutError:
            print("⚠️ 未收到 AA")

asyncio.run(main())
