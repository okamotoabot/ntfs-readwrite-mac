import Foundation
import Darwin

struct NTFSVolume {
    var name: String
    var mountPath: String
    var device: String
    var readOnly: Bool
    var uuid: String?
}

enum NTFSOpError: LocalizedError {
    case userCancelled
    case commandFailed(String)
    case dirtyVolume(String)
    case stillReadOnly(String)

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
    static func admin(_ script: String) throws -> String {
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

    func volumeAt(_ path: String, fallbackName: String? = nil) -> NTFSVolume? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        guard tupleString(&st.f_fstypename).lowercased() == "ntfs" else { return nil }
        let flags = UInt32(truncatingIfNeeded: st.f_flags)
        let readOnly = (flags & UInt32(MNT_RDONLY)) != 0
        let mountPath = tupleString(&st.f_mntonname)
        let device = tupleString(&st.f_mntfromname)
        var name = fallbackName ?? URL(fileURLWithPath: mountPath).lastPathComponent
        if name.isEmpty { name = "NTFS 磁盘" }
        return NTFSVolume(name: name, mountPath: mountPath, device: device, readOnly: readOnly, uuid: nil)
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

    // MARK: - 挂载操作

    /// 推荐流程：写入 fstab（以后每次插入自动读写）+ 重新挂载。
    @discardableResult
    func enableReadWrite(_ v: NTFSVolume) throws -> NTFSVolume {
        Log.write("enableReadWrite: \(v.name) \(v.device) \(v.mountPath)")
        let uuid = v.uuid ?? volumeUUID(forDevice: v.device)
        var parts: [String] = []
        if let uuid = uuid, !hasFstabRW(uuid) {
            parts.append("/bin/echo \(Shell.shq("UUID=\(uuid.uppercased()) none ntfs rw,auto")) >> \(fstabPath)")
        }
        parts.append("/usr/sbin/diskutil unmount \(Shell.shq(v.mountPath)) >/dev/null 2>&1")
        parts.append("/usr/sbin/diskutil mount \(Shell.shq(v.device))")
        do {
            // fstab 写入与重新挂载合并为一次提权，避免连续弹两次密码框
            _ = try Shell.admin(parts.joined(separator: "\n"))
        } catch {
            throw classify(error)
        }
        if let nv = verify(v), !nv.readOnly {
            Log.write("enableReadWrite ok (diskutil/fstab)")
            return nv
        }
        // 兜底：直接用 mount 命令以 rw 重挂载
        do {
            try remountWithMount(v)
        } catch {
            throw classify(error)
        }
        if let nv = verify(v), !nv.readOnly {
            Log.write("enableReadWrite ok (mount)")
            return nv
        }
        Log.write("enableReadWrite still read-only")
        throw NTFSOpError.stillReadOnly("diskutil 与 mount 两种方式均未获得写权限。")
    }

    /// 临时读写重挂载（不改 fstab，重新插入或重启后恢复只读）。
    @discardableResult
    func remountReadWriteTemporary(_ v: NTFSVolume) throws -> NTFSVolume {
        Log.write("temp remount: \(v.name) \(v.device)")
        do {
            try remountWithMount(v)
        } catch {
            throw classify(error)
        }
        guard let nv = verify(v), !nv.readOnly else {
            throw NTFSOpError.stillReadOnly("mount 命令执行后仍为只读。")
        }
        return nv
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
            _ = try Shell.admin(script)
        } catch {
            throw classify(error)
        }
        Log.write("disableReadWrite: \(v.name)")
    }

    func eject(_ v: NTFSVolume) throws {
        let r = Shell.run("/usr/sbin/diskutil", ["eject", v.device])
        guard r.code == 0 else {
            throw NTFSOpError.commandFailed(r.err.isEmpty ? r.out : r.err)
        }
    }

    // MARK: - 私有

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
            _ = try Shell.admin(script)
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
