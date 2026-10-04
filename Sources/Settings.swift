import Foundation
import ServiceManagement

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// 插入 NTFS 磁盘时是否自动询问读写挂载（默认开）。
    var autoEnable: Bool {
        get { defaults.object(forKey: "AutoEnable") == nil ? true : defaults.bool(forKey: "AutoEnable") }
        set { defaults.set(newValue, forKey: "AutoEnable") }
    }

    var isLoginItem: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func setLoginItem(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("login item error: \(error)")
        }
    }

    /// 按磁盘 UUID 记住用户在弹窗里的选择。
    func rememberedChoice(_ uuid: String) -> Bool? {
        let key = "Remember.\(uuid.uppercased())"
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    func remember(_ uuid: String, _ wantReadWrite: Bool) {
        defaults.set(wantReadWrite, forKey: "Remember.\(uuid.uppercased())")
    }
}
