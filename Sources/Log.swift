import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "local.tools.ntfsrw.log")
    private static let fm = FileManager.default

    static var path: String {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = base.appendingPathComponent("NTFSReadWrite", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ntfsrw.log").path
    }

    static func write(_ message: String) {
        let line = "\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium))  \(message)\n"
        queue.async {
            let p = path
            if let fh = FileHandle(forWritingAtPath: p) {
                fh.seekToEndOfFile()
                fh.write(Data(line.utf8))
                try? fh.close()
            } else {
                try? line.write(toFile: p, atomically: true, encoding: .utf8)
            }
        }
    }
}
