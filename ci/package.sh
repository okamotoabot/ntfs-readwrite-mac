#!/bin/bash
# 把 build.sh 产出的 .app 打包为两种标准分发格式：
#   1. DMG —— 打开后拖拽到 Applications（经典 macOS 分发方式）
#   2. PKG —— 安装器引导自动装入 /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/NTFS 读写助手.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)

[ -d "$APP" ] || { echo "app bundle missing: $APP"; exit 1; }

# ---------- DMG ----------
STAGING="build/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG="build/NTFSReadWrite-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "NTFS 读写助手" -srcfolder "$STAGING" -format UDZO -ov "$DMG"
echo "dmg: $DMG"

# ---------- PKG ----------
PKGROOT="build/pkgroot"
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/Applications"
cp -R "$APP" "$PKGROOT/Applications/"

pkgbuild --root "$PWD/$PKGROOT" \
         --identifier local.tools.ntfsrw \
         --version "$VERSION" \
         --install-location /Applications \
         build/ntfsrw-app.pkg

productbuild --package build/ntfsrw-app.pkg \
             --identifier local.tools.ntfsrw \
             --version "$VERSION" \
             "build/NTFSReadWrite-${VERSION}-installer.pkg"
echo "pkg: build/NTFSReadWrite-${VERSION}-installer.pkg"

ls -la build/*.dmg build/*.pkg
