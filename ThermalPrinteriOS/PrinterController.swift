//
//  PrinterController.swift
//  CoreBluetooth 连接与打印控制（B3 热敏）
//
//  连接流：扫描 → 连接 → 发现服务 → 订阅通知 → 就绪
//  打印流：分片发送（100B/片, 12ms）→ 等待打印机 0xAA"完成"信号 → 下一张
//

import Foundation
import CoreBluetooth
import UIKit

@MainActor
final class PrinterController: NSObject, ObservableObject {

    // MARK: - 常量（实测确认，见 NOTES.md）

    static let serviceUUID = CBUUID(string: "e7810a71-73ae-499d-8c15-faa9aef0c3f2")
    static let writeUUID  = CBUUID(string: "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f")
    static let doneByte: UInt8 = 0xAA       // 打印"完成"信号
    static let okBytes: [UInt8] = [0x4F, 0x4B]  // "OK" 打印"开始"信号

    // MARK: - 发布状态

    @Published var isScanning = false
    @Published var discovered: [CBPeripheral] = []
    @Published var connectedName: String?
    @Published var isConnected = false
    @Published var isPrinting = false
    @Published var logText = ""

    // MARK: - 私有

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var doneContinuation: CheckedContinuation<Bool, Never>?
    private var printQueue: [(Data, String)] = []   // 待打印任务
    private var isFlushing = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 日志

    func log(_ s: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logText += "[\(stamp)] \(s)\n"
        // 只保留最近 200 行，避免无限增长
        let lines = logText.split(separator: "\n")
        if lines.count > 200 {
            logText = lines.suffix(200).joined(separator: "\n") + "\n"
        }
    }

    // MARK: - 扫描 / 连接

    func scan() {
        stopScan()
        discovered = []
        log("开始扫描…")
        #if targetEnvironment(simulator)
        // iOS 模拟器不支持 CoreBluetooth（苹果限制），永远连不上真实打印机
        log("⚠️ 模拟器不支持蓝牙！请把 App 装到真 iPhone 上才能连接打印机。")
        log("（真机安装步骤见 README：Xcode 里选你的 iPhone 设备后 ⌘R）")
        isScanning = false
        #else
        isScanning = true
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
        } else {
            log("蓝牙状态：\(central.state.rawValue)，请先在系统设置中允许蓝牙")
            isScanning = false
        }
        #endif
    }

    func stopScan() {
        isScanning = false
        central.stopScan()
    }

    func connect(_ p: CBPeripheral) {
        stopScan()
        log("正在连接 \(p.name ?? p.identifier.uuidString)…")
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    // MARK: - 打印

    func printQR(text: String) {
        guard let job = PrintEngine.makeQRPrintData(text: text) else {
            log("二维码生成失败")
            return
        }
        enqueue(data: job.data, label: "二维码")
    }

    func printImage(_ image: UIImage) {
        guard let job = PrintEngine.makePrintData(from: image) else {
            log("图片转换失败")
            return
        }
        enqueue(data: job.data, label: "图片(\(job.height)行)")
    }

    private func enqueue(data: Data, label: String) {
        guard isConnected, writeChar != nil else {
            log("未连接打印机")
            return
        }
        printQueue.append((data, label))
        log("加入队列：\(label)，\(data.count) 字节（队列 \(printQueue.count) 个任务）")
        flushQueueIfNeeded()
    }

    private func flushQueueIfNeeded() {
        guard !isFlushing, !printQueue.isEmpty else { return }
        isFlushing = true
        Task { [weak self] in
            guard let self else { return }
            while !self.printQueue.isEmpty {
                let (data, label) = self.printQueue.removeFirst()
                await self.executePrint(data: data, label: label)
            }
            self.isFlushing = false
        }
    }

    /// 执行单个打印任务：分片发送 → 等待 0xAA 完成
    private func executePrint(data: Data, label: String) async {
        guard let peripheral, let writeChar else {
            log("打印中断：连接丢失")
            return
        }
        isPrinting = true
        log("开始打印：\(label)…")

        // 分片发送（withoutResponse + 12ms 间隔）
        let chunk = PrintEngine.chunkSize
        var idx = 0
        while idx < data.count {
            let end = min(idx + chunk, data.count)
            let slice = data.subdata(in: idx..<end)
            peripheral.writeValue(slice, for: writeChar, type: .withoutResponse)
            idx = end
            try? await Task.sleep(nanoseconds: UInt64(PrintEngine.interChunkDelay * 1e9))
        }
        log("数据发送完毕（\(data.count) 字节），等待打印机完成信号…")

        // 等待 0xAA（最长 15 秒）
        let gotDone = await waitForDone(timeout: 15)
        isPrinting = false
        if gotDone {
            log("✅ 打印完成：\(label)")
        } else {
            log("⚠️ 未收到完成信号（可能仍在打印或连接异常）：\(label)")
        }
    }

    /// 等待打印机发来 0xAA
    private func waitForDone(timeout: TimeInterval) async -> Bool {
        if doneContinuation != nil { return false }
        return await withCheckedContinuation { cont in
            doneContinuation = cont
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                if let c = doneContinuation {
                    doneContinuation = nil
                    c.resume(returning: false)
                }
            }
        }
    }

    // MARK: - 收到数据

    private func handleReceived(_ bytes: [UInt8]) {
        if bytes.count == 1 && bytes[0] == PrinterController.doneByte {
            log("收到 0xAA（打印完成）")
            if let c = doneContinuation {
                doneContinuation = nil
                c.resume(returning: true)
            }
        } else if bytes == PrinterController.okBytes {
            log("收到 OK（打印开始）")
        } else {
            log("收到数据：\(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension PrinterController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                log("蓝牙已就绪")
            case .unauthorized:
                log("未授权蓝牙，请在 设置→隐私与安全性→蓝牙 中允许")
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
