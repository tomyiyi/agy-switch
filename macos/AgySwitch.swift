import Cocoa
import SwiftUI

// MARK: - 数据模型
struct AccountInfo: Decodable, Identifiable {
    let id: String
    let label: String
    let note: String
    let logged_in: Bool
    let calibrated: Bool
    let remain_5h_pct: Int
    let remain_7d_pct: Int
    let app_exists: Bool
    let running: Bool
    let pid: Int
    let running_ide: Bool?
    let ide_pid: Int?
    let health: String
    let turns_5h: Int
    let limit_5h: Int
    let reset_5h_min: Int
    let turns_7d: Int
    let limit_7d: Int
    let kb_7d: Double
    let latest_active: String
    let cooldown_remaining_min: Int
}

struct SessionInfo: Decodable, Identifiable {
    var id: String { path }
    let account_id: String
    let account_label: String
    let conv_id: String
    let path: String
    let time: String
}

struct HandoffHistItem: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let kb: Double
    let time: String
}

struct StatusPayload: Decodable {
    let workspace: String
    let workspaces: [String]?
    let running_id: String
    let accounts: [AccountInfo]
    let sessions: [SessionInfo]
    let warn_5h_limit: Int
    let warn_7d_limit: Int
    let handoff_preview: String
    let handoff_updated: String
    let handoff_history: [HandoffHistItem]?
    let last_switch: String?
}

struct DoctorCheck: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let status: String
    let detail: String
}

struct DoctorPayload: Decodable {
    let checked_at: String
    let checks: [DoctorCheck]
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case dashboard = "总览"
    case accounts = "账号池"
    case handoff = "交接中心"
    case doctor = "运行体检"
    case settings = "通用设置"
    case about = "关于"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .accounts: return "person.2.fill"
        case .handoff: return "doc.text.fill"
        case .doctor: return "stethoscope"
        case .settings: return "slider.horizontal.3"
        case .about: return "info.circle.fill"
        }
    }
}

// MARK: - 设计系统色板（3 层表面深度）
enum DS {
    static let canvasBg = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)
            : NSColor(calibratedRed: 0.955, green: 0.965, blue: 0.985, alpha: 1)
    })
    static let cardBg = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.18, alpha: 1)
            : NSColor.white
    })
    static let insetBg = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.15, alpha: 1)
            : NSColor(calibratedRed: 0.972, green: 0.978, blue: 0.99, alpha: 1)
    })
    static let border = Color.primary.opacity(0.08)
    static let brandBlue = Color(red: 0.15, green: 0.45, blue: 0.98)
    static let brandGreen = Color(red: 0.12, green: 0.72, blue: 0.46)
    static let brandOrange = Color(red: 0.95, green: 0.56, blue: 0.12)
    static let brandRed = Color(red: 0.92, green: 0.27, blue: 0.27)
}

// MARK: - 状态管理
final class SwitchStore: ObservableObject {
    @Published var status: StatusPayload?
    @Published var doctor: DoctorPayload?
    @Published var toast: String = ""
    @Published var isBusy: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var autoStartEnabled: Bool = false
    private var lastAlertedAccount: String = ""
    private var lastAlertTime: Date = .distantPast
    private var pollTimer: Timer?

    var isCurrentLowQuota: Bool {
        guard let active = status?.accounts.first(where: { $0.running }) else { return false }
        return active.remain_5h_pct <= 15 || active.remain_7d_pct <= 15
    }

    private var scriptPath: String {
        if let res = Bundle.main.resourcePath {
            let bundled = (res as NSString).appendingPathComponent("server.py")
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/workspace/agy-switch/server.py")
    }

    init() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh(showFeedback: false)
        }
    }

    private func checkLowQuotaNotification(_ decoded: StatusPayload) {
        guard let active = decoded.accounts.first(where: { $0.running }) else { return }
        let low = active.remain_5h_pct <= 15 || active.remain_7d_pct <= 15
        guard low else { return }
        let now = Date()
        if lastAlertedAccount == active.id && now.timeIntervalSince(lastAlertTime) < 1800 {
            return
        }
        lastAlertedAccount = active.id
        lastAlertTime = now
        let pct = min(active.remain_5h_pct, active.remain_7d_pct)
        let msg = "当前账号 \(active.label) 余量仅剩 \(pct)%（≤15%），建议立即打开 AGY Switch 一键接力到满血号！"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "display notification \"\(msg)\" with title \"AGY Switch · 额度预警\""]
        try? proc.run()
    }

    private func runCLI(_ args: [String]) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["python3", scriptPath] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return data
        } catch {
            return nil
        }
    }

    func showToast(_ msg: String) {
        DispatchQueue.main.async { self.toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            if self.toast == msg { self.toast = "" }
        }
    }

    func runDoctor() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let data = self.runCLI(["--cli-doctor"]),
                  let decoded = try? JSONDecoder().decode(DoctorPayload.self, from: data) else { return }
            DispatchQueue.main.async { self.doctor = decoded }
        }
    }

    func refresh(showFeedback: Bool = false) {
        DispatchQueue.main.async { self.isRefreshing = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let data = self.runCLI(["--cli-status"]),
                  let decoded = try? JSONDecoder().decode(StatusPayload.self, from: data) else {
                DispatchQueue.main.async {
                    self?.isRefreshing = false
                    if showFeedback { self?.showToast("刷新失败，请检查运行环境") }
                }
                return
            }
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            let nowStr = fmt.string(from: Date())
            DispatchQueue.main.async {
                self.status = decoded
                self.isRefreshing = false
                self.checkLowQuotaNotification(decoded)
                if showFeedback {
                    self.showToast("已刷新（\(nowStr)）· 当前：\(decoded.running_id.isEmpty ? "无" : decoded.running_id)")
                }
            }
        }
    }

    func calibrate(_ accId: String, pct5h: Int, pct7d: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-calibrate", accId, "\(pct5h)", "\(pct7d)"])
            DispatchQueue.main.async {
                self?.showToast("已校准 \(accId) · 5h \(pct5h)% / 周 \(pct7d)%")
                self?.refresh()
            }
        }
    }

    func fetchAutoStart() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self, let data = self.runCLI(["--cli-autostart", "status"]),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let en = obj["enabled"] as? Bool else { return }
            DispatchQueue.main.async { self.autoStartEnabled = en }
        }
    }

    func setAutoStart(_ enabled: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-autostart", enabled ? "on" : "off"])
            DispatchQueue.main.async {
                self?.autoStartEnabled = enabled
                self?.showToast(enabled ? "已开启开机自动启动" : "已关闭开机自动启动")
            }
        }
    }

    func saveHandoff(transcript: String, note: String) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-handoff-save", transcript, note])
            DispatchQueue.main.async {
                self?.isBusy = false
                self?.showToast("已生成 HANDOFF_AUTO.md，接力词已复制")
                self?.refresh()
            }
        }
    }

    func saveConfig(workspace: String, limit5h: Int, limit7d: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-config", workspace, "\(limit5h)", "\(limit7d)"])
            DispatchQueue.main.async {
                self?.showToast("设置已保存")
                self?.refresh()
            }
        }
    }

    func launchIDE(_ accId: String) {
        isBusy = true
        showToast("正在用 \(accId) 启动 Antigravity IDE（保留当前 Antigravity）...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-launch-ide", accId])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.isBusy = false
                self?.showToast("已用 \(accId) 启动 Antigravity IDE")
                self?.refresh()
            }
        }
    }

    func switchTo(_ targetId: String) {
        isBusy = true
        showToast(targetId.isEmpty ? "正在生成交接单并切到下一个满血号..." : "正在切换到 \(targetId)...")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-switch", targetId])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                self?.isBusy = false
                self?.showToast("切换完成，新窗口 Cmd+V 即可继续")
                self?.refresh()
            }
        }
    }

    func setCooldown(_ accId: String, hours: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-cooldown", accId, "\(hours)"])
            DispatchQueue.main.async {
                self?.showToast(hours > 0 ? "已标记 \(accId) 冷却 \(hours) 小时" : "已恢复 \(accId) 为满血")
                self?.refresh()
            }
        }
    }

    func clearAllCooldowns() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-clear-cooldowns"])
            DispatchQueue.main.async {
                self?.showToast("已一键解除全部账号冷却")
                self?.refresh()
            }
        }
    }

    func addAccount(id: String, note: String, launchNow: Bool) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let data = self.runCLI(["--cli-add", id, note]),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self?.isBusy = false
                    self?.showToast("创建账号失败")
                }
                return
            }
            if let err = obj["error"] as? String {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.showToast("失败：\(err)")
                }
                return
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.showToast("已创建隔离账号 \(id)")
                self.refresh()
                if launchNow { self.switchTo(id) }
            }
        }
    }

    func deleteAccount(_ accId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-delete", accId])
            DispatchQueue.main.async {
                self?.showToast("已将 \(accId) 安全移入废纸篓")
                self?.refresh()
            }
        }
    }

    func updateNote(_ accId: String, note: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-note", accId, note])
            DispatchQueue.main.async {
                self?.showToast("已更新 \(accId) 备注")
                self?.refresh()
            }
        }
    }

    func restoreHandoff(_ filename: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-restore-handoff", filename])
            DispatchQueue.main.async {
                self?.showToast("已恢复 \(filename) 为当前交接单，接力词已复制")
                self?.refresh()
            }
        }
    }

    func manageWorkspace(_ action: String, path: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-workspaces", action, path])
            DispatchQueue.main.async {
                self?.showToast(action == "remove" ? "已移除工作区" : "已切换当前接力工作区")
                self?.refresh()
            }
        }
    }
}

// MARK: - 精致按钮与微组件
struct PrimaryPillButtonStyle: ButtonStyle {
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .system(size: 11.5, weight: .semibold) : .system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 5 : 8)
            .background(
                Capsule()
                    .fill(isEnabled ? DS.brandBlue.opacity(configuration.isPressed ? 0.8 : 1.0) : Color.gray.opacity(0.32))
            )
    }
}

struct SubtlePillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(DS.cardBg.opacity(configuration.isPressed ? 0.7 : 1.0))
                    .overlay(Capsule().stroke(DS.border, lineWidth: 1))
            )
    }
}

// 紧凑型微额度块（对标 Cockpit 视觉节奏：加粗彩色数字 + 3.5px 极细条 + 小字副信息）
struct CompactQuotaMetric: View {
    let title: String
    let pct: Int
    let subtext: String
    let defaultAccent: Color

    var body: some View {
        let clamped = max(0, min(100, pct))
        let tint: Color = clamped <= 15 ? DS.brandRed : (clamped <= 35 ? DS.brandOrange : defaultAccent)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(clamped)%")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundColor(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint).frame(width: max(clamped > 0 ? 4 : 0, geo.size.width * Double(clamped) / 100.0))
                }
            }
            .frame(height: 3.5)

            Text(subtext)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.insetBg))
    }
}

// 真实本地用量微块（零假百分比，只展示 100% 真实轮数与状态）
struct RealUsageMetric: View {
    let title: String
    let valueText: String
    let subtext: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(valueText)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundColor(accent)
                .lineLimit(1)
            Text(subtext)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(.secondary.opacity(0.85))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.insetBg))
    }
}

// 家庭组标签解析器（从备注 "[家庭组X-主/子] 说明" 提取结构化分组与角色）
struct FamilyTagInfo {
    let groupKey: String      // "家庭组 A" / "家庭组 B" / "家庭组 C" / "家庭组 D" / "未分组"
    let shortBadge: String    // "A组" / "B组" / "C组" / "D组" / ""
    let isManager: Bool
    let cleanNote: String
    let tint: Color

    static func parse(_ note: String) -> FamilyTagInfo {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let closeIdx = trimmed.firstIndex(of: "]") {
            let inside = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx])
            let rest = String(trimmed[trimmed.index(after: closeIdx)...]).trimmingCharacters(in: .whitespaces)
            let isMgr = inside.contains("主")
            for (letter, color) in [
                ("D", Color(red: 0.06, green: 0.68, blue: 0.45)),
                ("A", Color(red: 0.49, green: 0.36, blue: 0.90)),
                ("B", DS.brandBlue),
                ("C", DS.brandOrange),
            ] {
                if inside.contains("家庭组\(letter)") || inside.contains("家庭组 \(letter)") {
                    return FamilyTagInfo(
                        groupKey: "家庭组 \(letter)",
                        shortBadge: "\(letter)组",
                        isManager: isMgr,
                        cleanNote: rest,
                        tint: color
                    )
                }
            }
        }
        return FamilyTagInfo(groupKey: "未分组", shortBadge: "", isManager: false, cleanNote: trimmed, tint: .secondary)
    }

    static let groupOrder: [String: Int] = [
        "家庭组 D": 0,
        "家庭组 A": 1,
        "家庭组 B": 2,
        "家庭组 C": 3,
        "未分组": 99
    ]
}

// 3 列网格精致账号卡（零假百分比 + 真实登录态 + 家庭组彩色胶囊 + 同组防误切提示）
struct CockpitStyleAccountCard: View {
    let acc: AccountInfo
    let isBusy: Bool
    var activeGroupKey: String? = nil
    let onSwitch: () -> Void
    var onLaunchIDE: (() -> Void)? = nil
    let onToggleCooldown: () -> Void
    var onEditNote: (() -> Void)? = nil
    var onCalibrate: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovered: Bool = false

    var body: some View {
        let fam = FamilyTagInfo.parse(acc.note)
        let isSameGroupAsActive = !acc.running && fam.groupKey != "未分组" && fam.groupKey == activeGroupKey
        let badgeColor: Color = acc.running ? DS.brandBlue : (!acc.logged_in ? DS.brandOrange : (acc.health == "cooldown" ? DS.brandRed : DS.brandGreen))
        let badgeText: String = acc.running ? "当前" : (!acc.logged_in ? "待登录" : (acc.health == "cooldown" ? "冷却 \(acc.cooldown_remaining_min)m" : "已登录"))
        let sub5h = !acc.logged_in ? "需先登录" : (acc.reset_5h_min > 0 ? "\(acc.reset_5h_min / 60)h\(acc.reset_5h_min % 60)m 后重置" : "空闲满血")
        let sub7d = !acc.logged_in ? "无本地记录" : "活跃 \(acc.latest_active)"

        VStack(alignment: .leading, spacing: 0) {
            // 主账号专属顶部 3px 主题色识别条
            if fam.isManager {
                LinearGradient(
                    colors: [fam.tint, fam.tint.opacity(0.55)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 3.5)
            }

            VStack(alignment: .leading, spacing: fam.isManager ? 11 : 9) {
                // 顶行：主账号用大号皇冠徽章 + 15pt Bold，子账号用 7px 圆点 + 13pt Semibold
                HStack(alignment: .center, spacing: 7) {
                    if fam.isManager {
                        ZStack {
                            Circle()
                                .fill(fam.tint.opacity(0.16))
                                .frame(width: 22, height: 22)
                            Image(systemName: "crown.fill")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(fam.tint)
                        }
                    } else {
                        Circle().fill(badgeColor).frame(width: 7, height: 7)
                    }

                    Text(acc.label)
                        .font(.system(size: fam.isManager ? 15 : 13, weight: fam.isManager ? .bold : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if isSameGroupAsActive {
                        Text("同组")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .help("与当前运行账号同属 \(fam.groupKey)，建议跨组切号")
                    }
                    Text(badgeText)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(badgeColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(badgeColor.opacity(0.13)))
                }

                // 家庭组胶囊：主号用实心高亮胶囊，子号用轻量描边胶囊
                if let editNote = onEditNote {
                    Button(action: editNote) {
                        HStack(spacing: 6) {
                            if !fam.shortBadge.isEmpty {
                                if fam.isManager {
                                    HStack(spacing: 3) {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 8))
                                        Text("\(fam.shortBadge) · 主账号")
                                            .font(.system(size: 10.5, weight: .bold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(fam.tint))
                                } else {
                                    Text("\(fam.shortBadge) · 成员")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(fam.tint.opacity(0.9))
                                        .padding(.horizontal, 6.5)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(fam.tint.opacity(0.08))
                                                .overlay(Capsule().stroke(fam.tint.opacity(0.25), lineWidth: 0.7))
                                        )
                                }

                                if !fam.cleanNote.isEmpty {
                                    Text(fam.cleanNote)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            } else {
                                Image(systemName: "tag")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.secondary.opacity(0.7))
                                Text(fam.cleanNote.isEmpty ? "标家庭组 / 加备注" : fam.cleanNote)
                                    .font(.system(size: 11))
                                    .foregroundColor(fam.cleanNote.isEmpty ? .secondary.opacity(0.7) : .secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                // 中部：双列 100% 真实本地轮数（不显示假百分比）
                HStack(spacing: 8) {
                    RealUsageMetric(
                        title: "近 5 小时",
                        valueText: acc.logged_in ? "\(acc.turns_5h) 轮" : "—",
                        subtext: sub5h,
                        accent: !acc.logged_in ? .secondary : (acc.turns_5h == 0 ? DS.brandGreen : .primary)
                    )
                    RealUsageMetric(
                        title: "近 7 天累计",
                        valueText: acc.logged_in ? "\(acc.turns_7d) 轮" : "—",
                        subtext: sub7d,
                        accent: !acc.logged_in ? .secondary : DS.brandBlue
                    )
                }

                // 底行：轻量图标栏 + 精致切换胶囊
                HStack(spacing: 8) {
                    if acc.logged_in {
                        Button(action: onToggleCooldown) {
                            Image(systemName: acc.health == "cooldown" ? "bolt.heart" : "snowflake")
                                .font(.system(size: 12))
                                .foregroundColor(acc.health == "cooldown" ? DS.brandGreen : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(acc.health == "cooldown" ? "恢复可用" : "标记冷却 5 小时")
                    }

                    if acc.id != "main", let del = onDelete {
                        Button(action: del) {
                            Image(systemName: "trash")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("删除隔离账号（移入废纸篓）")
                    }

                    Spacer()

                    Button(acc.running ? "使用中" : (!acc.logged_in ? "去登录" : "切换")) {
                        onSwitch()
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                    .disabled(acc.running || !acc.app_exists || isBusy)
                }
            }
            .padding(fam.isManager ? 14 : 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(DS.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 13)
                        .fill(
                            LinearGradient(
                                colors: [fam.isManager ? fam.tint.opacity(0.07) : Color.clear, Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                )
                .shadow(color: Color.black.opacity(isHovered ? 0.09 : (fam.isManager ? 0.06 : 0.035)), radius: isHovered ? 10 : (fam.isManager ? 8 : 5), y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(
                    acc.running ? DS.brandBlue.opacity(0.75) : (fam.isManager ? fam.tint.opacity(isHovered ? 0.65 : 0.42) : (isHovered ? DS.brandBlue.opacity(0.3) : DS.border)),
                    lineWidth: (acc.running || fam.isManager) ? 1.5 : 1
                )
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - 1. 总览页（全局汇总条 + Hero 卡 + 3 列推荐池）
struct DashboardView: View {
    @ObservedObject var store: SwitchStore
    @State private var showCalibrate: Bool = false
    @State private var cal5h: Double = 80
    @State private var cal7d: Double = 95

    var body: some View {
        let accounts = store.status?.accounts ?? []
        let activeAcc = accounts.first(where: { $0.running })
        let readyCount = accounts.filter { $0.health == "ready" }.count
        let total7dTurns = accounts.reduce(0) { $0 + $1.turns_7d }
        let recommended = accounts.filter { $0.health == "ready" && !$0.running && $0.app_exists }.prefix(6)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 顶部全局 Telemetry 汇总条
                HStack(spacing: 14) {
                    Label("账号池 \(accounts.count)", systemImage: "person.2")
                    Divider().frame(height: 12)
                    Label("满血 \(readyCount)", systemImage: "checkmark.circle.fill")
                        .foregroundColor(DS.brandGreen)
                    Divider().frame(height: 12)
                    Label("近7天累计 \(total7dTurns) 轮", systemImage: "chart.bar")
                        .foregroundColor(.secondary)
                    Spacer()
                    if let ws = store.status?.workspace, !ws.isEmpty {
                        Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: ws)) }) {
                            Label(URL(fileURLWithPath: ws).lastPathComponent, systemImage: "folder")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("打开工作区：\(ws)")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.cardBg).shadow(color: .black.opacity(0.03), radius: 4, y: 1))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.border, lineWidth: 1))

                // 低额度（≤15%）主动预警横幅
                if let a = activeAcc, (a.remain_5h_pct <= 15 || a.remain_7d_pct <= 15) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(DS.brandOrange)
                        Text("当前账号 \(a.label) 余量已 ≤ 15%（5h: \(a.remain_5h_pct)% · 周: \(a.remain_7d_pct)%），建议立即接力到满血号避免限流。")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("立即接力") { store.switchTo("") }
                            .buttonStyle(PrimaryPillButtonStyle(compact: true))
                            .disabled(store.isBusy)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DS.brandOrange.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.brandOrange.opacity(0.4), lineWidth: 1))
                }

                // Hero 当前活跃账号主卡
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Circle().fill(activeAcc != nil ? DS.brandBlue : .gray).frame(width: 9, height: 9)
                                Text(activeAcc?.label ?? "当前无运行实例")
                                    .font(.system(size: 20, weight: .bold))
                                if let a = activeAcc, a.pid > 0 {
                                    Text("PID \(a.pid)")
                                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                                        .foregroundColor(DS.brandBlue)
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                        .background(Capsule().fill(DS.brandBlue.opacity(0.12)))
                                }
                                if let a = activeAcc, a.reset_5h_min > 0 {
                                    Text("\(a.reset_5h_min / 60)h\(a.reset_5h_min % 60)m 后滚动重置")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(DS.brandOrange)
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                        .background(Capsule().fill(DS.brandOrange.opacity(0.12)))
                                }
                            }
                            Text("工作区：\(store.status?.workspace ?? "-")")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            if let a = activeAcc {
                                Button("校准额度") {
                                    cal5h = Double(a.remain_5h_pct)
                                    cal7d = Double(a.remain_7d_pct)
                                    showCalibrate = true
                                }
                                .buttonStyle(SubtlePillButtonStyle())
                            }

                            Button(action: { store.refresh(showFeedback: true) }) {
                                if store.isRefreshing {
                                    HStack(spacing: 5) {
                                        ProgressView().controlSize(.small)
                                        Text("刷新中")
                                    }
                                } else {
                                    Label("刷新", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(SubtlePillButtonStyle())
                            .disabled(store.isRefreshing)

                            Button(action: { store.switchTo("") }) {
                                Label("一键接力到下一个满血号", systemImage: "bolt.fill")
                            }
                            .buttonStyle(PrimaryPillButtonStyle(compact: false))
                            .disabled(store.isBusy)
                        }
                    }

                    if let a = activeAcc {
                        HStack(spacing: 12) {
                            RealUsageMetric(
                                title: "近 5 小时对话",
                                valueText: "\(a.turns_5h) 轮",
                                subtext: a.reset_5h_min > 0 ? "\(a.reset_5h_min / 60)h\(a.reset_5h_min % 60)m 后滚动重置" : "空闲状态",
                                accent: a.turns_5h == 0 ? DS.brandGreen : .primary
                            )
                            RealUsageMetric(
                                title: "近 7 天累计",
                                valueText: "\(a.turns_7d) 轮",
                                subtext: a.note.isEmpty ? "精确余量请看 Antigravity 右下角弹窗" : "分组/备注：\(a.note)",
                                accent: DS.brandBlue
                            )
                        }
                    }
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 15)
                        .fill(DS.cardBg)
                        .shadow(color: DS.brandBlue.opacity(0.08), radius: 12, y: 3)
                )
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(DS.brandBlue.opacity(0.35), lineWidth: 1.2))
                .sheet(isPresented: $showCalibrate) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("校准真实剩余额度：\(activeAcc?.label ?? "")").font(.headline)
                        Text("对照 Antigravity 右下角弹窗里的真实余量拖动滑块，保存后随对话自动递减。")
                            .font(.caption).foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("5 小时窗口剩余：\(Int(cal5h))%").font(.callout.monospacedDigit())
                            Slider(value: $cal5h, in: 0...100, step: 1)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("本周 (7d) 剩余：\(Int(cal7d))%").font(.callout.monospacedDigit())
                            Slider(value: $cal7d, in: 0...100, step: 1)
                        }
                        HStack {
                            Spacer()
                            Button("取消") { showCalibrate = false }
                            Button("保存校准") {
                                if let a = activeAcc { store.calibrate(a.id, pct5h: Int(cal5h), pct7d: Int(cal7d)) }
                                showCalibrate = false
                            }
                            .buttonStyle(PrimaryPillButtonStyle(compact: true))
                        }
                    }
                    .padding(20)
                    .frame(width: 380)
                }

                // 推荐备用满血池（3 列自适应网格）
                HStack {
                    Text("推荐备用满血号")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("共 \(readyCount) 个满血可用")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 12)], spacing: 12) {
                    ForEach(Array(recommended)) { acc in
                        CockpitStyleAccountCard(
                            acc: acc,
                            isBusy: store.isBusy,
                            onSwitch: { store.switchTo(acc.id) },
                            onLaunchIDE: { store.launchIDE(acc.id) },
                            onToggleCooldown: { store.setCooldown(acc.id, hours: 5) }
                        )
                    }
                }

                // 3 步无缝接力微引导条
                HStack(spacing: 14) {
                    Label("如何无缝续上工作：", systemImage: "lightbulb.fill")
                        .foregroundColor(DS.brandBlue)
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("① 点「一键接力」自动保存 HANDOFF_AUTO.md 并退旧号")
                    Text("→")
                    Text("② 等 2 秒新号窗口打开同一目录")
                    Text("→")
                    Text("③ 对话框直接 Cmd+V 发送接力词")
                    Spacer()
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.cardBg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.border, lineWidth: 1))
            }
            .padding(20)
        }
        .background(DS.canvasBg)
    }
}

// 紧凑小卡片（高密度模式，真实轮数 + 家庭组标签）
struct CompactMiniAccountCard: View {
    let acc: AccountInfo
    let isBusy: Bool
    let onSwitch: () -> Void

    var body: some View {
        let fam = FamilyTagInfo.parse(acc.note)
        let dotColor: Color = acc.running ? DS.brandBlue : (!acc.logged_in ? DS.brandOrange : (acc.health == "cooldown" ? DS.brandRed : DS.brandGreen))

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(dotColor).frame(width: 6.5, height: 6.5)
                Text(acc.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer()
                if !fam.shortBadge.isEmpty {
                    Text(fam.isManager ? "\(fam.shortBadge)·主" : fam.shortBadge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(fam.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(fam.tint.opacity(0.13)))
                }
            }
            HStack(spacing: 6) {
                Text(acc.logged_in ? "5h \(acc.turns_5h)轮" : "待登录")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(acc.logged_in ? (acc.turns_5h == 0 ? DS.brandGreen : .primary) : DS.brandOrange)
                if acc.logged_in {
                    Text("·").foregroundColor(.secondary)
                    Text("7d \(acc.turns_7d)轮")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(acc.running ? "使用中" : (!acc.logged_in ? "去登录" : "切换")) { onSwitch() }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                    .disabled(acc.running || !acc.app_exists || isBusy)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.cardBg).shadow(color: .black.opacity(0.03), radius: 4, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(acc.running ? DS.brandBlue.opacity(0.6) : DS.border, lineWidth: acc.running ? 1.5 : 1))
    }
}

// 横向列表行（表格模式，真实轮数 + 家庭组标签）
struct AccountListRow: View {
    let acc: AccountInfo
    let isBusy: Bool
    let onSwitch: () -> Void
    let onToggleCooldown: () -> Void
    let onCalibrate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let fam = FamilyTagInfo.parse(acc.note)
        let dotColor: Color = acc.running ? DS.brandBlue : (!acc.logged_in ? DS.brandOrange : (acc.health == "cooldown" ? DS.brandRed : DS.brandGreen))

        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(acc.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if !fam.shortBadge.isEmpty {
                            Text("\(fam.shortBadge)·\(fam.isManager ? "主号" : "成员")")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(fam.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(fam.tint.opacity(0.13)))
                        }
                    }
                    Text(fam.cleanNote.isEmpty ? "活跃 \(acc.latest_active)" : fam.cleanNote)
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 240, alignment: .leading)

            RealUsageMetric(
                title: "近 5 小时",
                valueText: acc.logged_in ? "\(acc.turns_5h) 轮" : "—",
                subtext: acc.logged_in ? (acc.turns_5h == 0 ? "空闲满血" : "活跃中") : "待登录",
                accent: !acc.logged_in ? .secondary : (acc.turns_5h == 0 ? DS.brandGreen : .primary)
            )
            RealUsageMetric(
                title: "近 7 天累计",
                valueText: acc.logged_in ? "\(acc.turns_7d) 轮" : "—",
                subtext: acc.logged_in ? "活跃 \(acc.latest_active)" : "无本地记录",
                accent: !acc.logged_in ? .secondary : DS.brandBlue
            )

            HStack(spacing: 10) {
                if acc.logged_in {
                    Button(action: onToggleCooldown) {
                        Image(systemName: acc.health == "cooldown" ? "bolt.heart" : "snowflake")
                            .foregroundColor(acc.health == "cooldown" ? DS.brandGreen : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                if acc.id != "main" {
                    Button(action: onDelete) { Image(systemName: "trash").foregroundColor(.secondary) }.buttonStyle(.plain)
                }
                Button(acc.running ? "使用中" : (!acc.logged_in ? "去登录" : "切换")) { onSwitch() }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                    .disabled(acc.running || !acc.app_exists || isBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 11).fill(DS.cardBg).shadow(color: .black.opacity(0.03), radius: 4, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(acc.running ? DS.brandBlue.opacity(0.6) : DS.border, lineWidth: acc.running ? 1.5 : 1))
    }
}

// MARK: - 2. 账号池页（按家庭组智能分组 + 网格/紧凑/列表 3 视图 + 增删改备注）
struct AccountsView: View {
    @ObservedObject var store: SwitchStore
    @State private var filter: String = "all"
    @State private var layoutMode: String = UserDefaults.standard.string(forKey: "agy_layout") ?? "grid"
    @State private var groupByFamily: Bool = UserDefaults.standard.object(forKey: "agy_group_family") == nil ? true : UserDefaults.standard.bool(forKey: "agy_group_family")
    @State private var searchText: String = ""
    @State private var showAddSheet: Bool = false
    @State private var newAccId: String = ""
    @State private var newAccNote: String = ""
    @State private var launchAfterAdd: Bool = false

    @State private var editingNoteAcc: AccountInfo? = nil
    @State private var editingNoteText: String = ""
    @State private var calibratingAcc: AccountInfo? = nil
    @State private var calAcc5h: Double = 100
    @State private var calAcc7d: Double = 100
    @State private var deletingAcc: AccountInfo? = nil

    private func buildSections(_ list: [AccountInfo]) -> [(key: String, tint: Color, items: [AccountInfo])] {
        var bucket: [String: (tint: Color, items: [AccountInfo])] = [:]
        for acc in list {
            let fam = FamilyTagInfo.parse(acc.note)
            var entry = bucket[fam.groupKey] ?? (tint: fam.tint, items: [])
            entry.items.append(acc)
            bucket[fam.groupKey] = entry
        }
        return bucket.map { (k, v) in
            // 组内排序：主号排第 1，其次已登录，最后按名称
            let sortedItems = v.items.sorted { a, b in
                let fa = FamilyTagInfo.parse(a.note)
                let fb = FamilyTagInfo.parse(b.note)
                if fa.isManager != fb.isManager { return fa.isManager }
                if a.logged_in != b.logged_in { return a.logged_in }
                return a.label < b.label
            }
            return (key: k, tint: v.tint, items: sortedItems)
        }.sorted { a, b in
            (FamilyTagInfo.groupOrder[a.key] ?? 50) < (FamilyTagInfo.groupOrder[b.key] ?? 50)
        }
    }

    @ViewBuilder
    private func renderAccounts(_ items: [AccountInfo], activeGroupKey: String?) -> some View {
        if layoutMode == "list" {
            LazyVStack(spacing: 8) {
                ForEach(items) { acc in
                    AccountListRow(
                        acc: acc,
                        isBusy: store.isBusy,
                        onSwitch: { store.switchTo(acc.id) },
                        onToggleCooldown: { store.setCooldown(acc.id, hours: acc.health == "cooldown" ? 0 : 5) },
                        onCalibrate: {
                            calibratingAcc = acc
                            calAcc5h = Double(acc.remain_5h_pct)
                            calAcc7d = Double(acc.remain_7d_pct)
                        },
                        onDelete: { deletingAcc = acc }
                    )
                }
            }
        } else if layoutMode == "compact" {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185, maximum: 240), spacing: 10)], spacing: 10) {
                ForEach(items) { acc in
                    CompactMiniAccountCard(
                        acc: acc,
                        isBusy: store.isBusy,
                        onSwitch: { store.switchTo(acc.id) }
                    )
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 255, maximum: 350), spacing: 12)], spacing: 12) {
                ForEach(items) { acc in
                    CockpitStyleAccountCard(
                        acc: acc,
                        isBusy: store.isBusy,
                        activeGroupKey: activeGroupKey,
                        onSwitch: { store.switchTo(acc.id) },
                        onLaunchIDE: { store.launchIDE(acc.id) },
                        onToggleCooldown: { store.setCooldown(acc.id, hours: acc.health == "cooldown" ? 0 : 5) },
                        onEditNote: {
                            editingNoteAcc = acc
                            editingNoteText = acc.note
                        },
                        onCalibrate: {
                            calibratingAcc = acc
                            calAcc5h = Double(acc.remain_5h_pct)
                            calAcc7d = Double(acc.remain_7d_pct)
                        },
                        onDelete: { deletingAcc = acc }
                    )
                }
            }
        }
    }

    var body: some View {
        let all = store.status?.accounts ?? []
        let activeAcc = all.first(where: { $0.running })
        let activeGroupKey = activeAcc.map { FamilyTagInfo.parse($0.note).groupKey }
        let filtered = all.filter { acc in
            let matchFilter = (filter == "all") || (filter == "ready" && acc.health == "ready") || (filter == "cooldown" && acc.health == "cooldown")
            let q = searchText.trimmingCharacters(in: .whitespaces)
            let matchSearch = q.isEmpty || acc.label.localizedCaseInsensitiveContains(q) || acc.note.localizedCaseInsensitiveContains(q)
            return matchFilter && matchSearch
        }
        let sections = buildSections(filtered)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("搜索账号名或家庭组...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 175)

                Button(action: {
                    groupByFamily.toggle()
                    UserDefaults.standard.set(groupByFamily, forKey: "agy_group_family")
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: groupByFamily ? "rectangle.3.group.fill" : "square.grid.2x2")
                            .font(.system(size: 11))
                        Text(groupByFamily ? "按家庭组" : "平铺")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundColor(groupByFamily ? DS.brandBlue : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(
                        Capsule()
                            .fill(groupByFamily ? DS.brandBlue.opacity(0.12) : DS.cardBg)
                            .overlay(Capsule().stroke(groupByFamily ? DS.brandBlue.opacity(0.35) : DS.border, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .help("切换按家庭组分组展示或平铺展示")

                Picker("", selection: $layoutMode) {
                    Image(systemName: "square.grid.2x2").tag("grid")
                    Image(systemName: "square.grid.3x3").tag("compact")
                    Image(systemName: "list.bullet").tag("list")
                }
                .pickerStyle(.segmented)
                .frame(width: 104)
                .onChange(of: layoutMode) { _, newVal in
                    UserDefaults.standard.set(newVal, forKey: "agy_layout")
                }
                .help("切换排列方式：标准网格 / 紧凑高密度 / 横向列表")

                Picker("", selection: $filter) {
                    Text("全部 (\(all.count))").tag("all")
                    Text("满血 (\(all.filter { $0.health == "ready" }.count))").tag("ready")
                    Text("冷却 (\(all.filter { $0.health == "cooldown" }.count))").tag("cooldown")
                }
                .pickerStyle(.segmented)
                .frame(width: 230)

                Spacer()

                if all.contains(where: { $0.health == "cooldown" }) {
                    Button("解除全部冷却") { store.clearAllCooldowns() }
                        .buttonStyle(SubtlePillButtonStyle())
                }

                Button(action: { store.refresh(showFeedback: true) }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SubtlePillButtonStyle())

                Button(action: {
                    newAccId = ""
                    newAccNote = ""
                    launchAfterAdd = false
                    showAddSheet = true
                }) {
                    Label("添加账号", systemImage: "plus")
                }
                .buttonStyle(PrimaryPillButtonStyle(compact: true))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
                if groupByFamily {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(sections, id: \.key) { sec in
                            let loggedCount = sec.items.filter { $0.logged_in }.count
                            let isCurrentGroup = sec.key != "未分组" && sec.key == activeGroupKey
                            let subtitle = sec.key == "家庭组 D" ? "独享 AI Pro · 切号首选" : (isCurrentGroup ? "当前运行所在组 · 切号建议避开" : "已登录 \(loggedCount)/\(sec.items.count)")

                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(sec.tint)
                                        .frame(width: 4, height: 15)
                                    Text(sec.key)
                                        .font(.system(size: 13.5, weight: .bold))
                                    Text("\(sec.items.count) 个账号")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                                    Text(subtitle)
                                        .font(.system(size: 11, weight: isCurrentGroup || sec.key == "家庭组 D" ? .semibold : .regular))
                                        .foregroundColor(sec.key == "家庭组 D" ? sec.tint : (isCurrentGroup ? DS.brandOrange : .secondary))
                                    Spacer()
                                }
                                .padding(.horizontal, 2)

                                renderAccounts(sec.items, activeGroupKey: activeGroupKey)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                } else {
                    renderAccounts(filtered, activeGroupKey: activeGroupKey)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
            }
        }
        .background(DS.canvasBg)
        .sheet(isPresented: $showAddSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("添加新的隔离账号").font(.title3.bold())
                Text("自动创建独立 HOME 目录、软链公共 Skills 与桌面 .app 启动器，创建后走官方 Google 登录一次即可。")
                    .font(.caption).foregroundColor(.secondary)
                TextField("账号标识（如 11-myaccount）", text: $newAccId).textFieldStyle(.roundedBorder)
                TextField("备注（可选，如 邮箱 / Pro主力）", text: $newAccNote).textFieldStyle(.roundedBorder)
                Toggle("创建后立即切换到此号并打开登录", isOn: $launchAfterAdd).font(.callout)
                HStack {
                    Spacer()
                    Button("取消") { showAddSheet = false }
                    Button("确认创建") {
                        let idClean = newAccId.trimmingCharacters(in: .whitespaces)
                        if !idClean.isEmpty {
                            store.addAccount(id: idClean, note: newAccNote, launchNow: launchAfterAdd)
                            showAddSheet = false
                        }
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                    .disabled(newAccId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20).frame(width: 420)
        }
        .sheet(item: $editingNoteAcc) { acc in
            VStack(alignment: .leading, spacing: 12) {
                Text("编辑备注：\(acc.label)").font(.headline)
                TextField("输入备注（留空清除）", text: $editingNoteText).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("取消") { editingNoteAcc = nil }
                    Button("保存") {
                        store.updateNote(acc.id, note: editingNoteText)
                        editingNoteAcc = nil
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                }
            }
            .padding(20).frame(width: 360)
        }
        .sheet(item: $calibratingAcc) { acc in
            VStack(alignment: .leading, spacing: 14) {
                Text("校准真实剩余额度：\(acc.label)").font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    Text("5 小时窗口剩余：\(Int(calAcc5h))%").font(.callout.monospacedDigit())
                    Slider(value: $calAcc5h, in: 0...100, step: 1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("本周 (7d) 剩余：\(Int(calAcc7d))%").font(.callout.monospacedDigit())
                    Slider(value: $calAcc7d, in: 0...100, step: 1)
                }
                HStack {
                    Spacer()
                    Button("取消") { calibratingAcc = nil }
                    Button("保存校准") {
                        store.calibrate(acc.id, pct5h: Int(calAcc5h), pct7d: Int(calAcc7d))
                        calibratingAcc = nil
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                }
            }
            .padding(20).frame(width: 360)
        }
        .alert("确认删除账号？", isPresented: Binding(get: { deletingAcc != nil }, set: { if !$0 { deletingAcc = nil } })) {
            Button("取消", role: .cancel) { deletingAcc = nil }
            Button("移入废纸篓", role: .destructive) {
                if let target = deletingAcc { store.deleteAccount(target.id) }
                deletingAcc = nil
            }
        } message: {
            Text("将把 \(deletingAcc?.label ?? "") 的隔离目录和桌面启动器安全移入废纸篓，随时可恢复。")
        }
    }
}

// MARK: - 3. 交接中心页
struct HandoffView: View {
    @ObservedObject var store: SwitchStore
    @State private var selectedPath: String = ""
    @State private var extraNote: String = ""

    var body: some View {
        let sessions = store.status?.sessions ?? []

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("跨账号交接单 (HANDOFF_AUTO.md)")
                    .font(.headline)
                HStack {
                    Picker("来源会话", selection: $selectedPath) {
                        Text("自动选择最近活跃会话").tag("")
                        ForEach(sessions) { s in
                            Text("\(s.account_label) · \(s.time)").tag(s.path)
                        }
                    }
                    .frame(maxWidth: 360)
                    Spacer()
                    Button("生成并复制接力词") {
                        store.saveHandoff(transcript: selectedPath, note: extraNote)
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                    .disabled(store.isBusy)
                }
                TextField("可选：给下一个号的特别交代（例如：先修登录报错，不要改数据库）", text: $extraNote)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 13).fill(DS.cardBg).shadow(color: .black.opacity(0.04), radius: 6, y: 2))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(DS.border, lineWidth: 1))

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("当前交接单预览").font(.subheadline.bold())
                        Spacer()
                        if let upd = store.status?.handoff_updated, !upd.isEmpty {
                            Text("更新于 \(upd)").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    ScrollView {
                        Text(store.status?.handoff_preview.isEmpty == false ? store.status!.handoff_preview : "尚未生成 HANDOFF_AUTO.md，点击上方按钮即可生成。")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(14)
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(DS.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.border, lineWidth: 1))
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("历史归档").font(.subheadline.bold())
                        Spacer()
                        Text("最近 10 份").font(.caption).foregroundColor(.secondary)
                    }
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            let hist = store.status?.handoff_history ?? []
                            if hist.isEmpty {
                                Text("暂无历史归档\n每次更新交接单时自动备份")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.top, 28)
                            } else {
                                ForEach(hist) { item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                .lineLimit(1)
                                            Text("\(item.time) · \(String(format: "%.1f", item.kb)) KB")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Button("恢复") { store.restoreHandoff(item.name) }
                                            .controlSize(.small)
                                    }
                                    .padding(9)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.insetBg))
                                }
                            }
                        }
                        .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(DS.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.border, lineWidth: 1))
                }
                .frame(width: 270)
            }
        }
        .padding(20)
        .background(DS.canvasBg)
    }
}

// MARK: - 4. 运行体检页
struct DoctorView: View {
    @ObservedObject var store: SwitchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地运行环境体检").font(.title3.bold())
                    Text(store.doctor != nil ? "最近检查：\(store.doctor!.checked_at)" : "点击右侧开始检查")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button("重新体检") { store.runDoctor() }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.doctor?.checks ?? []) { item in
                        let icon = item.status == "ok" ? "checkmark.circle.fill" : (item.status == "warn" ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                        let color: Color = item.status == "ok" ? DS.brandGreen : (item.status == "warn" ? DS.brandOrange : DS.brandRed)
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon).foregroundColor(color).font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.system(size: 13.5, weight: .semibold))
                                Text(item.detail).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(DS.cardBg).shadow(color: .black.opacity(0.03), radius: 4, y: 1))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25), lineWidth: 1))
                    }
                }
            }
        }
        .padding(20)
        .background(DS.canvasBg)
        .onAppear { store.runDoctor() }
    }
}

// MARK: - 5. 通用设置页
struct SettingsView: View {
    @ObservedObject var store: SwitchStore
    @State private var workspace: String = ""
    @State private var limit5h: Int = 200
    @State private var limit7d: Int = 1000
    @State private var themeMode: String = UserDefaults.standard.string(forKey: "agy_theme") ?? "system"

    private func applyTheme(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: "agy_theme")
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    var body: some View {
        Form {
            Section("外观") {
                Picker("明暗主题", selection: $themeMode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: themeMode) { newVal in
                    applyTheme(newVal)
                }
            }

            Section("常用接力工作区（多项目一键切换）") {
                ForEach(store.status?.workspaces ?? [workspace], id: \.self) { wsPath in
                    HStack {
                        Text(wsPath)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        if wsPath == store.status?.workspace {
                            Text("当前")
                                .font(.caption2.bold())
                                .foregroundColor(DS.brandBlue)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(DS.brandBlue.opacity(0.12)))
                        }
                        Spacer()
                        if wsPath != store.status?.workspace {
                            Button("设为当前") {
                                workspace = wsPath
                                store.manageWorkspace("use", path: wsPath)
                            }
                            .controlSize(.small)
                        }
                        Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: wsPath)) }) {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.plain)
                        if (store.status?.workspaces?.count ?? 1) > 1 {
                            Button(action: { store.manageWorkspace("remove", path: wsPath) }) {
                                Image(systemName: "trash").foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Button("+ 添加常用工作区目录...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        workspace = url.path
                        store.manageWorkspace("add", path: url.path)
                    }
                }
            }
            Section("本地额度预警参考线（未校准时使用）") {
                Stepper("5 小时窗口上限：\(limit5h) 轮", value: $limit5h, in: 20...500, step: 10)
                Stepper("7 天周上限：\(limit7d) 轮", value: $limit7d, in: 100...3000, step: 50)
            }
            Section("系统集成") {
                Toggle("登录 macOS 时自动启动 AGY Switch", isOn: Binding(
                    get: { store.autoStartEnabled },
                    set: { store.setAutoStart($0) }
                ))
            }
            HStack {
                Spacer()
                Button("保存设置") {
                    store.saveConfig(workspace: workspace, limit5h: limit5h, limit7d: limit7d)
                }
                .buttonStyle(PrimaryPillButtonStyle(compact: true))
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .background(DS.canvasBg)
        .onAppear {
            store.fetchAutoStart()
            if let s = store.status {
                workspace = s.workspace
                limit5h = s.warn_5h_limit
                limit7d = s.warn_7d_limit
            }
        }
    }
}

// MARK: - 6. 关于页（对标 CC Switch 风格）
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(LinearGradient(colors: [DS.brandBlue, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 48, height: 48)
                            Image(systemName: "bolt.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("AGY Switch").font(.title3.bold())
                            Text("版本 v3.4.0 · macOS 原生多账号串行接力工具")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("检查更新") {
                            if let url = URL(string: "https://github.com/tomyiyi/agy-switch/commits/main") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(PrimaryPillButtonStyle(compact: true))
                    }
                    .padding(18)

                    Divider()

                    HStack(spacing: 10) {
                        Button("GitHub 仓库") {
                            if let url = URL(string: "https://github.com/tomyiyi/agy-switch") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(SubtlePillButtonStyle())

                        Button("更新日志 (CHANGELOG)") {
                            if let url = URL(string: "https://github.com/tomyiyi/agy-switch/blob/main/CHANGELOG.md") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(SubtlePillButtonStyle())

                        Spacer()
                    }
                    .padding(14)

                    Divider()

                    HStack {
                        Label("如果 AGY Switch 帮到了你，欢迎在 GitHub 点个 Star ⭐", systemImage: "star.fill")
                            .font(.caption)
                            .foregroundColor(DS.brandOrange)
                        Spacer()
                        Button("去点 Star") {
                            if let url = URL(string: "https://github.com/tomyiyi/agy-switch") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(SubtlePillButtonStyle())
                    }
                    .padding(14)
                    .background(DS.brandOrange.opacity(0.08))
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(DS.cardBg).shadow(color: .black.opacity(0.04), radius: 8, y: 2))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.border, lineWidth: 1))
                .frame(maxWidth: 620)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .background(DS.canvasBg)
    }
}

// MARK: - 主框架
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
            .navigationSplitViewColumnWidth(min: 155, ideal: 170, max: 195)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack {
                        Circle()
                            .fill(store.status?.running_id.isEmpty == false ? DS.brandBlue : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(store.status?.running_id.isEmpty == false ? store.status!.running_id : "未运行")
                            .font(.caption.bold())
                            .lineLimit(1)
                        Spacer()
                        Text("v4.1")
                            .font(.system(size: 10, weight: .medium))
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
                        .background(Capsule().fill(Color.black.opacity(0.82)))
                        .shadow(radius: 8)
                        .padding(.bottom, 18)
                }
            }
        }
        .frame(minWidth: 960, minHeight: 620)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private let store = SwitchStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "⚡"
        statusItem.button?.action = #selector(toggleWindow)
        statusItem.button?.target = self

        let rootView = MainRootView(store: store)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 660),
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

    @objc private func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            store.refresh()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            store.refresh()
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
