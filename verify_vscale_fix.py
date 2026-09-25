#!/usr/bin/env python3
"""修正纵向比例后的验证打印：

  ① 文本任务（由 App 引擎生成的真实打印序列 /tmp/text_job.bin）
  ② 1000 行参考条，按 15ms/片 发送（短任务档）
  ③ 1000 行参考条，按 25ms/片 发送（长任务档）

②③ 用于确认「发送速率不影响行距」。若两者等长，说明行距只由打印机决定。
1000 行按 0.084mm/行 应打印约 84mm（按实测 0.086 则约 86mm）。
"""
import asyncio
import sys
from PIL import Image, ImageDraw, ImageFont
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
WB, WIDTH = 72, 576
TOP, BOTTOM = 60, 260

ENABLE = bytes([0x10, 0xFF, 0xF1, 0x03])
STOP = bytes([0x10, 0xFF, 0xF1, 0x45])
AWAKE = bytes(1024)
THICK = bytes([0x10, 0xFF, 0x10, 0x00, 0x03])   # 浓度 3（App 默认）


def font(size):
    for p in ("/System/Library/Fonts/Helvetica.ttc",
              "/System/Library/Fonts/Supplemental/Arial Bold.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()


def bar_raster(rows: int, number: int) -> bytes:
    """满宽黑条 + 角上画数字标识"""
    img = Image.new("L", (WIDTH, rows), 255)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, WIDTH - 1, rows - 1], fill=0)
    f = font(60)
    d.text((14, 14), str(number), fill=255, font=f)      # 白字挖空（反白）
    r = bytearray(WB * rows)
    px = img.load()
    for y in range(rows):
        for x in range(WIDTH):
            if px[x, y] < 128:
                r[y * WB + x // 8] |= 1 << (7 - x % 8)
    return bytes(r)


def bar_job(rows: int, number: int) -> bytes:
    body = bar_raster(rows, number)
    total = TOP + rows + BOTTOM
    seq = bytearray()
    seq += ENABLE + AWAKE + THICK
    seq += bytes([0x1D, 0x76, 0x30, 0x00, WB & 0xFF, WB >> 8, total & 0xFF, total >> 8])
    seq += bytes(WB * TOP) + body + bytes(WB * BOTTOM)
    seq += STOP
    return bytes(seq)


async def send(client, done, seq, label, delay):
    print(f"打印 {label}（{len(seq)} 字节，{delay*1000:.0f}ms/片）…")
    done.clear()
    for i in range(0, len(seq), 100):
        await client.write_gatt_char(WRITE_UUID, seq[i:i + 100], response=False)
        await asyncio.sleep(delay)
    try:
        await asyncio.wait_for(done.wait(), timeout=90)
        print(f"  ✓ {label} 完成")
    except asyncio.TimeoutError:
        print(f"  ⚠️ {label} 未收到完成信号")
    await asyncio.sleep(1.5)


async def main():
    text_job = open("/tmp/text_job.bin", "rb").read()
    done = asyncio.Event()
    async with BleakClient(ADDR) as client:
        def on_notify(char, data):
            if data == b"\xaa":
                done.set()

        await client.start_notify(WRITE_UUID, on_notify)
        await asyncio.sleep(0.5)
        await send(client, done, bar_job(2000, 4), "④ 2000 行条 @15ms（约 200KB，测大任务）", 0.015)

asyncio.run(main())
