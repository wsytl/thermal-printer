//
//  PrinterController.swift  (macOS)
//  CoreBluetooth 连接与打印控制（B3 热敏）
//
//  连接流：扫描 → 连接 → 发现服务 → 订阅通知 → 就绪
//  打印流：分片发送（100B/片, 12ms）→ 等待打印机 0xAA"完成"信号 → 下一张
//

import Foundation
import CoreBluetooth
import AppKit

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

    // 打印进度（发送阶段 0...1；等待完成信号时为 nil 但 isPrinting 仍为 true）
    @Published var sendingProgress: Double?
    @Published var queueCount = 0
    @Published var currentJobLabel: String?

    // MARK: - 私有

    // 以下成员被 PrinterControllerDelegates.swift 的代理扩展访问，故为 internal
    // （Swift 的 private 不能跨文件访问；它们是 BLE 会话状态，不对外暴露 API）
    private(set) var central: CBCentralManager!
    private(set) var peripheral: CBPeripheral?
    var writeChar: CBCharacteristic?      // 代理扩展里订阅成功后写入
    private var doneContinuation: CheckedContinuation<Bool, Never>?
    private var writeContinuation: CheckedContinuation<Void, Never>?   // 带响应写入的等待
    private var jobStart = Date()                                      // 统计发送耗时
    private var printQueue: [(data: Data, label: String, onDone: ((Bool) -> Void)?)] = []
    private var isFlushing = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 日志

    func log(_ s: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logText += "[\(stamp)] \(s)\n"
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
        isScanning = true
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
        case .unauthorized:
            log("⚠️ 未授权蓝牙：请在 系统设置 → 隐私与安全性 → 蓝牙 中允许本 App")
            isScanning = false
        case .poweredOff:
            log("⚠️ 蓝牙已关闭：请打开 Mac 的蓝牙（菜单栏蓝牙图标 或 系统设置 → 蓝牙）")
            isScanning = false
        default:
            log("蓝牙状态：\(central.state.rawValue)")
            isScanning = false
        }
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

    /// 加入打印队列（按序执行）。onDone 在该任务完成后回调（success = 是否收到完成信号）。
    func enqueue(data: Data, label: String, onDone: ((Bool) -> Void)? = nil) {
        guard isConnected, writeChar != nil else {
            log("未连接打印机")
            return
        }
        printQueue.append((data, label, onDone))
        queueCount = printQueue.count
        log("加入队列：\(label)，\(data.count) 字节（队列 \(printQueue.count) 个任务）")
        flushQueueIfNeeded()
    }

    /// 取消队列中尚未开始的任务（当前正在打印的无法中断）
    func cancelQueue() {
        let removed = printQueue.count
        printQueue.removeAll()
        queueCount = 0
        if removed > 0 {
            log("已取消 \(removed) 个排队任务")
        }
    }

    private func flushQueueIfNeeded() {
        guard !isFlushing, !printQueue.isEmpty else { return }
        isFlushing = true
        Task { [weak self] in
            guard let self else { return }
            while !self.printQueue.isEmpty {
                let job = self.printQueue.removeFirst()
                self.queueCount = self.printQueue.count
                let success = await self.executePrint(data: job.data, label: job.label)
                job.onDone?(success)
            }
            self.isFlushing = false
        }
    }

    /// 执行单个打印任务：分片发送（等应答）→ 等待 0xAA 完成信号
    private func executePrint(data: Data, label: String) async -> Bool {
        guard let peripheral, let writeChar else {
            log("打印中断：连接丢失")
            return false
        }
        isPrinting = true
        currentJobLabel = label
        sendingProgress = 0
        jobStart = Date()
        log("开始打印：\(label)…")

        // 用「带响应写入」：每片等打印机 ATT 应答再发下一片，由打印机自己节流。
        // 官方 App 亦为此方式（Android 默认 WRITE_TYPE_DEFAULT）——withoutResponse
        // 在长任务/密内容时会静默丢包，表现为图案变短、缺底部边距。
        let maxLen = peripheral.maximumWriteValueLength(for: .withResponse)
        let chunk = max(20, min(PrintEngine.chunkSize, maxLen))
        var idx = 0
        while idx < data.count {
            let end = min(idx + chunk, data.count)
            await writeChunk(data.subdata(in: idx..<end), to: writeChar, on: peripheral)
            idx = end
            sendingProgress = Double(idx) / Double(data.count)
        }
        sendingProgress = nil
        log(String(format: "数据发送完毕（%d 字节，用时 %.1fs），等待打印机完成信号…",
                   data.count, Date().timeIntervalSince(jobStart)))

        // 等待 0xAA（长任务打印慢，给足 60 秒）
        let gotDone = await waitForDone(timeout: 60)
        isPrinting = false
        currentJobLabel = nil
        if gotDone {
            log("✅ 打印完成：\(label)")
        } else {
            log("⚠️ 未收到完成信号（可能仍在打印或连接异常）：\(label)")
        }
        return gotDone
    }

    /// 带响应写入单片，等 didWriteValueFor 回调（回调在代理扩展里调用 finishWrite）
    private func writeChunk(_ data: Data, to char: CBCharacteristic, on peripheral: CBPeripheral) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writeContinuation = cont
            peripheral.writeValue(data, for: char, type: .withResponse)
        }
    }

    /// 由代理扩展在 didWriteValueFor 时调用
    func finishWrite() {
        writeContinuation?.resume()
        writeContinuation = nil
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

    /// 收到打印机通知（由代理扩展调用）
    func handleReceived(_ bytes: [UInt8]) {
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
