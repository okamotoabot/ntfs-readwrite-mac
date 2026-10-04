import Foundation
import Darwin

struct NTFSVolume {
    var name: String
    var mountPath: String
    var device: String
    var readOnly: Bool
    var uuid: String?
    var isFuseT: Bool = false
}

enum NTFSOpError: LocalizedError {
    case userCancelled
    case commandFailed(String)
    case dirtyVolume(String)
    case stillReadOnly(String)
    case engineMissing

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "已取消操作。"
        case .commandFailed(let message):
            return "命令执行失败：\n\(message)"
        case .dirtyVolume(let message):
            return """
            这个 NTFS 卷处于“脏（dirty）”状态，macOS 内置驱动拒绝以写入方式挂载。
            常见原因：Windows 开启了“快速启动”、或上次没有安全弹出。

            处理办法：把磁盘接到 Windows 电脑上，运行 chkdsk 盘符: /f 后安全弹出；\
            或在 Windows 电源选项中关闭“快速启动”后重试。

            详细输出：
            \(message)
            """
        case .stillReadOnly(let message):
            return """
            尝试以读写方式重新挂载后仍是只读。

            可能原因：
            · 当前 macOS 版本的内置 NTFS 驱动已不再提供写入能力（该能力一直是实验性的）；
            · 卷被标记为脏，系统拒绝写入。

            \(message)
            """
        case .engineMissing:
            return """
            未安装用户态 NTFS 引擎。

            请点击菜单栏图标，选择「安装用户态 NTFS 引擎」。\
            该引擎基于开源的 ntfs-3g 与 FUSE-T，不安装任何内核扩展、无需关闭 SIP，\
            在内置驱动不支持写入的系统（如 macOS 26/27）上提供读写能力。
            """
        }
    }
}

/// 读取 statfs 中 C 定长字符数组元组里的字符串。
private func tupleString<T>(_ t: inout T) -> String {
    withUnsafeBytes(of: &t) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return (-1, "", "\(error)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }

    /// 通过 osascript “do shell script ... with administrator privileges” 以 root 执行 sh 脚本。
    /// 这是系统自带的提权途径，不引入任何第三方组件。
    /// CI 测试：设置 NTFSRW_TEST_ADMIN=1 时改用 sudo -n（GitHub runner 免密 sudo），避免交互式密码框。
    static func admin(_ script: String) throws -> String {
        if ProcessInfo.processInfo.environment["NTFSRW_TEST_ADMIN"] == "1" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", "/bin/bash", "-c", script]
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            do {
                try p.run()
            } catch {
                throw NTFSOpError.commandFailed("\(error)")
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let errText = String(decoding: errData, as: UTF8.self)
            if p.terminationStatus == 0 {
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let outText = String(decoding: outData, as: UTF8.self)
                print("[admin exit=0]\(outText)\(errText)")
                return outText
            }
            print("[admin exit=\(p.terminationStatus)] \(errText)")
            throw NTFSOpError.commandFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            throw NTFSOpError.commandFailed("\(error)")
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let errText = String(decoding: errData, as: UTF8.self)
        if p.terminationStatus == 0 {
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: outData, as: UTF8.self)
        }
        if errText.contains("User canceled") || errText.contains("(-128)") {
            throw NTFSOpError.userCancelled
        }
        throw NTFSOpError.commandFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 单引号包裹的 shell 安全引用。
    static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class VolumeManager {
    static let shared = VolumeManager()
    private init() {}

    private let fstabPath = "/etc/fstab"

    // MARK: - 扫描

    func scan() -> [NTFSVolume] {
        var result: [NTFSVolume] = []
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                               options: [.skipHiddenVolumes]) else {
            return result
        }
        for url in urls {
            if let v = volumeAt(url.path, fallbackName: url.lastPathComponent) {
                result.append(v)
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// 检测某挂载点是否为 NTFS：内置驱动（ntfs）或用户态引擎（FUSE-T 以 NFS 回环呈现，来源形如 fuse-t:/卷名）。
    func volumeAt(_ path: String, fallbackName: String? = nil) -> NTFSVolume? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        let fstype = tupleString(&st.f_fstypename).lowercased()
        let mntfrom = tupleString(&st.f_mntfromname)
        let isBuiltin = fstype == "ntfs"
        let isFuseT = fstype == "nfs" && mntfrom.lowercased().hasPrefix("fuse-t:/")
        guard isBuiltin || isFuseT else { return nil }
        let flags = UInt32(truncatingIfNeeded: st.f_flags)
        let readOnly = (flags & UInt32(MNT_RDONLY)) != 0
        let mountPath = tupleString(&st.f_mntonname)
        var name = fallbackName ?? URL(fileURLWithPath: mountPath).lastPathComponent
        if name.isEmpty { name = "NTFS 磁盘" }
        return NTFSVolume(name: name,
                          mountPath: mountPath,
                          device: mntfrom,
                          readOnly: readOnly,
                          uuid: nil,
                          isFuseT: isFuseT)
    }

    func volumeUUID(forDevice device: String) -> String? {
        diskUtilInfo(device)?["VolumeUUID"] as? String
    }

    private func diskUtilInfo(_ arg: String) -> [String: Any]? {
        let r = Shell.run("/usr/sbin/diskutil", ["info", "-plist", arg])
        guard r.code == 0,
              let data = r.out.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    // MARK: - /etc/fstab 管理

    func fstabRWUUIDs() -> [String] {
        guard let content = try? String(contentsOfFile: fstabPath, encoding: .utf8) else { return [] }
        var uuids: [String] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 4,
                  fields[0].hasPrefix("UUID="),
                  fields[2].lowercased() == "ntfs",
                  fields[3].lowercased().contains("rw") else { continue }
            uuids.append(String(fields[0].dropFirst(5)).uppercased())
        }
        return uuids
    }

    func hasFstabRW(_ uuid: String) -> Bool {
        fstabRWUUIDs().contains(uuid.uppercased())
    }

    // MARK: - 用户态引擎（ntfs-3g + FUSE-T）

    func engineInstalled() -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: "/usr/local/bin/ntfs-3g")
            && fm.fileExists(atPath: "/usr/local/lib/libfuse-t.dylib")
    }

    /// 安装用户态引擎：先装捆绑的 FUSE-T 官方 pkg（如缺失），再复制引擎文件，最后自检。
    /// 全程离线可用，不依赖 Homebrew。
    func installEngine() throws {
        let engineURL: URL
        if let override = ProcessInfo.processInfo.environment["NTFSRW_ENGINE_DIR"] {
            engineURL = URL(fileURLWithPath: override)
        } else if let res = Bundle.main.resourceURL {
            engineURL = res.appendingPathComponent("engine")
        } else {
            throw NTFSOpError.commandFailed("无法定位应用资源目录。")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: engineURL.appendingPathComponent("bin/ntfs-3g").path) else {
            throw NTFSOpError.commandFailed("""
            本应用内没有内置引擎文件。
            若是本地构建：请先运行 ci/build_engine.sh 生成 Resources/engine 后重新打包。
            """)
        }

        var steps: [String] = ["/bin/mkdir -p /usr/local/bin /usr/local/sbin /usr/local/lib"]
        // FUSE-T 缺失时先安装捆绑的官方 pkg
        let pkg = engineURL.appendingPathComponent("FUSE-T.pkg")
        if !fm.fileExists(atPath: "/usr/local/lib/libfuse-t.dylib") {
            guard fm.fileExists(atPath: pkg.path) else {
                throw NTFSOpError.commandFailed("""
                应用内未找到 FUSE-T 安装包（FUSE-T.pkg）。
                请到 https://github.com/macos-fuse-t/fuse-t/releases 手动安装 FUSE-T 后重试。
                """)
            }
            steps.append("/usr/sbin/installer -pkg \(Shell.shq(pkg.path)) -target /")
        }
        let src = Shell.shq(engineURL.path)
        steps.append(contentsOf: [
            "/bin/cp \(src)/bin/ntfs-3g /usr/local/bin/ntfs-3g",
            "/bin/cp \(src)/bin/lowntfs-3g /usr/local/bin/lowntfs-3g 2>/dev/null || true",
            "/bin/cp \(src)/bin/ntfsfix /usr/local/bin/ntfsfix 2>/dev/null || true",
            "/bin/cp \(src)/sbin/mkntfs /usr/local/sbin/mkntfs 2>/dev/null || true",
            "/bin/cp \(src)/lib/libntfs-3g* /usr/local/lib/ 2>/dev/null || true",
            "/bin/chmod 755 /usr/local/bin/ntfs-3g /usr/local/bin/lowntfs-3g /usr/local/bin/ntfsfix /usr/local/sbin/mkntfs 2>/dev/null || true",
        ])
        try Shell.admin(steps.joined(separator: "\n"))
        let check = Shell.run("/usr/local/bin/ntfs-3g", ["--version"])
        guard check.code == 0 else {
            throw NTFSOpError.commandFailed("引擎安装后自检失败：\n\(check.err)\(check.out)")
        }
        Log.write("engine installed: \(check.out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// 用 ntfs-3g 以读写挂载（FUSE-T 用户态，无内核扩展）。
    @discardableResult
    func mountWithNTFS3G(_ v: NTFSVolume) throws -> NTFSVolume {
        guard engineInstalled() else { throw NTFSOpError.engineMissing }
        Log.write("ntfs-3g mount: \(v.name) \(v.device)")
        let volname = v.name.replacingOccurrences(of: "/", with: ":")
        let script = """
        for i in 1 2 3; do
          /usr/sbin/diskutil unmount \(Shell.shq(v.mountPath)) >/dev/null 2>&1
          /bin/mkdir -p \(Shell.shq(v.mountPath))
          if /usr/local/bin/ntfs-3g \(Shell.shq(v.device)) \(Shell.shq(v.mountPath)) -o \(Shell.shq("volname=\(volname),allow_other")); then
            exit 0
          fi
          sleep 1
        done
        exit 1
        """
        do {
            try Shell.admin(script)
        } catch {
            _ = Shell.run("/usr/sbin/diskutil", ["mount", v.device])
            throw classify(error)
        }
        // FUSE-T 的 NFS 回环注册是异步的，稍候再校验
        Thread.sleep(forTimeInterval: 1)
        guard let nv = verify(v), !nv.readOnly else {
            throw NTFSOpError.stillReadOnly("ntfs-3g 挂载后未能确认写权限。")
        }
        return nv
    }

    // MARK: - 挂载操作

    /// 推荐流程：一次授权内依次尝试 内置驱动(fstab+diskutil) → mount -o rw → 用户态引擎。
    /// 全部失败时回滚 fstab 并恢复只读挂载。
    @discardableResult
    func enableReadWrite(_ v: NTFSVolume) throws -> NTFSVolume {
        Log.write("enableReadWrite: \(v.name) \(v.device) \(v.mountPath)")
        let uuid = v.uuid ?? volumeUUID(forDevice: v.device)
        let mp = Shell.shq(v.mountPath)
        let dev = Shell.shq(v.device)
        let volname = v.name.replacingOccurrences(of: "/", with: ":")

        var parts: [String] = []
        // 1) 内置驱动：写 fstab（幂等）+ diskutil 重挂载
        if let uuid = uuid {
            parts.append("""
            if ! /usr/bin/grep -q '^UUID=\(uuid.uppercased())[[:space:]]' /etc/fstab 2>/dev/null; then
              /bin/echo \(Shell.shq("UUID=\(uuid.uppercased()) none ntfs rw,auto")) >> \(fstabPath)
            fi
            """)
        }
        parts.append("""
        /usr/sbin/diskutil unmount \(mp) >/dev/null 2>&1
        /usr/sbin/diskutil mount \(dev) >/dev/null 2>&1
        LINE=$(/sbin/mount | /usr/bin/grep -F \(Shell.shq("on \(v.mountPath) (")) || true)
        if [ -n "$LINE" ] && ! echo "$LINE" | /usr/bin/grep -q 'read-only'; then
          exit 0
        fi
        """)
        // 2) 内置驱动：mount -t ntfs -o rw（在 26/27 上可能静默按只读挂载，必须校验）
        parts.append("""
        for i in 1 2 3; do
          /usr/sbin/diskutil unmount \(mp) >/dev/null 2>&1
          /bin/mkdir -p \(mp)
          if /sbin/mount -t ntfs -o rw \(dev) \(mp); then
            LINE2=$(/sbin/mount | /usr/bin/grep -F \(Shell.shq("on \(v.mountPath) (")) || true)
            if [ -n "$LINE2" ] && ! echo "$LINE2" | /usr/bin/grep -q 'read-only'; then
              exit 0
            fi
          fi
          sleep 1
        done
        """)
        // 3) 用户态引擎：ntfs-3g + FUSE-T（macOS 26/27 的主力方案）
        parts.append("""
        if [ -x /usr/local/bin/ntfs-3g ] && [ -e /usr/local/lib/libfuse-t.dylib ]; then
          /usr/sbin/diskutil unmount force \(mp) >/dev/null 2>&1
          /bin/mkdir -p \(mp)
          if /usr/local/bin/ntfs-3g \(dev) \(mp) -o \(Shell.shq("volname=\(volname),allow_other")); then
            sleep 1
            exit 0
          fi
        fi
        """)
        // 4) 全部失败：回滚 fstab，恢复只读挂载
        parts.append("""
        echo '--- all engines failed, diagnostics ---' >&2
        /sbin/mount | /usr/bin/grep -iE 'ntfs|fuse|\\(nfs' >&2 || true
        /bin/ls -la /Volumes >&2 || true
        /usr/local/bin/ntfs-3g --version >&2 2>&1 || echo 'ntfs-3g missing or broken' >&2
        """)
        if let uuid = uuid {
            parts.append("/usr/bin/sed -i '' -e \(Shell.shq("/^UUID=\(uuid.uppercased())[[:space:]]/d")) \(fstabPath) 2>/dev/null || true")
        }
        parts.append("""
        /usr/sbin/diskutil mount \(dev) >/dev/null 2>&1 || true
        exit 3
        """)

        do {
            try Shell.admin(parts.joined(separator: "\n"))
        } catch {
            let converted = classify(error)
            if case NTFSOpError.commandFailed = converted {
                let hint = engineInstalled() ? "" : "\n提示：用户态 NTFS 引擎未安装，可在菜单中安装后再试。"
                throw NTFSOpError.stillReadOnly("内置驱动与用户态引擎均未能获得写权限。\(hint)")
            }
            throw converted
        }
        // 链路报告成功但校验失败（NFS 注册竞态等）时，用独立引擎路径再试一次
        var nv = verify(v)
        if nv == nil || nv!.readOnly {
            Log.write("chain ok but verify failed — retrying standalone engine mount")
            Thread.sleep(forTimeInterval: 1)
            nv = try? mountWithNTFS3G(v)
        }
        if let nv = nv, !nv.readOnly {
            Log.write("enableReadWrite ok")
            return nv
        }
        Log.write("enableReadWrite failed")
        throw NTFSOpError.stillReadOnly("重新挂载后未能确认写权限。")
    }

    /// 临时读写重挂载（不改 fstab）。
    @discardableResult
    func remountReadWriteTemporary(_ v: NTFSVolume) throws -> NTFSVolume {
        Log.write("temp remount: \(v.name) \(v.device)")
        do {
            try remountWithMount(v)
        } catch {
            throw classify(error)
        }
        if let nv = verify(v), !nv.readOnly { return nv }
        // 内置写入不可用时退回用户态引擎
        return try mountWithNTFS3G(v)
    }

    /// 移除 fstab 自动读写配置，并恢复只读挂载。
    func disableReadWrite(_ v: NTFSVolume) throws {
        let uuid = v.uuid ?? volumeUUID(forDevice: v.device)
        guard let uuid = uuid, hasFstabRW(uuid) else { return }
        let script = """
        /usr/bin/sed -i '' -e \(Shell.shq("/^UUID=\(uuid.uppercased())[[:space:]]/d")) \(fstabPath)
        /usr/sbin/diskutil unmount \(Shell.shq(v.mountPath)) >/dev/null 2>&1
        /usr/sbin/diskutil mount \(Shell.shq(v.device))
        """
        do {
            try Shell.admin(script)
        } catch {
            throw classify(error)
        }
        Log.write("disableReadWrite: \(v.name)")
    }

    func eject(_ v: NTFSVolume) throws {
        if v.device.lowercased().hasPrefix("fuse-t:/") {
            // FUSE-T 卷没有真实块设备，直接卸载挂载点
            let r = Shell.run("/usr/sbin/diskutil", ["unmount", v.mountPath])
            guard r.code == 0 else {
                throw NTFSOpError.commandFailed(r.err.isEmpty ? r.out : r.err)
            }
            return
        }
        let r = Shell.run("/usr/sbin/diskutil", ["eject", v.device])
        guard r.code == 0 else {
            throw NTFSOpError.commandFailed(r.err.isEmpty ? r.out : r.err)
        }
    }

    // MARK: - 私有

    /// 校验挂载点当前是否为 NTFS（内置或 FUSE-T）并返回最新只读状态。
    private func verify(_ v: NTFSVolume) -> NTFSVolume? {
        volumeAt(v.mountPath, fallbackName: v.name)
    }

    private func remountWithMount(_ v: NTFSVolume) throws {
        let script = """
        for i in 1 2 3; do
          /usr/sbin/diskutil unmount \(Shell.shq(v.mountPath)) >/dev/null 2>&1
          /bin/mkdir -p \(Shell.shq(v.mountPath))
          if /sbin/mount -t ntfs -o rw \(Shell.shq(v.device)) \(Shell.shq(v.mountPath)); then
            exit 0
          fi
          sleep 1
        done
        exit 1
        """
        do {
            try Shell.admin(script)
        } catch {
            // 失败时尽量把卷恢复成只读挂载，避免磁盘“消失”
            _ = Shell.run("/usr/sbin/diskutil", ["mount", v.device])
            throw error
        }
    }

    private func classify(_ error: Error) -> Error {
        guard case NTFSOpError.commandFailed(let message) = error else { return error }
        let low = message.lowercased()
        if low.contains("dirty") || low.contains("unclean") || low.contains("not unmounted") {
            return NTFSOpError.dirtyVolume(message)
        }
        return error
    }
}
