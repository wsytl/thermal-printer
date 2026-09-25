# B3 热敏打印 App（个人自用）

用自己的设备给B3 热敏打印机打印图片/二维码。协议已通过实际打印验证
（二维码像素级正确、文字无镜像、`0xAA` 流控正常）。仅供个人使用。

**推荐用 Mac 版**：不需要开发者账号，直接就能跑。

## 目录

- `ThermalPrinter/` — **Mac 版源码**（SwiftUI + CoreBluetooth，推荐）
- `ThermalPrinter.xcodeproj/` — Mac 版 Xcode 工程（已编译验证 ✅）
- `ThermalPrinteriOS/` — iOS 版源码（需开发者签名，备用）
- `ThermalPrinteriOS.xcodeproj/` — iOS 版工程
- `print_mirror_test.py` / `print_qr.py` — Mac 命令行打印脚本（协议验证用）
- `NOTES.md` — 完整逆向笔记（协议细节、已知问题）

---

## 一、Mac 版（推荐，无需开发者账号）

### 运行方式（二选一）

**方式 A（最简单）— 直接运行已编译好的 App：**

双击打开：`build_mac/sym/Release/ThermalPrinter.app`

（如果以后用 Xcode 重新编译过，产物在 Xcode 的 DerivedData 里，也可以在
Xcode 里直接运行，见方式 B。）

**方式 B — 用 Xcode 运行：**

1. 双击 `ThermalPrinter.xcodeproj` 打开
2. 点工具栏的运行按钮（▶）或按 ⌘R
3. 不需要任何开发者账号（工程已设置为 "Sign to Run Locally" 本地签名）

### 首次运行：授权蓝牙

1. 启动后系统会弹窗 **"ThermalPrinter 想要访问蓝牙"** → 点**允许**
2. 如果没弹窗或点过"不允许"：打开 **系统设置 → 隐私与安全性 → 蓝牙**，
   把 `ThermalPrinter` 的开关打开（找不到就重启 App 一次）
3. 确保 Mac 蓝牙已开启（菜单栏蓝牙图标 或 系统设置 → 蓝牙）

### 使用步骤

1. 打开 App → 自动扫描并自动连接（按**打印机广播的设备名** `Buding-B3-…` 自动连上）
2. 顶部切换三种打印模式：
   - **文本**：输入文字 → 排版（横排/竖排）、对齐、**字体**、**字号**（20–300 滑块 + 快捷档）、
     行距/字距、**粗体/斜体/下划线/反白** → 右侧预览 → 打印文本
   - **二维码**：输入网址/文字/WiFi/名片等内容 → 打印二维码（48×48mm，纠错 H）
   - **图片**：选择一张或多张图片 → 亮度/对比度/抖动 → 打印全部；
     点单张的「编辑」打开**图片编辑器**（见下）
3. 底部「打印历史」可查看记录并重新打印；「显示/隐藏日志」可看连接与打印细节
4. 打印中可看发送进度、取消排队任务

### 打印预览（三种模式都有）

三种模式右侧都有**公共打印预览栏**（文本 / 二维码 / 图片）：

- 「**原图**」：源图（文本图 / 二维码 / 照片）
- 「**打印效果**」：纸上的实际 1 位点阵效果（含抖动纹理），**按源图比例显示**，
  与真实打印比例一致；下方显示预计打印尺寸（mm）

> 图片模式点缩略图即可切换预览对象；点「编辑」进入图片编辑器（编辑器内也复用同一预览组件）。

### 文本打印功能一览

| 分类 | 选项 |
|---|---|
| 排版 | **横排 / 竖排**（竖排逐字堆叠）；对齐：左 / 中 / 右 |
| 字体 | 系统默认、苹方（黑体）、宋体、楷体、冬青黑体、华文黑体、圆体、Menlo、Times、Arial |
| 字号 | 20–300 滑块 + 快捷档（小 60 / 中 100 / 大 150 / 特大 220） |
| 间距 | 行距 −20…80、字距 −8…40 |
| 样式 | 粗体、斜体、下划线、**反白**（黑底白字，适合做标签标题） |
| 预览 | 右侧公共预览栏：原图 / 打印效果 + 预计打印尺寸 |

> 所有字体均为 macOS 自带且支持中文，换行按 576 点宽（约 496 点内容宽）自动折行。

### 图片编辑器（裁剪 / 旋转 / 镜像 / 翻转）

点图片缩略图下的「编辑」打开，左侧是预览、右侧是控制：

| 功能 | 说明 |
|---|---|
| 旋转 | 左转 90° / 右转 90°（顺时针）/ 180° |
| 镜像 | 左右镜像（水平翻转）、上下翻转（垂直翻转） |
| 裁剪 | 拖动方框移动 + 宽/高滑块；比例预设：自由 / 1:1 / 4:3 / 3:4 / 16:9 |
| 打印效果 | 亮度、对比度、抖动（Floyd–Steinberg） |
| 预览 | 「编辑」标签看几何变换；「**打印预览**」标签看纸上**实际 1 位点阵效果** |
| 重置 | 一键恢复原图与默认参数 |

底部实时显示预计打印尺寸（mm）与点阵行数。旋转/镜像/裁剪按此顺序应用，
打印时再按 1.75 纵向修正生成点阵。

> 注意：**iOS 模拟器不支持蓝牙**（苹果限制），Mac 上请用这个 Mac 版 App，
> 或者把 iOS 版装到真 iPhone 上（需要开发者签名，见下）。

---

## 二、iOS 版（备用，需要签名）

在没有开发者账号时无法安装到 iPhone（免费 Apple ID 有 3 台设备注册上限）。
若以后有账号：

1. Xcode 打开 `ThermalPrinteriOS.xcodeproj` → Target `ThermalPrinteriOS` →
   Signing & Capabilities → Team 选你的账号（勾 Automatically manage signing）
2. 确认 Bundle Identifier = `com.wsytl.ThermalPrinteriOS`
3. iPhone 数据线连接 → 顶部选 iPhone → ⌘R
4. 手机「设置→通用→VPN与设备管理」信任开发者证书（7 天过期重跑一次）

---

## 三、打印原理（要点）

- 数据通道：服务 `e7810a71-73ae-499d-8c15-faa9aef0c3f2`
  特征 `bef8d6c9-9c21-4c9e-b632-bd58c1009f9f`（notify + write）
- 打印序列：`enable(10 FF F1 03)` + `awake(1024×00)` + `GS v 0 光栅`(576点宽) + `stop(10 FF F1 45)`
- ⚠️ **绝不发送官方的 `0F 4A`(lineDots)**：实测它是固件"打印引导页"的触发命令，
  会导致每次打印前多出 "J扫J"（二维码 + "扫描二维码，查看按键的使用方法"）
- 上下留白全部放在位图里（lineDots 不是走纸命令，见上）；底部留白需足够长才能出纸口
  （底部 260 行 ≈2.2cm，保证撕纸时可见约 1cm）
- **打印浓度**：`10 FF 10 00 <1...5>`（越大越深，默认 3）。底部栏可调；
  不发送时打印机用出厂默认（偏淡）
- 纵向行距修正：打印机纵向约 21 行/mm（比横向 300dpi 密 1.75 倍），
  生成点阵前图像高度预拉伸 1.75 倍，打印比例才正确
- 传输：100 字节/片、write-without-response；短任务（≤50KB）15ms/片、
  长任务 25ms/片（打印机消化速度约 4KB/s，过快会丢尾部数据）
- 每张打印完成后打印机发 `0xAA`，App 等它再打下一张（避免连打丢数据）

## 四、已知问题（详见 NOTES.md 第七节）

- 每张打印前纸顶部会出现一小段固件引导页（"J扫J"/"扫码二维码…"字样），
  固件行为，暂无法去除，不影响图案本身。
- 如需调参数（留白行数、分片大小、延时），改
  `ThermalPrinter/PrintEngine.swift` 顶部的常量即可。

## 五、协议参数回归自检

改动代码后，建议先跑一遍协议自检（不需要打印机、不耗纸），确认三种模式的打印序列
仍然符合已验证的参数：

```bash
cd <项目目录>
swiftc -O ThermalPrinter/PrintEngine.swift verify_protocol.swift -o /tmp/verify_protocol && /tmp/verify_protocol
```

会逐项检查：enable/awake/GS v 0 结构、不含 0F 4A（引导页触发命令）、每行 72 字节（576 点）、
高度字段 = 图案行数 + 顶 60 + 底 260、数据长度自洽、纵向 1.75 修正、
传输速率分档（≤50KB 快档 / >50KB 慢档）、**文本朝向**（防倒置回归）、
**图片变换方向**（左右镜像/上下翻转/左右旋转 90° 的方向 + 恒等式还原）、
**文本样式**（竖排高宽比、反白黑底占比、粗体生效）。

## 六、相关文件

### 源码结构（`ThermalPrinter/`，按职责分文件）

| 文件 | 作用 |
|---|---|
| **引擎层** | |
| `PrintEngine.swift` | 协议核心：常量、打印序列组装、任务工厂、速率分档 |
| `PrintEngineRaster.swift` | 光栅化：灰度/阈值、亮度对比度、Floyd–Steinberg 抖动、点阵→预览图 |
| `PrintEngineText.swift` | 文本渲染：`TextStyle`、字体解析、CoreText 绘制（竖排/反白等） |
| `PrintEngineImage.swift` | 图片：EXIF 加载、裁剪、旋转/镜像/翻转 |
| **BLE 层** | |
| `PrinterController.swift` | 连接与打印队列（分片发送、进度、取消） |
| `PrinterControllerDelegates.swift` | CoreBluetooth 代理：扫描/连接/服务发现/收包 |
| **模型层** | |
| `PrintSettings.swift` | 打印设置（亮度/对比度/抖动/浓度 + 文本排版），派生 `rasterOptions`/`textStyle` |
| `PrintHistory.swift` | 打印历史（含落盘持久化） |
| `AppModels.swift` | `PickedImage` / `PendingImage` / `PrintRecord` |
| **视图层** | |
| `ContentView.swift` | 主界面：状态栏、模式切换、日志、底部栏、历史面板（只做协调） |
| `TextPrintView.swift` / `QRPrintView.swift` / `ImagePrintView.swift` | 三种打印模式视图 |
| `ImageEditorSheet.swift` | 图片编辑器（裁剪/旋转/镜像/翻转 + 打印预览） |
| `PrintPreviewPane.swift` | 公共打印预览组件（三模式 + 编辑器共用） |
| `ThermalPrinterApp.swift` | App 入口 |

### 项目其它文件

| 文件 | 作用 |
|---|---|
| `verify_protocol.swift` | 协议参数回归自检工具（无需打印机） |
| `NOTES.md` | 逆向全过程笔记（协议表、流控、已知问题、浓度/引导页实验） |
| （不含）厂商参考资料 | 官方 App 反编译源码与固件镜像**不在本仓库**（避免再分发厂商代码），另存于私有仓库 `thermal-printer-vendor-ref`；已确认的协议结论都写进了 `NOTES.md` |
| `probe_banner.py` / `probe_density.py` | 命令探测脚本（引导页触发条件 / 浓度对照） |
| `gh_tunnel.py` | 推送用本地隧道：本机 DNS 把 github.com 解析到被墙 IP 时，把流量转发到可用 IP（见脚本头注释） |
