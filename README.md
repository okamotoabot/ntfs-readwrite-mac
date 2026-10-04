# NTFS 读写助手（macOS）

一个菜单栏小工具，让 macOS 上的 NTFS 磁盘直接**读写**。

**不依赖任何第三方驱动或运行库**：不装 kext、不装 DriverKit 扩展、不装 macFUSE/ntfs-3g，
全部使用系统自带组件（`ntfs.kext`、`diskutil`、`mount`、AppKit、Swift 标准库——均为 macOS 自带）。

按 macOS 27 / SDK 27（"Golden Gate"，仅 Apple Silicon）设计，最低支持 macOS 13。

## 下载（免编译）

到 [Releases](https://github.com/xiaruihong1-bot/ntfs-readwrite-mac/releases/latest) 下载 `NTFSReadWrite-v1.0.0.app.zip`，解压后把 `NTFS 读写助手.app` 拖进「应用程序」即可。

> 首次打开若提示"无法验证开发者"：右键点击 App → 打开，或在终端执行
> `xattr -cr "/Applications/NTFS 读写助手.app"`。

## 原理

macOS 自带 NTFS 驱动，默认只读挂载，但保留了实验性的写入能力——只要挂载选项带 `rw` 即可启用：

- 在 `/etc/fstab` 写入 `UUID=xxx none ntfs rw,auto`，该磁盘**每次插入自动以读写挂载**；
- 或用 `mount -t ntfs -o rw ...` 临时重挂载（本次有效）。

本工具把这两步做成了自动化流程：

1. 用 `statfs` 实时识别 NTFS 卷及其只读/读写状态；
2. 「以读写方式重新挂载」= 一次管理员授权内完成：写 fstab（幂等，已存在则跳过）→ `diskutil unmount` → `diskutil mount` → 用 `statfs` 校验确实是读写；
3. 如果 diskutil 路径没拿到写权限，自动退回 `mount -t ntfs -o rw` 重试（含未挂载点重建、竞态重试）；
4. 插入新 NTFS 磁盘时自动弹窗询问（可勾选"记住此选择"按磁盘记忆），失败后有 5 分钟冷却避免循环。

## 构建

在 Mac 上（需要 Xcode 或 Command Line Tools）：

```bash
./build.sh
# 产物：build/NTFS 读写助手.app
cp -R "build/NTFS 读写助手.app" /Applications/
open "/Applications/NTFS 读写助手.app"
```

> 提示：如果代码是通过 zip/微信/网盘传过来的，`build.sh` 可能丢失可执行权限。
> 报 "Permission denied" 时改用 `bash build.sh` 运行即可。

菜单栏出现 💾 图标即运行成功。首次使用建议保留在"自动询问"模式。

## 功能

- 菜单栏列出所有已挂载 NTFS 卷及状态（只读/读写）
- 「以读写方式重新挂载（推荐）」：写 fstab，之后这块盘每次插入都自动读写（只需第一次输管理员密码）
- 「仅本次临时读写挂载」：不动 fstab，重新插入后恢复只读
- 「恢复只读」：移除 fstab 条目并重新挂载
- 插入自动询问（可按磁盘记住选择）、登录自启动（SMAppService）、安全弹出、打开 Finder
- 失败诊断：脏卷（dirty）会给出 Windows `chkdsk` 处理建议；日志写入
  `~/Library/Application Support/NTFSReadWrite/ntfsrw.log`

## 重要限制（务必阅读）

1. **苹果官方从未把内置 NTFS 写入标记为稳定特性**，这是多年的实验性行为，不同 macOS 版本表现不一。
   首次使用请先在测试盘/有备份的数据上验证。
2. **卷为"脏"状态时系统会拒绝写入**：Windows 开启"快速启动"或未安全弹出都会导致。
   接回 Windows 运行 `chkdsk 盘符: /f` 并安全弹出即可恢复；建议在 Windows 中关闭快速启动。
3. NTFS 日志（$LogFile）不会被回放，写入中途断电/强拔后可能需要在 Windows 上修复。
4. 如果某个 macOS 版本彻底移除了内置写入能力，本工具会明确报"仍为只读"而不是静默出错。
   到那时，无第三方驱动的方案只剩"用户态文件浏览器"形态（直接读写原始块设备、不挂载进 Finder）。

## 卸载

```bash
# 1. 移除 fstab 条目（本工具只添加 UUID=... none ntfs rw,auto 这种行）
sudo sed -i '' '/none ntfs rw/d' /etc/fstab
# 2. 删除应用
rm -rf "/Applications/NTFS 读写助手.app"
# 3. （可选）删除日志
rm -rf ~/Library/Application\ Support/NTFSReadWrite
```

## 故障排查

- 看日志：`~/Library/Application Support/NTFSReadWrite/ntfsrw.log`（菜单"说明 / 日志"可直接打开）
- 手动验证当前挂载状态：`mount | grep ntfs`（看到 `rw` 即读写）
- 手动等价命令（不依赖本工具也能用）：

```bash
# 临时读写（重启前有效）
diskutil unmount /Volumes/磁盘名
sudo mkdir -p /Volumes/磁盘名
sudo mount -t ntfs -o rw /dev/diskXsY /Volumes/磁盘名

# 永久（该磁盘每次自动读写）
diskutil info /Volumes/磁盘名 | grep "Volume UUID"
echo 'UUID=你的UUID none ntfs rw,auto' | sudo tee -a /etc/fstab
diskutil unmount /Volumes/磁盘名 && diskutil mount /dev/diskXsY
```

## 目录结构

```
Sources/main.swift            入口（菜单栏 App，accessory 模式）
Sources/AppDelegate.swift     菜单、挂载事件监听、弹窗与冷却逻辑
Sources/VolumeManager.swift   NTFS 扫描 / fstab 管理 / 重挂载 / 提权执行
Sources/Settings.swift        偏好设置与登录项（SMAppService）
Sources/Log.swift             日志
Resources/Info.plist          Bundle 配置（LSUIElement 菜单栏应用）
build.sh                      一键构建脚本（swiftc + ad-hoc 签名）
```

## 背景

macOS 27（2026，"Golden Gate"）起仅支持 Apple Silicon；内置 NTFS 写入自 OS X 时代起就是
实验性行为，社区长期通过 fstab 方法启用（如 [GitHub Gist 上的 fstab 指南](https://gist.github.com)）。
若需要绝对可靠的 NTFS 写入，只能引入第三方驱动（Paragon/Tuxera 或 macFUSE+ntfs-3g）——
那正是本项目刻意排除的路线。

> 免责声明：本软件按现状提供。对内置驱动写入造成的任何数据问题，请以备份为准。
