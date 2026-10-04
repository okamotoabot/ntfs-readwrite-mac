import AppKit

final class VolumeItem: NSMenuItem {
    enum Kind {
        case enableRW
        case tempRW
        case disableRW
        case reveal
        case eject
    }

    let volume: NTFSVolume
    let kind: Kind

    init(volume: NTFSVolume, kind: Kind) {
        self.volume = volume
        self.kind = kind
        super.init(title: "", action: nil, keyEquivalent: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var mountObserver: Any?
    private var busy = false
    private var failureCooldown: [String: Date] = [:]
    private let cooldownInterval: TimeInterval = 300
    private let vm = VolumeManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "externaldrive",
                                   accessibilityDescription: "NTFS 读写助手")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.volumeMounted(note)
        }
        Log.write("app launched")
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let volumes = vm.scan()

        if volumes.isEmpty {
            menu.addItem(NSMenuItem(title: "未检测到已挂载的 NTFS 磁盘", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }

        for v in volumes {
            let state = v.readOnly ? "只读" : "读写"
            menu.addItem(NSMenuItem(title: "\(v.name)（\(state)） · \(v.device)", action: nil, keyEquivalent: ""))
            if v.readOnly {
                menu.addItem(makeItem(v, kind: .enableRW,
                                      title: "   以读写方式重新挂载（推荐，之后自动生效）"))
                menu.addItem(makeItem(v, kind: .tempRW,
                                      title: "   仅本次临时读写挂载"))
            } else if let uuid = v.uuid ?? vm.volumeUUID(forDevice: v.device),
                      vm.hasFstabRW(uuid) {
                menu.addItem(makeItem(v, kind: .disableRW,
                                      title: "   恢复只读（移除自动读写配置）"))
            }
            menu.addItem(makeItem(v, kind: .reveal, title: "   在 Finder 中打开"))
            menu.addItem(makeItem(v, kind: .eject, title: "   安全弹出"))
            menu.addItem(.separator())
        }

        let auto = NSMenuItem(title: "插入 NTFS 磁盘时自动询问读写挂载",
                              action: #selector(toggleAuto(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = Settings.shared.autoEnable ? .on : .off
        menu.addItem(auto)

        let login = NSMenuItem(title: "登录时自动启动",
                               action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = Settings.shared.isLoginItem ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let about = NSMenuItem(title: "说明 / 日志", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func makeItem(_ v: NTFSVolume, kind: VolumeItem.Kind, title: String) -> VolumeItem {
        let item = VolumeItem(volume: v, kind: kind)
        item.title = title
        item.target = self
        item.action = #selector(volumeAction(_:))
        return item
    }

    // MARK: - 动作

    @objc private func volumeAction(_ sender: VolumeItem) {
        switch sender.kind {
        case .enableRW:
            performEnableRW(sender.volume, remember: true)
        case .tempRW:
            performTempRW(sender.volume)
        case .disableRW:
            performDisableRW(sender.volume)
        case .reveal:
            NSWorkspace.shared.open(URL(fileURLWithPath: sender.volume.mountPath))
        case .eject:
            performEject(sender.volume)
        }
    }

    private func performEnableRW(_ v: NTFSVolume, remember: Bool) {
        runOp(cooldownKey: v.device) {
            let nv = try self.vm.enableReadWrite(v)
            if remember, let uuid = nv.uuid ?? self.vm.volumeUUID(forDevice: nv.device) {
                Settings.shared.remember(uuid, true)
            }
            return nil
        }
    }

    private func performTempRW(_ v: NTFSVolume) {
        runOp(cooldownKey: v.device) {
            try self.vm.remountReadWriteTemporary(v)
            return nil
        }
    }

    private func performDisableRW(_ v: NTFSVolume) {
        runOp {
            try self.vm.disableReadWrite(v)
            return nil
        }
    }

    private func performEject(_ v: NTFSVolume) {
        runOp {
            try self.vm.eject(v)
            return nil
        }
    }

    @objc private func toggleAuto(_ sender: NSMenuItem) {
        let s = Settings.shared
        s.autoEnable.toggle()
        sender.state = s.autoEnable ? .on : .off
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let s = Settings.shared
        s.setLoginItem(!s.isLoginItem)
        sender.state = s.isLoginItem ? .on : .off
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "NTFS 读写助手"
        alert.informativeText = """
        原理：调用 macOS 自带的 NTFS 驱动（ntfs.kext），通过 /etc/fstab 与重新挂载获得写权限。\
        不安装任何第三方内核驱动、系统扩展或运行库。

        注意：
        · 苹果从未承诺内置 NTFS 写入的可靠性，重要数据请先备份；
        · Windows 请关闭“快速启动”并安全弹出，否则卷会标记为脏、只能只读挂载；
        · 若重新挂载后仍为只读，说明当前系统版本已禁用内置写入能力。

        日志：\(Log.path)
        """
        alert.addButton(withTitle: "打开日志")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: Log.path))
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: - 磁盘插入

    private func volumeMounted(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        guard let v = vm.volumeAt(url.path) else { return }
        guard v.readOnly else { return }   // fstab 已配置的卷自动就是读写
        guard Settings.shared.autoEnable else { return }
        // 自动重试失败后进入冷却，避免“失败→重挂载→再失败”的循环
        if let d = failureCooldown[v.device], Date().timeIntervalSince(d) < cooldownInterval { return }

        let uuid = v.uuid ?? vm.volumeUUID(forDevice: v.device)
        if let uuid = uuid, let remembered = Settings.shared.rememberedChoice(uuid) {
            if remembered {
                performEnableRW(v, remember: false)
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "检测到 NTFS 磁盘"
        alert.informativeText = "磁盘“\(v.name)”目前以只读方式挂载。\n要重新以读写方式挂载吗？（需要输入一次管理员密码）"
        alert.addButton(withTitle: "以读写挂载")
        alert.addButton(withTitle: "保持只读")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "记住此选择，以后不再询问"
        let response = alert.runModal()
        let wantRW = response == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on, let uuid = uuid {
            Settings.shared.remember(uuid, wantRW)
        }
        if wantRW {
            performEnableRW(v, remember: false)
        }
    }

    // MARK: - 工具

    private func runOp(cooldownKey: String? = nil, _ body: @escaping () throws -> String?) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var message: String?
            var failure: String?
            do {
                message = try body()
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self?.busy = false
                if let failure = failure {
                    if let key = cooldownKey {
                        self?.failureCooldown[key] = Date()
                    }
                    self?.alert("操作失败：\n\(failure)", critical: true)
                } else if let message = message, !message.isEmpty {
                    self?.alert(message, critical: false)
                }
            }
        }
    }

    private func alert(_ text: String, critical: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = critical ? .critical : .informational
        alert.messageText = critical ? "NTFS 读写助手 — 出错了" : "NTFS 读写助手"
        alert.informativeText = text
        alert.runModal()
    }
}
