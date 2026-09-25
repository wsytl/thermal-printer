#!/usr/bin/env python3
"""打印镜像检测图：大号文字 THERMAL B3 123 + 二维码（单张，等待 0xAA 完成信号）。

文字若读起来正常 => 无镜像；若反了（321 3B GNIDUB）=> 打印机/打包镜像。
底部应干净出纸（0xAA 流控，不再连打）。
"""
import asyncio
import sys
from PIL import Image, ImageDraw, ImageFont
from bleak import BleakClient

ADDR = sys.argv[1] if len(sys.argv) > 1 else "E0FDE891-08CD-4A23-0D1E-46FAA9E38D36"
SERVICE_UUID = "e7810a71-73ae-499d-8c15-faa9aef0c3f2"
WRITE_UUID = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"
DONE = b"\xaa"

WIDTH_DOTS = 576
DENSITY = int(__import__('os').environ.get('DENSITY', '3'))  # 打印浓度 1-5
TOP_BLANK_ROWS = 60
BOTTOM_BLANK_ROWS = 260


def load_font(size):
    for path in ("/System/Library/Fonts/Helvetica.ttc",
                 "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
                 "/System/Library/Fonts/Supplemental/Arial.ttf"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def make_text_block(text: str) -> Image.Image:
    """白底黑字大号文字图，宽 576，文字垂直居中"""
    w, h = WIDTH_DOTS, 220
    img = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(img)
    for size in (150, 120, 100, 80, 64):
        font = load_font(size)
        bb = d.textbbox((0, 0), text, font=font)
        tw, th = bb[2] - bb[0], bb[3] - bb[1]
        if tw <= w - 40:
            break
    d.text(((w - tw) // 2 - bb[0], (h - th) // 2 - bb[1]), text, fill=0, font=font)
    return img


def build_raster(*blocks):
    """把若干 PIL 灰度图拼接成一张宽 576 的点阵（黑=1, MSB-first），返回 (raster, height)"""
    wb = (WIDTH_DOTS + 7) // 8
    total_h = sum(b.height for b in blocks)
    raster = bytearray(wb * total_h)
    y = 0
    for block in blocks:
        # 居中到 576 宽（不足则左右补白）
        off = (WIDTH_DOTS - block.width) // 2
        pix = block.load()
        for row in range(block.height):
            for col in range(block.width):
                if pix[col, row] < 128:
                    x = off + col
                    if 0 <= x < WIDTH_DOTS:
                        raster[(y + row) * wb + x // 8] |= 1 << (7 - (x % 8))
        y += block.height
    return bytes(raster), total_h


def build_sequence(raster: bytes, height: int) -> bytes:
    wb = (WIDTH_DOTS + 7) // 8
    total_height = height + TOP_BLANK_ROWS + BOTTOM_BLANK_ROWS
    seq = bytearray()
    seq += bytes([0x10, 0xFF, 0xF1, 0x03])       # enable
    seq += bytes(1024)                             # awake
    seq += bytes([0x10, 0xFF, 0x10, 0x00, DENSITY])  # 打印浓度
    seq += bytes([0x1D, 0x76, 0x30, 0x00,
                  wb & 0xFF, wb >> 8,
                  total_height & 0xFF, total_height >> 8])
    seq += bytes(wb * TOP_BLANK_ROWS)
    seq += raster
    seq += bytes(wb * BOTTOM_BLANK_ROWS)
    seq += bytes([0x10, 0xFF, 0xF1, 0x45])        # stop
    return bytes(seq)


def pick_delay(nbytes: int) -> float:
    """速率分档：≤50KB → 15ms/片；>50KB → 25ms/片（打印机消化 ≈4KB/s，过快会丢尾部数据）"""
    return 0.015 if nbytes <= 50_000 else 0.025


async def send_chunked(client, char_uuid, data, chunk=100, delay=0.015):
    for i in range(0, len(data), chunk):
        await client.write_gatt_char(char_uuid, data[i:i + chunk], response=False)
        await asyncio.sleep(delay)


async def main():
    import qrcode
    from qrcode.constants import ERROR_CORRECT_H
    # 文字块（镜像检测）
    text_img = make_text_block("THERMAL B3 123")
    # 二维码块
    qr = qrcode.QRCode(version=None, error_correction=ERROR_CORRECT_H, box_size=8, border=4)
    qr.add_data("BUDING-B3 PRINT OK 2026")
    qr.make(fit=True)
    qr_img = qr.make_image(fill_color="black", back_color="white").convert("L")
    # 二维码也居中到 576 宽
    qr_canvas = Image.new("L", (WIDTH_DOTS, qr_img.height), 255)
    qr_canvas.paste(qr_img, ((WIDTH_DOTS - qr_img.width) // 2, 0))
    qr_canvas.save("mirror_test.png")

    raster, height = build_raster(text_img, qr_canvas)
    seq = build_sequence(raster, height)
    print(f"序列 {len(seq)} 字节，图案高 {height} 行")

    done = asyncio.Event()

    def on_notify(char, data):
        print(f"  [通知 {char.uuid[:8]}] {data.hex(' ')}")
        if data == DONE:
            done.set()

    async with BleakClient(ADDR) as client:
        print(f"已连接 {ADDR}")
        await client.start_notify(WRITE_UUID, on_notify)
        await asyncio.sleep(0.5)
        # 握手查询（App 连接后第一步）
        await client.write_gatt_char(WRITE_UUID, bytes([0x10, 0xFF, 0x30, 0x12]), response=True)
        await asyncio.sleep(1.0)
        await send_chunked(client, WRITE_UUID, seq, delay=pick_delay(len(seq)))
        print("发送完毕，等待 0xAA 完成信号...")
        try:
            await asyncio.wait_for(done.wait(), timeout=15)
            print("✅ 收到 0xAA，打印完成")
        except asyncio.TimeoutError:
            print("⚠️ 15 秒内未收到 0xAA")


if __name__ == "__main__":
    asyncio.run(main())
