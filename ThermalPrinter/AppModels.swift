//
//  AppModels.swift
//  B3 热敏打印 App —— 界面数据模型
//

import SwiftUI
import AppKit

struct PickedImage: Identifiable {
    let id = UUID()
    let image: CGImage
    let title: String
}

struct PendingImage: Identifiable {
    let id = UUID()
    let image: CGImage
    let title: String
}

struct PrintRecord: Identifiable {
    let id: UUID
    let time: Date
    let kind: String
    let title: String
    let data: Data
    let height: Int
}

