#!/usr/bin/env python3
"""连接打印机，枚举全部服务/特征/属性，尝试读取并订阅通知。

用法：
    .venv/bin/python enum.py <MAC地址>

把完整输出原样发回来，我可以根据 UUID 直接判断芯片/方案。
"""
import asyncio
import sys
from bleak import BleakClient


async def main():
    addr = sys.argv[1] if len(sys.argv) > 1 else input("打印机 MAC 地址：").strip()
    async with BleakClient(addr) as client:
        print(f"已连接：{addr}   MTU={client.mtu_size}")
        for service in client.services:
            print(f"\n服务 {service.uuid}")
            for ch in service.characteristics:
                props = ",".join(sorted(ch.properties))
                print(f"  特征 {ch.uuid}  属性[{props}]")
                for desc in ch.descriptors:
                    print(f"    描述符 {desc.uuid}")
                if "read" in ch.properties:
                    try:
                        v = await asyncio.wait_for(client.read_gatt_char(ch.uuid), timeout=2.0)
                        print(f"    -> 读取值: {v.hex(' ')}")
                    except Exception as e:
                        print(f"    -> 读取失败: {type(e).__name__}")

        def on_notify(uuid, data):
            print(f"  [收到通知] {uuid}: {data.hex(' ')}")

        for service in client.services:
            for ch in service.characteristics:
                if "notify" in ch.properties:
                    try:
                        await client.start_notify(ch.uuid, on_notify)
                        print(f"已订阅通知：{ch.uuid}")
                    except Exception as e:
                        print(f"订阅失败 {ch.uuid}: {type(e).__name__}")

        print("\n等待 5 秒接收通知（期间可以按打印机的走纸键试试）...")
        await asyncio.sleep(5.0)

    print("\n完成。请把上面全部输出原样发回来。")


asyncio.run(main())
