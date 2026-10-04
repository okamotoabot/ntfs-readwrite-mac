#!/bin/bash
# 在 macOS 上构建 ntfs-3g（链接 FUSE-T 用户态框架），产物收集到 Resources/engine/
# 供 App 捆绑分发。GPLv2：源码位于 https://github.com/tuxera/ntfs-3g
# 运行前提：安装了 Xcode 命令行工具；Homebrew（CI 自带）
set -euo pipefail
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)/Resources/engine"
rm -rf "$ENGINE_DIR"
mkdir -p "$ENGINE_DIR/bin" "$ENGINE_DIR/sbin" "$ENGINE_DIR/lib"

brew install --cask fuse-t
brew list pkgconf  >/dev/null 2>&1 || brew install pkgconf
brew list autoconf >/dev/null 2>&1 || brew install autoconf
brew list automake >/dev/null 2>&1 || brew install automake
brew list libtool  >/dev/null 2>&1 || brew install libtool

# FUSE-T 的 pkg-config 名是 fuse-t/fuse3，ntfs-3g 找的是经典 fuse.pc，写一个垫片
sudo tee /usr/local/lib/pkgconfig/fuse.pc > /dev/null <<'EOF'
prefix=/usr/local
libdir=${prefix}/lib
includedir=${prefix}/include

Name: fuse
Description: FUSE 2.x compat shim pointing at FUSE-T
Version: 2.9.9
Libs: -L${libdir} -lfuse-t
Cflags: -I${includedir}/fuse
EOF

WORK="$(mktemp -d)"
curl -fL --retry 3 -o "$WORK/n3.tgz" https://github.com/tuxera/ntfs-3g/archive/refs/tags/2026.7.7.tar.gz || \
  curl -fL --retry 3 -o "$WORK/n3.tgz" https://github.com/tuxera/ntfs-3g/archive/refs/tags/2022.10.3.tar.gz
cd "$WORK" && tar xzf n3.tgz && cd ntfs-3g-*
./autogen.sh
PKG_CONFIG_PATH=/usr/local/lib/pkgconfig CFLAGS="-D_FILE_OFFSET_BITS=64" \
  LDFLAGS="-Wl,-rpath,/usr/local/lib" \
  ./configure --prefix=/usr/local --exec-prefix=/usr/local --with-fuse=external
make -j"$(sysctl -n hw.ncpu)"
sudo make install

cp /usr/local/bin/ntfs-3g "$ENGINE_DIR/bin/"
cp /usr/local/bin/lowntfs-3g "$ENGINE_DIR/bin/" 2>/dev/null || true
cp /usr/local/bin/ntfsfix "$ENGINE_DIR/bin/" 2>/dev/null || true
cp /usr/local/sbin/mkntfs "$ENGINE_DIR/sbin/" 2>/dev/null || true
cp /usr/local/lib/libntfs-3g*.dylib* "$ENGINE_DIR/lib/" 2>/dev/null || true
curl -fL -o "$ENGINE_DIR/LICENSE.GPL" https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt || true

# 捆绑 FUSE-T 官方签名 pkg（用户机器上由 App 的引擎安装器用 installer -pkg 静默安装，无需 Homebrew）
APILATEST=$(curl -sfL https://api.github.com/repos/macos-fuse-t/fuse-t/releases/latest || true)
PKGURL=$(printf '%s' "$APILATEST" | /usr/bin/grep -o 'https://[^"]*\.pkg' | /usr/bin/head -1 || true)
if [ -n "${PKGURL:-}" ]; then
  curl -fL --retry 3 -o "$ENGINE_DIR/FUSE-T.pkg" "$PKGURL"
  echo "bundled FUSE-T pkg: $PKGURL"
else
  echo "WARN: could not resolve FUSE-T pkg URL" >&2
fi
curl -fL -o "$ENGINE_DIR/LICENSE.FUSE-T" https://raw.githubusercontent.com/macos-fuse-t/fuse-t/main/LICENSE || true

echo "---- engine files ----"
find "$ENGINE_DIR" -type f
/usr/local/bin/ntfs-3g --version
