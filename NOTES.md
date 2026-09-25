# B3 热敏打印机逆向笔记（协议已打通 ✅）

> 最终更新：2026-09-24 —— 打印验证通过（二维码可扫、像素级正确）

## 一、设备信息

- 广播名：`Buding-B3-7FBF_BLE`；型号 B3；固件 `V1.10-1`；SN `B3232200092`
- macOS 连接地址（系统 UUID）：`E0FDE891-08CD-4A23-0D1E-46FAA9E38D36`（换机/重扫可能变）
- MTU：240 协商成功
- 打印头：**576 点宽**（300dpi 的 2 寸机，48mm 纸）—— App 型号注册表：
  `PrinterModel.init("Buding-B3-", ..., 576.0f, 4.8f, true)`（B1=384点，B5=576点）
- BLE SoC：杰理（Jieli）"3121 Mou Ble" 方案；内部引擎 TSPL 系（`MFG:APRT;CMD:XPP,XL;MDL:B3;CLS:PRINT`）

## 二、GATT 通道（决定性结论）

- **数据/命令通道**：服务 `e7810a71-73ae-499d-8c15-faa9aef0c3f2`
  特征 `bef8d6c9-9c21-4c9e-b632-bd58c1009f9f`（notify + write + write-without-response）
- App 取 `gatt.getServices().get(4)`（第 5 个服务）的第 0 个特征 —— 即上面这对
- `FF00/FF02/FF03` 三件套：只回 ACK（`01 01`），不是打印数据通道（早期误判）

## 三、命令帧（`10 FF <cmd_hi> <cmd_lo> [payload]`，查询回 ASCII）

| 命令 | 字节 | 实测回应 |
|---|---|---|
| queryMAC | `10 FF 30 12` | 12 字节 MAC×2 |
| queryVersion | `10 FF 20 F1` | ASCII "V1.10-1" |
| querySN | `10 FF 20 F2` | ASCII "B3232200092" |
| queryPower | `10 FF 50 F1` | 2 字节（电量） |
| queryStatus | `10 FF 40 00` | 状态（0=正常） |
| queryShuttime | `10 FF 13 00` | 1~2 字节 |
| setShuttime | `10 FF 12 00 <b>` | "OK" |
| setPrintThickness | `10 FF 10 00 <b>` | |
| **enablePrinter** | `10 FF F1 03` | "OK"（任务开始） |
| **stopPrint** | `10 FF F1 45` | |
| **awake** | 1024 × `0x00` | 唤醒（疑似触发引导页，见已知问题） |
| **printLineDots(b)** | `0F 4A <b> 00` | 实测不走纸（无效边距命令？） |
| **imageCommand** | `1D 76 30 <m> xL xH yL yH` + 点阵 | GS v 0 光栅；m=0 可用 |
| compressHeader | `1F 00 01 00` + w + h + 4B LE 长度 + 压缩数据 | 压缩路径（未用，原生算法未知） |

- **加密 m 字节**（printEncrypt=true）：`m = ((wb&15)&(height>>4)) | (((height>>4)|(wb&15))<<4) & 0xFF`
  实测 **m=0 也能打印**（非压缩路径不校验）
- **点阵打包**：黑=1，每行 MSB-first，`wb = ceil(width/8)` 字节/行

## 四、打印序列（已验证 ✅）

```
enable(10 FF F1 03)
awake(1024×00)
GS v 0: 1D 76 30 00 <wb_L> <wb_H> <h_L> <h_H>
[顶部空白行 wb×N 字节]
[点阵数据]
[底部空白行 wb×N 字节]   ← 保证图案完全出纸（约 1cm ≈ 118 行）
stop(10 FF F1 45)
```

> ⚠️ **不要发官方的 `0F 4A`（lineDots）命令！** 实测它是固件"打印引导页"的触发命令，
> 每次打印会在最前面多出一段 **"J扫J"**（二维码 + "扫描二维码，查看按键的使用方法"）。
> 去掉后引导页完全消失（2026-09-25 六组对照实验确认，见第十节）。
> 我们的上下留白全部放在位图里，本来也不需要 lineDots（它本身并不走纸）。

- 留白：顶部 60 行 + 底部 **260 行（≈2.2cm）**（300dpi 下 118 点/cm）
  - **底部边距原理（2026-09-25 实测）**：打印头到出纸口约有 2cm+ 距离。
    任务结束后尾部留白**确实打印了**，但若不够长会留在打印机内部（黑线标记实验证实），
    在出纸口撕纸就看不到留白。所以底部空白必须 ≥ 头到口距离 + 想要的可见留白。
    260 行 ≈2.2cm 保证撕纸时看到约 1cm 空白。
- **纵向行距修正系数 = 1.75（2026-09-25 重大发现）**：
  - 实测（照片 OpenCV 像素测量 + 尺子交叉验证）：打印机横向 11.9 点/mm（300dpi），
    但**纵向每行位图只走纸约 0.047mm（≈21 行/mm）**——比横向密 1.75 倍。
  - 后果：所有图案被纵向压缩 1.75 倍（方块 500 行实测 ~42×24mm 而非 42×42；
    she.jpg 1559 行实测 72mm 而非 131mm；980 行图案照片实测高≈宽）。
  - 修复：生成点阵前把图像高度**预拉伸 1.75 倍**（App `verticalCorrection`，Python 同样），
    打印出来比例即正确。QR 也走此路径 → 二维码打出来为正方形。
  - 证据链：双块测试 400/700 行 → 19.5/32.5mm（21 行/mm）；she.jpg → 72mm（21 行/mm）；
    照片 980 行 vs 576 点 → 压缩 0.575；底部 260 行 ≈1.2cm 可见（若 300dpi 应为 2.2cm）。
    早期"方块 42×42mm"与"1008 行 85.5mm"为误测（与上述证据矛盾）。
  - 待用户验证：App 打印 she.jpg 比例应恢复正确；若仍有偏差，按 48/实测高微调系数。
- 传输：write-without-response，100B/片。**速率必须按任务大小分档（2026-09-25 实测标定）**：
  - **≤50KB：15ms/片（≈6.6KB/s）**——短任务（二维码等）快且安全
  - **>50KB：25ms/片（≈4.0KB/s）**——长任务必须 ≤ 打印机消化速度
  - 根因：打印机处理**纯黑内容**的消化速度 ≈ **4KB/s**，模块缓冲 ≈ **24KB**；
    发送快于消化 → 缓冲填满 → **任务尾部数据丢失**（图案打了但无底部留白、
    收不到 0xAA、任务挂起）。实测：500 方块 49.9KB @8.3KB/s 失败、@7.7KB/s 成功；
    1000 行纯黑 86KB @4KB/s 成功。官方 App 的 20B/6ms ≈1KB/s 是"任何内容都安全"的下限。
- 打印机打印场相对纸张**偏右约 1mm**（576 点场起点在纸左缘内 2.8mm，右端距纸边约 0.8mm）；
  全宽内容基本对称，窄内容会显得左边距大 ~2mm（可后续用水平偏移补偿，影响小暂不处理）
- 软件验证：OpenCV 解码重建点阵 == "BUDING-B3 PRINT OK 2026" ✅（像素级正确）

## 五、响应/流控协议（App 源码确认 + 实测验证 ✅）

收到数据后 App 按长度分派：
- **2 字节 `"OK"` (0x4F 0x4B)** = 打印任务开始（START_PRINTING）
- **1 字节 `0xAA`** = 打印任务完成（PRINT_DONE）→ App 信号量放行
- 查询回应：MAC 12 字节 / VER·SN ASCII / 状态 1 字节 等
- **多张连打必须等上一张的 `0xAA` 再发下一张**（实测不等 → 第二张尾部乱码/丢数据）
- ✅ 实测：单张打印后 15 秒内收到 `0xAA`（print_mirror_test.py / print_qr.py 已实现等待）

## 六、最终验证结论（2026-09-24 晚）

- ✅ **无镜像**：大号文字 "THERMAL B3 123" 打印正常从左到右（打包方向与官方 App 一致：
  黑=1、MSB-first、逐行从上到下、无任何翻转）
- ✅ **二维码像素级正确**：OpenCV 从点阵重建可解码 `BUDING-B3 PRINT OK 2026`
- ✅ **576 点宽居中**；上下各约 1cm 留白（放位图内，lineDots 不走纸）
- ✅ **无纵横比例失真**：500×500 点方块实测打印 42×42mm，正方形（纵横均 300dpi）
- ✅ **长任务完整出纸**：速率按大小分档（≤50KB 快 / >50KB 慢），任务不再截断
- ⚠️ 之前观察到的"左右镜像"是连打第二张乱码/错位的视觉误判，实际无镜像

## 七、已知问题（待后续调试）

1. ~~**"J扫J"引导页**~~ **已解决（2026-09-25）**：根因是官方序列里的 `0F 4A`（lineDots）
   命令。见第十节"引导页触发条件实验"。去掉该命令后引导页彻底消失。
2. **快速连打丢数据**：第一张打印未完就发第二张 → 尾部乱码。已用 AA 流控解决（见上）。
3. **`FF02/FF03` 通道**：`01 01` 逐包 ACK 流控仍存在，与 e7810a71 数据通道并存，用途待查。
4. **iOS 真机签名**：免费 Apple ID 设备名额用满（3 台上限），需新注册 Apple ID 或
   在 developer.apple.com 删除旧设备（见 README）。

## 七之二、已修复的坑（易复发，务必注意）

1. **文本打印 180° 倒置（2026-09-25 修复）**
   - 现象：文本打出来上下颠倒（用户把纸转 180° 看即"上下左右全镜像"）；图片却正常。
   - 根因：`NSGraphicsContext(cgContext:flipped: true)` 覆盖在裸 `CGBitmapContext` 上时，
     AppKit 的 flipped 坐标约定与实际 CGContext（原点左下）不一致 → 文字画成倒置。
     只影响文本路径，所以图片是对的。
   - 修复：改用 **CoreText**（`CTFramesetterCreateWithAttributedString` +
     `CTFramesetterSuggestFrameSizeWithConstraints` 量高 + `CTFrameDraw`）直接在当前
     CGContext 绘制——坐标系天然一致，字形正立、首行在顶部。
   - 防回归：`verify_protocol.swift` 增加了"文本朝向自检"（用正立 "F" 检查首行横笔
     覆盖率 >60%、末行 <40%）。字体大小用 `CTFramesetterSuggestFrameSizeWithConstraints`
     量高，比 `boundingRect` 略小（文本任务 866 行 vs 之前 896 行），属正常差异。

2. **点阵行序（180° 倒置）**
   - 根因：CGBitmapContext 内存行序是"顶行在前"，早期代码多做了一次行翻转 → 整幅倒置。
   - 修复：`rasterize` 直接按行取（`srcRow = row`），不翻转。
   - 一并记牢：横向位序是 MSB-first（点 0 → 字节 0 的 bit7），不要反转。

3. **纵向 1.75 修正**：打印机纵向行距约 21 行/mm（横向 11.9 点/mm），生成点阵前
   图像高度必须预拉伸 1.75 倍，否则图案被压扁（详见第四节）。

4. **打印预览的显示比例（易错）**
   - 现象：预览图（1 位点阵）被上下拉伸。
   - 根因：点阵是 `576 × N` 行，其中 N 已含 1.75 纵向修正（行数比"视觉高度"多 1.75 倍）。
     若按点阵**自身像素比例**显示（如 `.scaledToFit()`），就会纵向拉伸 1.75 倍。
   - 正确做法：按**源图比例** `源宽/源高` 显示。因为纸上实际比例恰好等于源图比例：
     纸上高 = N × 0.048mm = 源高 × (576/源宽) × 1.75 × 0.084/1.75 = 源高 × 48.4/源宽，
     即 48.4 : (源高×48.4/源宽) = 源宽 : 源高 ✅
   - 例：she.jpg 805×2179 → 点阵 576×2728；点阵自身比例 0.2111（错误）、
     源图比例 0.3694（正确 = 纸上 48.4:130.9mm = 0.3695）。
   - 已封装为公共组件 `PrintPreviewPane`（文本/二维码/图片三模式 + 图片编辑器共用）。

## 八、工具

- `scan.py` — 扫描（bleak 3.x 无 `.rssi`/`.metadata`）
- `list_chars.py <地址>` — 枚举 GATT
- `query_probe.py` — 查询通道定位（已确认 e7810a71/bef8d6c9）
- `print_test.py` — 图案打印（384 点旧版，已废弃）
- `print_qr.py` — 二维码打印（576 点，单张 + 等待 0xAA）
- `print_mirror_test.py` — 镜像检测：大号文字 + 二维码（已验证无镜像、AA 流控）
- `qr_raster.bin` / `qr_test_big.png` — 验证用二维码点阵/图
- `ThermalPrinteriOS/` — iOS App 源码（Swift + CoreBluetooth）
- `ThermalPrinter/` — **Mac 版 App 源码**（SwiftUI + CoreBluetooth，ad-hoc 签名免开发者账号）
  已编译：`build_mac/sym/Release/ThermalPrinter.app`（通用二进制，双击即用）

## 九、iOS App 技术要点

- CoreBluetooth：扫描名含 "Buding"；连接后找 `e7810a71/bef8d6c9`
- 打印：`rasterize`（缩放到 576 宽 → 灰度 → 阈值 128 → MSB-first 打包）
  → `buildPrintData`（enable+awake+lineDots+GSv0+边距+lineDots+stop）
  → 100B/片 withoutResponse 12ms → 等 `0xAA` 完成信号
- Info.plist 需 `NSBluetoothAlwaysUsageDescription`
- 免费 Apple ID 真机签名（7 天有效），iPhone 需"设置→通用→VPN与设备管理"信任开发者证书

## 十、引导页（"J扫J"）触发条件实验（2026-09-25，已解决 ✅）

**背景**：每次打印纸张最前面都会多出一段 "J扫J"（用户描述），内容为二维码 +
"扫描二维码，查看按键的使用方法"。官方固件镜像（**存于私有仓库 `thermal-printer-vendor-ref/ref/B3-V1.10-1.BIN`**，不在本仓库）中确认存在：

| 固件内偏移 | 内容 |
|---|---|
| 0x1504 | GBK "扫描二维码…查看按键的使用方法" |
| 0x15e68 | `https://buding.chuangyouxiao.com/app/buding_printer_button_guide.htm`（二维码指向的"按键指南"页） |
| 0x14b4/0x14d0/0x14e8 | `BT:%s` / `FW:%s` / `SN:%s`（设备信息文本模板） |

（固件镜像有轻度字符串混淆：`E` 与 `y` 互换，例如 `chuangEouxiao`=`chuangyouxiao`、
`PRINTyR`=`PRINTER`；镜像无标准 Cortex-M 向量表，基址定位失败，故改用实验法。）

**实验**：一次打印 6 个带编号标签，每个用不同命令组合（脚本 `probe_banner.py`）：

| 标签 | 序列 | 结果 |
|---|---|---|
| 1 | 完整当前序列（含 lineDots） | 出现 "J" |
| 2 | 仅 enable + stop（无图像） | 无输出（纸张空白） |
| 3 | 无 enable（其余同 1） | 无输出（**enable 是打印前提**） |
| 4 | 无 awake（含 lineDots） | 出现 "J扫J" **两遍** |
| 5 | 官方完整序列（含 setPrintThickness + 加密 m） | 出现 "J扫J" 一遍 |
| 6 | **去掉 lineDots**（enable+awake+图像+stop） | **完全没有引导页** ✅ |

**结论**：`0F 4A xx 00`（官方命名 `printLineDots`）不是走纸/行距命令，而是固件的
**"打印引导页"触发命令**（`0x0F 0x4A`）。去掉它 → 引导页消失，且不影响打印
（我们的上下留白本来就在位图里，且实测该命令并不走纸）。
`probe_banner.py` 保留作为复现脚本；`verify_protocol.swift` 增加了
"不含 0F 4A" 的防回归断言。

**顺带确认**：`enable(10 FF F1 03)` 是打印的必要前提（标签 3 无输出）；
`awake(1024×00)` 可去掉也能打（标签 4），但保留无副作用。

**官方 App 的完整命令表（反编译 `PrinterCommand.java` 确认）**：

| 命令 | 字节 |
|---|---|
| querySN / queryVersion | `10 FF 20 F2` / `10 FF 20 F1` |
| queryMAC | `10 FF 30 12` |
| queryShuttime / setShuttime | `10 FF 13 00` / `10 FF 12 00 <b>` |
| setPrintThickness | `10 FF 10 00 <b>` |
| queryPower / queryStatus | `10 FF 50 F1` / `10 FF 40 00` |
| enable / stop | `10 FF F1 03` / `10 FF F1 45` |
| lineDots（= 引导页触发！） | `0F 4A <n> 00` |
| 压缩图像（官方路径） | `1F 00 01 <加密m> <xL><xH><yL><yH> <len:LE32>` + 压缩数据 |
| 存图到按键 / 打印按键图 | `1F FF 01 <按钮ID> …` / `1F FF 02 …` |

B3 型号 `printEncrypt=true`、`supportCompress=true`；`m`（GS v 0 第 4 字节）官方
按 `i5=height>>4, i6=bytesPerRow&15 → m=((i6&i5)|((i5|i6)<<4))&0xFF` 生成。
我们用 `m=0` 的**非压缩**路径，实测同样可正常打印，无需压缩库。

## 十一、打印浓度（墨迹深浅）调节（2026-09-25 ✅）

**背景**：用户反馈打印墨迹偏淡。

**根因**：官方 App 每次打印都会先发一条浓度命令，而我们的实现从未发送 →
打印机用出厂默认（偏淡，官方默认值 1）。

**命令**：`setPrintThickness` = `10 FF 10 00 <级别>`
（反编译 `PrinterCommand.setPrintThickness` 确认；`PrinterModel.printThickness`
官方默认 1，B1 机型为 2）

**实测**：`probe_density.py` 打了 5 张浓度 1–5 的对照标签（含实心黑条 + 灰度渐变 +
细字），用户选定 **浓度 3**（黑条明显加深、渐变层次好、细字仍清晰）。

**实现**：
- `RasterOptions.density: UInt8 = 3`，`buildPrintData(..., density:)`
  在 awake 之后、GS v 0 之前插入 `10 FF 10 00 <density>`
- App：底部栏「浓度」选择器（1–5），文本/二维码/图片所有路径都走该设置
- Python 脚本：`DENSITY=5 python print_qr.py`（默认 3）
- 自检：`verify_protocol.swift` 增加"含浓度命令 + 级别在 1…5"断言

**顺带修掉的老脚本 bug**：`print_calib.py` / `print_diag.py` 还在用 12ms/片
（8.3KB/s，超出打印机 ≈4KB/s 消化速度）→ 长任务溢出、收不到 0xAA、尾部乱码。
现已统一改为速率分档（≤50KB → 15ms；>50KB → 25ms）。

## 十二、Swift 代码重构（2026-09-25）

**目标**：把 1067 行的 `ContentView.swift` 拆开，状态与视图分层。

**结果**（16 个文件，最大 298 行）：

| 层 | 文件 |
|---|---|
| 引擎 | `PrintEngine.swift`（协议核心）+ `PrintEngineRaster/Text/Image.swift`（extension 分文件，调用点 `PrintEngine.xxx` 不变） |
| BLE | `PrinterController.swift` + `PrinterControllerDelegates.swift` |
| 模型 | `PrintSettings.swift`（打印设置，派生 `rasterOptions`/`textStyle`）、`PrintHistory.swift`（历史+持久化）、`AppModels.swift` |
| 视图 | `ContentView.swift`（只做协调）、`TextPrintView/QRPrintView/ImagePrintView.swift`、`ImageEditorSheet.swift`、`PrintPreviewPane.swift` |

**要点**：
- 引擎拆分用 `extension PrintEngine {}`，对外 API 完全不变，行为零差异（协议自检通过）
- `PrintSettings` 集中管理打印参数，三个模式视图 + 编辑器共享同一个实例
- 各模式视图自己持有输入内容（文本/二维码/图片列表），通过 `enqueue(data, kind, title, height)` 回调上抛
- 跨文件的代理扩展需要 internal 访问级别：`writeChar` 改为 internal，`handleReceived` 去掉 private

**踩坑记录（重要）**：
1. **pbxproj 里文件名不能含 `+`**：`path = PrintEngine+Raster.swift` 未加引号会被 OpenStep plist
   解析器拒绝 → 整个工程"not a valid property list"，Xcode 无法打开。
   故文件名改为 `PrintEngineRaster.swift` 等。
2. **给经典 pbxproj 加文件要插 4 处**：PBXBuildFile 定义、PBXFileReference、组 children、
   **Sources 阶段的 files 数组内部**。少插 PBXBuildFile 定义 → 文件不参与编译（报"某某不是
   成员"却看不出原因）；插到 `End PBXSourcesBuildPhase` 之前 → 落在数组外，同样无效。
   工具：`/tmp/add_source_file.py`（已修正插入位置，幂等）。
