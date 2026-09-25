#!/usr/bin/env python3
"""协议通道定位：向每个可写特征发送 App 的查询命令，看哪个通道回 10 FF 帧。

用法：
    .venv/bin/python query_probe.py <打印机地址>

PrinterCommand 帧格式（来自 APK 反编译）：10 FF <cmd_hi> <cmd_lo>
"""
import asyncio
import sys
from bleak import BleakClient

QUERIES = [
    ("MAC", bytes([0x10, 0xFF, 0x30, 0x12])),
    ("VER", bytes([0x10, 0xFF, 0x20, 0xF1])),
    ("SN",  bytes([0x10, 0xFF, 0x20, 0xF2])),
]


async def main():
    addr = sys.argv[1]
    async with BleakClient(addr) as client:
        print(f"已连接 {addr}, MTU={client.mtu_size}\n")
        print("=== 全部服务（带索引，对照 App 的 getServices().get(4)）===")
        writables, notifies = [], []
        for idx, s in enumerate(client.services):
            print(f"[{idx}] 服务 {s.uuid}")
            for c in s.characteristics:
                props = ",".join(sorted(c.properties))
                tag = ""
                if "write" in props or "write-without-response" in props:
                    writables.append(c); tag += " <写>"
                if "notify" in props:
                    notifies.append(c); tag += " <通知>"
                print(f"     特征 {c.uuid}  [{props}]{tag}")
        print(f"\n可写 {len(writables)} 个, 通知 {len(notifies)} 个\n")

        def on_notify(char, data):
            print(f"  [通知 {char.uuid[:8]}] {data.hex(' ')}")

        for c in notifies:
            try:
                await client.start_notify(c.uuid, on_notify)
            except Exception as e:
                print(f"订阅失败 {c.uuid}: {e}")

        for qname, qdata in QUERIES:
            for w in writables:
                print(f"--- 向 {w.uuid[:8]} 发 {qname}: {qdata.hex(' ')}")
                try:
                    await client.write_gatt_char(w.uuid, qdata, response=False)
                except Exception as e:
                    print(f"    写失败: {e}")
                await asyncio.sleep(2.5)

        print("\n完成。重点看：哪个通道回 10 FF 帧，或回应里含 55 54 09 49 7f bf(MAC)。")


asyncio.run(main())
