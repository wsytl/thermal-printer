#!/bin/bash
#
#  package_mac.sh —— 打包 macOS 发布版
#
#  产出（dist/ 目录）：
#    ThermalPrinter.app            —— 应用本体（通用二进制：arm64 + x86_64）
#    ThermalPrinter-<版本>.dmg     —— 磁盘映像（拖进「应用程序」即可安装）
#    ThermalPrinter-<版本>.zip     —— 压缩包（另一种分发方式）
#    SHA256SUMS.txt                —— 校验和
#
#  用法：./package_mac.sh
#
set -euo pipefail

cd "$(dirname "$0")"
PROJECT="ThermalPrinter.xcodeproj"
TARGET="ThermalPrinter"
APP_NAME="ThermalPrinter"
BUILD_ROOT="build_mac"
DIST="dist"

echo "==> 1/5 清理并编译 Release（通用二进制）"
rm -rf "$DIST"
xcodebuild -project "$PROJECT" -target "$TARGET" -configuration Release \
  clean build SYMROOT="$BUILD_ROOT/sym" OBJROOT="$BUILD_ROOT/obj" \
  | tail -3

APP="$BUILD_ROOT/sym/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "❌ 未找到产物 $APP"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "    版本 ${VERSION}；架构：$(lipo -info "$APP/Contents/MacOS/$APP_NAME" | sed 's/.*are: //')"

echo "==> 2/5 准备发布目录"
mkdir -p "$DIST"
ditto "$APP" "$DIST/$APP_NAME.app"          # ditto 保留签名与扩展属性

echo "==> 3/5 生成 DMG（含「应用程序」快捷方式与安装说明）"
STAGE=$(mktemp -d)
ditto "$DIST/$APP_NAME.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/应用程序"
cat > "$STAGE/安装说明.txt" <<'TXT'
ThermalPrinter —— B3 热敏打印机（576 点 / 300dpi）macOS 打印工具

安装
  把 ThermalPrinter.app 拖到右侧「应用程序」文件夹即可。

首次打开（重要）
  本程序为本地签名（ad-hoc），未做苹果公证，首次打开会被 Gatekeeper 拦下：
    · 方法一：在「应用程序」里 右键点图标 → 打开 → 再点「打开」
    · 方法二：系统设置 → 隐私与安全性 → 底部点「仍要打开」
  之后就能正常双击启动了。

权限
  首次启动会申请「蓝牙」权限，必须允许：系统设置 → 隐私与安全性 → 蓝牙 → 勾选 ThermalPrinter。
  打印机需开机且未被其它设备占用（同一时间只能被一台主机连接）。

用法
  · 文本：输入文字 → 选字体/字号/竖排/反白等 → 打印
  · 二维码：输入网址/文字/WiFi/名片 → 打印（约 48×48mm）
  · 图片：选择图片（可多选）→ 亮度/对比度/抖动 → 打印；单张可先「编辑」裁剪/旋转/镜像
  · 右侧「打印效果」可预览纸上的实际 1 位点阵效果
  · 底部有打印历史（可重打）、日志（排查问题）

系统要求
  macOS 13 或更新版本；Apple Silicon 与 Intel 均可。
TXT
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
  "$DIST/$APP_NAME-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"

echo "==> 4/5 生成 ZIP"
ditto -c -k --sequesterRsrc --keepParent "$DIST/$APP_NAME.app" \
  "$DIST/$APP_NAME-$VERSION.zip"

echo "==> 5/5 校验和"
( cd "$DIST" && shasum -a 256 "$APP_NAME-$VERSION.dmg" "$APP_NAME-$VERSION.zip" \
  > SHA256SUMS.txt && cat SHA256SUMS.txt )

echo
echo "✅ 打包完成，产物在 $DIST/："
ls -lh "$DIST"
