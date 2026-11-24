import Cocoa
import SwiftUI

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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private let store = SwitchStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeManager.applySavedTheme()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡"
        statusMenu.delegate = self
        statusItem.menu = statusMenu

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
    }

    // 每次点开顶部 ⚡ 菜单时动态构建最新账号池快照，避免过期缓存
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
