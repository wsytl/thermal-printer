//
//  PrinterControllerDelegates.swift
//  B3 热敏打印 App —— CoreBluetooth 代理实现
//
//  扫描/连接/服务发现/通知订阅与收包；状态变更统一切回主线程再更新 @Published。
//

import Foundation
import CoreBluetooth
import AppKit

// MARK: - CBCentralManagerDelegate

extension PrinterController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                log("蓝牙已就绪")
            case .unauthorized:
                log("未授权蓝牙：请在 系统设置 → 隐私与安全性 → 蓝牙 中允许本 App")
            case .poweredOff:
                log("蓝牙已关闭")
            default:
                log("蓝牙状态变化：\(central.state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        Task { @MainActor in
            let name = peripheral.name ?? peripheral.identifier.uuidString
            // 注意：这里的 "Buding" 是打印机硬件自己广播的设备名（Buding-B3-xxxx_BLE），
            // 属于设备识别条件，不是本项目名称，不能改
            guard name.contains("Buding") || name.contains("buding") || name.lowercased().contains("b3")
            else { return }
            if !discovered.contains(where: { $0.identifier == peripheral.identifier }) {
                discovered.append(peripheral)
                log("发现：\(name)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            log("已连接，正在发现服务…")
            peripheral.discoverServices([PrinterController.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            log("连接失败：\(error?.localizedDescription ?? "未知错误")")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            isConnected = false
            connectedName = nil
            writeChar = nil
            log("已断开连接")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension PrinterController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil else {
                log("服务发现失败：\(error!.localizedDescription)")
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == PrinterController.serviceUUID }) else {
                log("未找到数据服务（e7810a71…），请确认型号为 B3")
                return
            }
            log("找到数据服务，发现特征…")
            peripheral.discoverCharacteristics([PrinterController.writeUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            guard error == nil else {
                log("特征发现失败：\(error!.localizedDescription)")
                return
            }
            guard let char = service.characteristics?.first(where: { $0.uuid == PrinterController.writeUUID }) else {
                log("未找到数据特征（bef8d6c9…）")
                return
            }
            writeChar = char
            if char.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: char)
            }
            isConnected = true
            connectedName = peripheral.name
            log("✅ 就绪：\(peripheral.name ?? "打印机")")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                log("订阅通知失败：\(error.localizedDescription)")
            } else if characteristic.isNotifying {
                log("已订阅通知")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        Task { @MainActor in
            handleReceived(bytes)
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        // CoreBluetooth 缓冲满时会回调此方法；当前靠 12ms 间隔限速，预留扩展
    }
}
