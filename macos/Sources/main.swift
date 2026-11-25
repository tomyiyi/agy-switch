import Cocoa
import Combine
import SwiftUI
import Carbon

// MARK: - 全局原生快捷键管理器 (Carbon RegisterEventHotKey)
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    var onTrigger: (() -> Void)?

    private init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, _) -> OSStatus in
                DispatchQueue.main.async {
                    GlobalHotKeyManager.shared.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }

    /// 注册快捷键 (默认 ⌃⌥A: keyCode 0, controlKey | optionKey)
    func register(keyCode: UInt32 = 0, modifiers: UInt32 = UInt32(controlKey | optionKey)) {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x41475953), id: 1) // 'AGYS'
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

// MARK: - HUD 悬浮窗口（支持焦点在搜索框时响应 ↑/↓/⌘1-5/Esc）
final class HUDWindow: NSPanel {
    var onMoveSelection: ((Int) -> Void)?
    var onQuickNumber: ((Int) -> Void)?
    var onEscape: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.level = .floating
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
        self.orderOut(sender)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let code = event.keyCode
            if code == 53 { // Esc
                onEscape?()
                self.orderOut(nil)
                return
            }
            if code == 126 { // Up Arrow
                onMoveSelection?(-1)
                return
            }
            if code == 125 { // Down Arrow
                onMoveSelection?(1)
                return
            }
            if event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers,
               let num = Int(chars), (1...5).contains(num) {
                onQuickNumber?(num - 1)
                return
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - 主窗口根视图
struct MainRootView: View {
    @ObservedObject var store: SwitchStore
    @State private var tab: SidebarTab = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $tab) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 158, ideal: 172, max: 196)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.status?.running_id.isEmpty == false ? DS.brandBlue : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(store.status?.running_id.isEmpty == false ? store.status!.running_id : "未运行")
                            .font(.caption.bold())
                            .lineLimit(1)
                        Spacer()
                        Text("v\(APP_VERSION)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
            }
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch tab {
                    case .dashboard: DashboardView(store: store)
                    case .accounts: AccountsView(store: store)
                    case .handoff: HandoffView(store: store)
                    case .doctor: DoctorView(store: store)
                    case .settings: SettingsView(store: store)
                    case .about: AboutView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !store.toast.isEmpty {
                    let toastColor: Color = {
                        switch store.toastKind {
                        case .success: return DS.brandGreen
                        case .warning: return DS.brandOrange
                        case .error: return DS.brandRed
                        case .info: return Color.black.opacity(0.84)
                        }
                    }()
                    let toastIcon: String = {
                        switch store.toastKind {
                        case .success: return "checkmark.circle.fill"
                        case .warning: return "exclamationmark.triangle.fill"
                        case .error: return "xmark.octagon.fill"
                        case .info: return "info.circle.fill"
                        }
                    }()
                    HStack(spacing: 7) {
                        Image(systemName: toastIcon).font(.system(size: 12))
                        Text(store.toast).font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8.5)
                    .background(Capsule().fill(toastColor.opacity(0.92)))
                    .shadow(color: toastColor.opacity(0.28), radius: 10, y: 4)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 980, minHeight: 630)
        .alert(item: $store.blockedSwitchAlert) { alertItem in
            Alert(
                title: Text("代理节点异常，已拦截启动"),
                message: Text(alertItem.message),
                primaryButton: .destructive(Text("仍要强制启动")) {
                    store.switchTo(alertItem.targetId, force: true)
                },
                secondaryButton: .cancel(Text("取消（去切节点）"))
            )
        }
    }
}

// MARK: - App 委托与菜单事件
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var hudWindow: HUDWindow?
    private let hudController = HUDController()
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private let store = SwitchStore()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeManager.applySavedTheme()

        // 1. 初始化顶部状态栏图标，并通过 Combine 实时订阅状态变化（零延迟）
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡"
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        store.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIndicator()
            }
            .store(in: &cancellables)
        updateStatusIndicator()

        // 2. 初始化主窗口
        let rootView = MainRootView(store: store)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 670),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AGY Switch"
        window.center()
        window.contentView = NSHostingView(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 3. 初始化极简 HUD 切号面板（与视图尺寸 460×430 严格一致）
        setupHUDWindow()

        // 4. 注册全局快捷键 ⌃⌥A (Control + Option + A)
        GlobalHotKeyManager.shared.onTrigger = { [weak self] in
            self?.toggleHUD()
        }
        GlobalHotKeyManager.shared.register(keyCode: 0, modifiers: UInt32(controlKey | optionKey))
    }

    private func hudCurrentItems() -> [AccountInfo] {
        guard let s = store.status else { return [] }
        let all = s.accounts.filter { $0.logged_in && !$0.running && $0.health != "cooldown" && $0.app_exists && !$0.isFlagged }
        let clean = hudController.searchText.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty {
            let rec = store.recommendedAccounts
            return Array((rec.isEmpty ? all : rec).prefix(8))
        }
        let q = clean.lowercased()
        return Array(all.filter {
            $0.label.lowercased().contains(q) ||
            $0.id.lowercased().contains(q) ||
            $0.displayEmail.lowercased().contains(q) ||
            $0.groupLetter.lowercased().contains(q) ||
            $0.note.lowercased().contains(q)
        }.prefix(8))
    }

    private func setupHUDWindow() {
        let hudView = QuickSwitchHUDView(store: store, hud: hudController, onDismiss: { [weak self] in
            self?.hudWindow?.orderOut(nil)
        })
        let panel = HUDWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 430))
        panel.contentView = NSHostingView(rootView: hudView)
        panel.onMoveSelection = { [weak self] delta in
            guard let self = self else { return }
            let count = self.hudCurrentItems().count
            self.hudController.moveSelection(delta: delta, count: count)
        }
        panel.onQuickNumber = { [weak self] idx in
            guard let self = self else { return }
            let items = self.hudCurrentItems()
            guard idx >= 0 && idx < items.count else { return }
            self.hudWindow?.orderOut(nil)
            let isTopAuto = self.hudController.searchText.trimmingCharacters(in: .whitespaces).isEmpty && idx == 0
            self.store.switchTo(isTopAuto ? "" : items[idx].id)
        }
        self.hudWindow = panel
    }

    @objc private func toggleHUD() {
        guard let panel = hudWindow else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            hudController.resetForOpen()
            store.refresh(showFeedback: false)
            store.probeNetwork(showFeedback: false)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateStatusIndicator() {
        guard let button = statusItem.button else { return }
        let runningId = store.status?.running_id ?? ""
        guard !runningId.isEmpty, let activeAcc = store.status?.accounts.first(where: { a in a.running }) else {
            button.title = "⚡"
            return
        }

        let grp = activeAcc.groupLetter
        let tag = grp.isEmpty ? "" : " · \(grp)组"
        if activeAcc.calibrated {
            let pct = activeAcc.remain_5h_pct
            let icon = pct >= 60 ? "🟢" : (pct >= 20 ? "🟡" : "🔴")
            button.title = "\(icon) ⚡ \(pct)%\(tag)"
        } else {
            let turns = activeAcc.turns_5h
            let icon = turns < 100 ? "🟢" : (turns < 160 ? "🟡" : "🔴")
            button.title = "\(icon) ⚡ \(turns)轮\(tag)"
        }
    }

    // 每次点开顶部 ⚡ 菜单时动态构建最新账号池快照
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let activeId = store.status?.running_id ?? ""
        let activeAcc = store.status?.accounts.first(where: { $0.running })
        let activeTag = activeAcc.map { a -> String in
            let g = a.groupLetter
            let base = g.isEmpty ? a.label : "\(a.label) (\(g)组)"
            return a.displayEmail.isEmpty ? base : "\(base) · \(a.displayEmail)"
        } ?? (activeId.isEmpty ? "无运行实例" : activeId)

        let headerItem = NSMenuItem(title: "当前运行：\(activeTag)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        if let top = store.topRecommendedAccount {
            let reason = top.recommendTag.isEmpty ? "跨组首选" : top.recommendTag
            let quickItem = NSMenuItem(
                title: "⚡ 一键接力 → \(top.label) [\(reason)]",
                action: #selector(menuQuickRelay),
                keyEquivalent: "r"
            )
            quickItem.target = self
            menu.addItem(quickItem)
        } else {
            let emptyItem = NSMenuItem(title: "暂无可接力的已登录账号", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        }

        let hudItem = NSMenuItem(title: "呼出极简切号浮窗 (⌃⌥A)", action: #selector(toggleHUD), keyEquivalent: "")
        hudItem.target = self
        menu.addItem(hudItem)

        if let net = store.networkStatus ?? store.status?.network {
            let netItem = NSMenuItem(title: "节点状态：\(net.badgeTitle)（点击重测）", action: #selector(menuProbeNetwork), keyEquivalent: "")
            netItem.target = self
            menu.addItem(netItem)
        }

        if let clash = store.clashStatus ?? store.status?.clash, clash.available {
            let clashParent = NSMenuItem(title: "🌐 切换 Clash 节点 (\(clash.active_node))", action: nil, keyEquivalent: "")
            let subMenu = NSMenu()

            let autoItem = NSMenuItem(title: "✨ 自动优选最快健康节点", action: #selector(menuClashAutoSelect(_:)), keyEquivalent: "")
            autoItem.target = self
            autoItem.representedObject = clash.active_group
            subMenu.addItem(autoItem)
            subMenu.addItem(NSMenuItem.separator())

            for cand in clash.candidates {
                let latTxt = cand.delay_ms > 0 ? " (\(cand.delay_ms)ms)" : ""
                let nodeItem = NSMenuItem(title: "\(cand.name)\(latTxt)", action: #selector(menuClashSwitchNode(_:)), keyEquivalent: "")
                nodeItem.target = self
                nodeItem.state = cand.selected ? .on : .off
                nodeItem.representedObject = [clash.active_group, cand.name]
                subMenu.addItem(nodeItem)
            }
            clashParent.submenu = subMenu
            menu.addItem(clashParent)
        }

        menu.addItem(NSMenuItem.separator())

        let candidates = store.recommendedAccounts.prefix(8)
        if !candidates.isEmpty {
            let subHeader = NSMenuItem(title: "指定切换到可用账号：", action: nil, keyEquivalent: "")
            subHeader.isEnabled = false
            menu.addItem(subHeader)

            for acc in candidates {
                let grp = acc.groupLetter.isEmpty ? "未分组" : "\(acc.groupLetter)组\(acc.isGroupManager ? "·主" : "")"
                let item = NSMenuItem(
                    title: "  \(acc.label)  (\(grp) · 5h \(acc.turns_5h)轮)",
                    action: #selector(menuSwitchAccount(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = acc.id
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
        }

        let handoffItem = NSMenuItem(title: "生成 HANDOFF_AUTO.md 并复制接力词", action: #selector(menuSaveHandoff), keyEquivalent: "h")
        handoffItem.target = self
        menu.addItem(handoffItem)

        let openItem = NSMenuItem(title: "打开 AGY Switch 主窗口", action: #selector(showMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: "刷新状态", action: #selector(menuRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 AGY Switch", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func menuQuickRelay() {
        store.switchTo("")
    }

    @objc private func menuSwitchAccount(_ sender: NSMenuItem) {
        if let targetId = sender.representedObject as? String {
            store.switchTo(targetId)
        }
    }

    @objc private func menuSaveHandoff() {
        store.saveHandoff(transcript: "", note: "")
    }

    @objc private func menuProbeNetwork() {
        store.probeNetwork(showFeedback: true)
    }

    @objc private func menuClashAutoSelect(_ sender: NSMenuItem) {
        let group = (sender.representedObject as? String) ?? ""
        store.clashAutoSelect(group: group)
    }

    @objc private func menuClashSwitchNode(_ sender: NSMenuItem) {
        if let pair = sender.representedObject as? [String], pair.count == 2 {
            store.clashSwitchNode(group: pair[0], node: pair[1])
        }
    }

    @objc private func menuRefresh() {
        store.refresh(showFeedback: true)
        store.probeNetwork(showFeedback: false)
    }

    @objc private func showMainWindow() {
        store.refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
