#!/bin/bash
# 端到端功能测试：构建引擎（如未安装）→ 用应用同一份 VolumeManager 代码编译测试器 → 真实挂载读写实测
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x /usr/local/bin/ntfs-3g ]; then
  bash ci/build_engine.sh
fi

mkdir -p build
xcrun swiftc -O -target "$(uname -m)-apple-macos13.0" \
  Sources/Log.swift Sources/VolumeManager.swift ci/main.swift \
  -o build/ntfsrw_test

NTFSRW_TEST_ADMIN=1 NTFSRW_ENGINE_DIR="$(pwd)/Resources/engine" build/ntfsrw_test
echo "==== 功能测试完成 ===="
