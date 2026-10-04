#!/bin/bash
# 构建 “NTFS 读写助手.app”
# 纯系统组件：AppKit + Swift 标准库（均为 macOS 自带），不打包任何第三方 dylib。
# 需要：Xcode 或 Command Line Tools（xcode-select --install）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NTFS 读写助手"
EXEC_NAME="NTFSReadWrite"

command -v xcrun >/dev/null 2>&1 || {
  echo "错误：未找到 xcrun。请先安装 Xcode Command Line Tools：xcode-select --install"
  exit 1
}

plutil -lint Resources/Info.plist

# 跟随本机架构（macOS 27 只支持 Apple Silicon；Intel 机器请手动改成 x86_64）
ARCH="$(uname -m)"
mkdir -p build
xcrun swiftc -O -target "${ARCH}-apple-macos13.0" \
  Sources/main.swift \
  Sources/Log.swift \
  Sources/Settings.swift \
  Sources/VolumeManager.swift \
  Sources/AppDelegate.swift \
  -o "build/${EXEC_NAME}"

APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "build/${EXEC_NAME}" "$APP/Contents/MacOS/${EXEC_NAME}"
if [ -d "Resources/engine" ]; then
  cp -R "Resources/engine" "$APP/Contents/Resources/engine"
  echo "已捆绑用户态 NTFS 引擎（ntfs-3g + FUSE-T）"
fi
codesign --force --sign - "$APP"

echo
echo "构建完成：$(pwd)/$APP"
echo "建议复制到 /Applications 后运行："
echo "  cp -R \"$APP\" /Applications/ && open \"/Applications/${APP_NAME}.app\""
