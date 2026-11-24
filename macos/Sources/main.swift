import Cocoa
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
            { (nextHandler, theEvent, userData) -> OSStatus in
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

// MARK: - HUD 悬浮窗口
final class HUDWindow: NSPanel {
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

    override var canBecomeKey: Bool {
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        self.orderOut(sender)
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
                    Text(store.toast)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.84)))
                        .shadow(radius: 8)
                        .padding(.bottom, 18)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 630)
    }
}

// MARK: - App 委托与菜单事件
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var hudWindow: HUDWindow?
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private let store = SwitchStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeManager.applySavedTheme()

        // 1. 初始化顶部状态栏图标与动态指示器
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡"
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.updateStatusIndicator()
        }
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

        // 3. 初始化极简 HUD 切号面板
        setupHUDWindow()

        // 4. 注册全局快捷键 ⌃⌥A (Control + Option + A)
        GlobalHotKeyManager.shared.onTrigger = { [weak self] in
            self?.toggleHUD()
        }
        GlobalHotKeyManager.shared.register(keyCode: 0, modifiers: UInt32(controlKey | optionKey))
    }

    private func setupHUDWindow() {
        let hudView = QuickSwitchHUDView(store: store, onDismiss: { [weak self] in
            self?.hudWindow?.orderOut(nil)
        })
        let panel = HUDWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320))
        panel.contentView = NSHostingView(rootView: hudView)
        self.hudWindow = panel
    }

    @objc private func toggleHUD() {
        guard let panel = hudWindow else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            store.refresh(showFeedback: false)
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // 每次点开顶部 ⚡ 菜单时动态构建最新账号池快照
    private func updateStatusIndicator() {
        guard let button = statusItem.button else { return }
        let runningId = store.status?.running_id ?? ""
        guard !runningId.isEmpty, let activeAcc = store.status?.accounts.first(where: { a in a.running }) else {
            button.title = "⚡"
            return
        }

        let pct = activeAcc.remain_5h_pct
        let icon: String
        if pct >= 60 {
            icon = "🟢"
        } else if pct >= 20 {
            icon = "🟡"
        } else {
            icon = "🔴"
        }

        let grp = activeAcc.groupLetter
        let tag = grp.isEmpty ? "" : " · \(grp)组"
        button.title = "\(icon) ⚡ \(pct)%\(tag)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let activeId = store.status?.running_id ?? ""
        let activeAcc = store.status?.accounts.first(where: { $0.running })
        let activeTag = activeAcc.map { a -> String in
            let g = a.groupLetter
            return g.isEmpty ? a.label : "\(a.label) (\(g)组)"
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

    @objc private func menuRefresh() {
        store.refresh(showFeedback: true)
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
