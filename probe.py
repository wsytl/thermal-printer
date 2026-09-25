#!/usr/bin/env python3
"""对打印机做黑盒协议探测：自动发送一批候选协议帧，观察打印机反应。

用法：
    .venv/bin/python probe.py <MAC地址>
    .venv/bin/python probe.py <MAC地址> <特征UUID>   # 指定某个可写特征

每发一条，盯紧打印机：电机转？出纸？指示灯闪？有反应的那条就是突破口。
日志自动存到 probe_log.txt。
"""
import asyncio
import sys
from bleak import BleakClient


def build_frame(header: bytes, cmd: int, payload: bytes,
                endian: str = "little", checksum: bool = True) -> bytes:
    """构造类"喵喵机"自定义帧：header + 长度(2B) + cmd + payload + 校验(和)。

    这只是候选格式，不同厂商细节不同，需要实测确认。
    """
    body = bytes([cmd]) + payload
    length = len(body) + (1 if checksum else 0)
    len_b = length.to_bytes(2, "little" if endian == "little" else "big")
    frame = header + len_b + body
    if checksum:
        frame += bytes([sum(frame) & 0xFF])
    return frame


# 384 点宽 x 24 行的全黑小图（48 字节/行，共 1152 字节）
BLACK_STRIP = b"\xff" * (48 * 24)

# GS v 0 位图命令的头部（ESC 3 24 设行距 + 1D 76 30 00 + 宽48字节 + 高24行）
ESC_POS_BITMAP = b"\x1b\x33\x18" + b"\x1d\x76\x30\x00" + bytes([48, 0, 24, 0])

PROBES = [
    # --- 基础文本 / ESC/POS ---
    ("纯文本 Hello", b"Hello"),
    ("纯文本+换行", b"Hello\n"),
    ("ESC/POS 初始化 ESC @", b"\x1b\x40"),
    ("ESC/POS 初始化+文本", b"\x1b\x40ESC/POS test\n"),
    ("ESC/POS 位图黑条 GS v 0", ESC_POS_BITMAP + BLACK_STRIP),
    ("ESC/POS 走纸 ESC d 5", b"\x1b\x64\x05"),
    # --- 常见"使能/握手"序列（有的机器要先使能才收数据） ---
    ("使能试探 AA 55 01 00", b"\xaa\x55\x01\x00"),
    ("使能试探 01", b"\x01"),
    ("使能试探 00", b"\x00"),
    ("使能试探 1B 1D 66 6D 74", b"\x1b\x1d\x66\x6d\x74"),
    # --- 类喵喵机自定义帧（55 AA 55 AA 帧头） ---
    ("喵喵机帧 cmd=0x01 小图(小端+校验)", build_frame(b"\x55\xaa\x55\xaa", 0x01, BLACK_STRIP[:96])),
    ("喵喵机帧 cmd=0x01 小图(小端无校验)", build_frame(b"\x55\xaa\x55\xaa", 0x01, BLACK_STRIP[:96], checksum=False)),
    ("喵喵机帧 cmd=0x02 小图(小端+校验)", build_frame(b"\x55\xaa\x55\xaa", 0x02, BLACK_STRIP[:96])),
    ("喵喵机帧 cmd=0x01 大端+校验", build_frame(b"\x55\xaa\x55\xaa", 0x01, BLACK_STRIP[:96], endian="big")),
    ("帧头 5A A5 版 cmd=0x01", build_frame(b"\x5a\xa5\x5a\xa5", 0x01, BLACK_STRIP[:96])),
    ("帧头 AA 55 AA 55 版 cmd=0x01", build_frame(b"\xaa\x55\xaa\x55", 0x01, BLACK_STRIP[:96])),
    # --- 状态查询试探（有 notify 特征时可能回数据） ---
    ("状态查询帧 cmd=0xF0 空负载", build_frame(b"\x55\xaa\x55\xaa", 0xF0, b"")),
    ("状态查询帧 cmd=0x03 空负载", build_frame(b"\x55\xaa\x55\xaa", 0x03, b"")),
]


async def main():
    addr = sys.argv[1] if len(sys.argv) > 1 else input("打印机 MAC 地址：").strip()
    target_char = sys.argv[2] if len(sys.argv) > 2 else None
    log = open("probe_log.txt", "w", encoding="utf-8")

    def note(s: str):
        print(s)
        log.write(s + "\n")
        log.flush()

    async with BleakClient(addr) as client:
        note(f"已连接 {addr}, MTU={client.mtu_size}")

        # 找要写的特征
        write_char = None
        for service in client.services:
            for ch in service.characteristics:
                if target_char and ch.uuid.lower() == target_char.lower():
                    write_char = ch
                    break
                if not target_char and ("write" in ch.properties
                                        or "write-without-response" in ch.properties):
                    write_char = ch
                    break
            if write_char:
                break
        if not write_char:
            note("没找到可写特征！先运行 enum.py，把特征列表发出来。")
            return
        note(f"使用写特征: {write_char.uuid}  属性: {sorted(write_char.properties)}")

        # 订阅所有可通知特征，捕获任何回包
        def on_notify(uuid, data):
            note(f"  [收到通知 {uuid}] {data.hex(' ')}")

        for service in client.services:
            for ch in service.characteristics:
                if "notify" in ch.properties:
                    try:
                        await client.start_notify(ch.uuid, on_notify)
                        note(f"已订阅通知 {ch.uuid}")
                    except Exception as e:
                        note(f"订阅通知失败 {ch.uuid}: {type(e).__name__}")

        note("\n开始探测。每发一条，盯紧打印机：电机转？出纸？指示灯变化？\n")
        for i, (label, payload) in enumerate(PROBES, 1):
            note(f"[{i:02d}] {label}")
            note(f"    发送({len(payload)}B): {payload.hex(' ')}")
            try:
                await client.write_gatt_char(write_char.uuid, payload, response=False)
            except Exception as e:
                note(f"    无响应写入失败: {type(e).__name__}")
                try:
                    await client.write_gatt_char(write_char.uuid, payload, response=True)
                    note("    （改用 write-with-response 成功）")
                except Exception as e2:
                    note(f"    write-with-response 也失败: {type(e2).__name__}")
            await asyncio.sleep(2.0)  # 观察时间

        note("\n探测完成，日志已存 probe_log.txt。把该文件发回来。")


asyncio.run(main())
