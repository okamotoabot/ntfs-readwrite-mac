// 端到端功能测试：在真实 macOS + FUSE-T + ntfs-3g 环境下，
// 用与应用相同的 VolumeManager 代码验证“插入磁盘 → 一键读写 → 文件读写 → 弹出”全链路。
// 运行：NTFSRW_TEST_ADMIN=1 build/ntfsrw_test

import Foundation

let vm = VolumeManager.shared
var failures = 0
var total = 0

func check(_ name: String, _ body: () throws -> Bool) {
    total += 1
    do {
        if try body() {
            print("PASS: \(name)")
        } else {
            print("FAIL: \(name)")
            failures += 1
        }
    } catch {
        print("ERROR: \(name) — \(error.localizedDescription)")
        failures += 1
    }
}

func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
        try p.run()
    } catch {
        return (-1, "\(error)")
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus,
            String(decoding: outData, as: UTF8.self) + String(decoding: errData, as: UTF8.self))
}

func randomFile(_ path: String, _ size: Int) throws {
    var data = Data(count: size)
    data.withUnsafeMutableBytes { ptr in
        if let base = ptr.baseAddress {
            arc4random_buf(base, ptr.count)
        }
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let work = "/tmp/ntfsrw-e2e"

print("=== NTFS 读写助手 端到端功能测试 ===")
print("engine installed: \(vm.engineInstalled())")

check("模拟全新机器：移除 FUSE-T") {
    _ = run("/opt/homebrew/bin/brew", ["uninstall", "--cask", "fuse-t"])
    try? Shell.admin("""
    /bin/rm -rf /usr/local/lib/libfuse-t.dylib /usr/local/lib/libfuse3.dylib /usr/local/lib/libfuse3.4.dylib /Library/Filesystems/fuse-t.fs
    """)
    return !vm.engineInstalled()
}

check("引擎安装器自动安装 FUSE-T + 引擎文件") {
    try vm.installEngine()
    return vm.engineInstalled()
}

check("引擎自检可运行") { vm.engineInstalled() }

// ---------- 场景一：模拟插入 NTFS 磁盘（内置驱动只读挂载）→ 一键读写 ----------
var dev = ""
var vol: NTFSVolume?

check("创建 64MB 磁盘镜像") {
    try? fm.removeItem(atPath: work)
    try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)
    return run("/bin/dd", ["if=/dev/zero", "of=\(work)/disk.img", "bs=1048576", "count=64"]).code == 0
}

check("mkntfs 格式化为 NTFS") {
    run("/usr/local/sbin/mkntfs", ["-F", "-L", "E2ETEST", "\(work)/disk.img"]).code == 0
}

check("套 UDRW 外壳") {
    run("/usr/bin/hdiutil", ["convert", "\(work)/disk.img", "-format", "UDRW", "-o", "\(work)/disk.dmg"]).code == 0
}

check("挂载为块设备") {
    let r = Shell.run("/usr/bin/hdiutil", ["attach", "-nomount", "\(work)/disk.dmg"])
    guard r.code == 0 else { print(r.err); return false }
    let first = r.out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
    var name = first.components(separatedBy: .whitespacesAndNewlines).first ?? ""
    if name.hasPrefix("/dev/disk") {
        dev = name
    }
    print("attached: \(dev)")
    return dev.hasPrefix("/dev/disk")
}

check("内置驱动只读挂载（模拟插盘自动挂载）") {
    let r = Shell.run("/usr/sbin/diskutil", ["mount", dev])
    print(r.out.trimmingCharacters(in: .whitespacesAndNewlines) + r.err.trimmingCharacters(in: .whitespacesAndNewlines))
    return r.code == 0
}

check("识别内置驱动挂载的只读卷") {
    guard let v = vm.volumeAt("/Volumes/E2ETEST") ?? vm.scan().first(where: { $0.device == dev }) else {
        print("scan found: \(vm.scan())")
        return false
    }
    print("volume: \(v.name) \(v.device) ro=\(v.readOnly) fuse=\(v.isFuseT)")
    vol = v
    return v.readOnly && !v.isFuseT
}

check("一键读写（内置驱动→mount→引擎 完整回退链）") {
    guard let v = vol else { return false }
    do {
        let nv = try vm.enableReadWrite(v)
        print("after: ro=\(nv.readOnly) fuse=\(nv.isFuseT) at \(nv.mountPath)")
        return !nv.readOnly
    } catch {
        print("chain threw: \(error)")
        print("--- mount table ---")
        print(Shell.run("/sbin/mount", []).out)
        print("--- /etc/fstab ---")
        print((try? String(contentsOfFile: "/etc/fstab", encoding: .utf8)) ?? "(none)")
        print("--- diskutil info ---")
        print(Shell.run("/usr/sbin/diskutil", ["info", dev]).out)
        throw error
    }
}

let mp = "/Volumes/E2ETEST"

check("写入小文本文件") {
    try "你好，NTFS！Hello NTFS-3G.".write(toFile: mp + "/hello.txt", atomically: true, encoding: .utf8)
    return true
}

check("读回并逐字比对") {
    let s = try String(contentsOfFile: mp + "/hello.txt", encoding: .utf8)
    return s == "你好，NTFS！Hello NTFS-3G."
}

check("中文目录与文件名读写") {
    try fm.createDirectory(atPath: mp + "/中文文件夹", withIntermediateDirectories: true)
    let path = mp + "/中文文件夹/测试 文件.txt"
    try "chinese path ok".write(toFile: path, atomically: true, encoding: .utf8)
    return try String(contentsOfFile: path, encoding: .utf8) == "chinese path ok"
}

check("1MB 二进制写入 + 逐字节校验") {
    try randomFile("/tmp/expected1m.bin", 1_000_000)
    try fm.copyItem(atPath: "/tmp/expected1m.bin", toPath: mp + "/bin1m.dat")
    return run("/usr/bin/cmp", ["/tmp/expected1m.bin", mp + "/bin1m.dat"]).code == 0
}

check("10MB 文件复制 + 校验（含耗时）") {
    try randomFile("/tmp/big.bin", 10_000_000)
    let t0 = Date()
    try fm.copyItem(atPath: "/tmp/big.bin", toPath: mp + "/big.bin")
    let secs = Date().timeIntervalSince(t0)
    print(String(format: "  10MB copy: %.2fs (%.1f MB/s)", secs, 10.0 / max(secs, 0.001)))
    return run("/usr/bin/cmp", ["/tmp/big.bin", mp + "/big.bin"]).code == 0
}

check("覆盖已有文件") {
    try "v2 content".write(toFile: mp + "/hello.txt", atomically: true, encoding: .utf8)
    return try String(contentsOfFile: mp + "/hello.txt", encoding: .utf8) == "v2 content"
}

check("删除文件与目录") {
    try fm.removeItem(atPath: mp + "/hello.txt")
    try fm.removeItem(atPath: mp + "/bin1m.dat")
    try fm.removeItem(atPath: mp + "/中文文件夹")
    try fm.removeItem(atPath: mp + "/big.bin")
    return !fm.fileExists(atPath: mp + "/hello.txt") && !fm.fileExists(atPath: mp + "/big.bin")
}

check("scan() 将其识别为读写 NTFS 卷") {
    vm.scan().contains { $0.mountPath == mp && !$0.readOnly && $0.isFuseT }
}

check("安全弹出") {
    guard let v = vm.scan().first(where: { $0.mountPath == mp }) else { return false }
    try vm.eject(v)
    return vm.volumeAt(mp) == nil
}

// ---------- 场景二：未挂载的裸 NTFS 盘 → 引擎直接挂载 ----------
var dev2 = ""

check("场景二：制作第二块测试盘") {
    try? fm.removeItem(atPath: work + "/disk2.img")
    return run("/bin/dd", ["if=/dev/zero", "of=\(work)/disk2.img", "bs=1048576", "count=32"]).code == 0
        && run("/usr/local/sbin/mkntfs", ["-F", "-L", "E2E2", "\(work)/disk2.img"]).code == 0
        && run("/usr/bin/hdiutil", ["convert", "\(work)/disk2.img", "-format", "UDRW", "-o", "\(work)/disk2.dmg"]).code == 0
}

check("场景二：挂载为块设备") {
    let r = Shell.run("/usr/bin/hdiutil", ["attach", "-nomount", "\(work)/disk2.dmg"])
    guard r.code == 0 else { return false }
    let first = r.out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
    dev2 = first.components(separatedBy: .whitespacesAndNewlines).first ?? ""
    return dev2.hasPrefix("/dev/disk")
}

check("场景二：引擎直接读写挂载") {
    let v = NTFSVolume(name: "E2E2", mountPath: "/Volumes/E2E2",
                       device: dev2, readOnly: true, uuid: nil)
    let nv = try vm.mountWithNTFS3G(v)
    return !nv.readOnly
}

check("场景二：文件写入读取") {
    try "second disk works".write(toFile: "/Volumes/E2E2/second.txt", atomically: true, encoding: .utf8)
    return try String(contentsOfFile: "/Volumes/E2E2/second.txt", encoding: .utf8) == "second disk works"
}

check("场景二：弹出") {
    guard let v = vm.scan().first(where: { $0.mountPath == "/Volumes/E2E2" }) else { return false }
    try vm.eject(v)
    return vm.volumeAt("/Volumes/E2E2") == nil
}

// ---------- 清理 ----------
_ = run("/usr/bin/hdiutil", ["detach", dev])
_ = run("/usr/bin/hdiutil", ["detach", dev2])

print("=========================================")
print("结果：\(total - failures)/\(total) 通过，\(failures) 失败")
exit(failures == 0 ? 0 : 1)
