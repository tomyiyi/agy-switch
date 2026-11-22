import Cocoa
import SwiftUI

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

struct StatusPayload: Decodable {
    let workspace: String
    let running_id: String
    let accounts: [AccountInfo]
    let sessions: [SessionInfo]
    let warn_5h_limit: Int
    let warn_7d_limit: Int
    let handoff_preview: String
    let handoff_updated: String
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
    case settings = "设置"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .accounts: return "person.2.fill"
        case .handoff: return "doc.text.fill"
        case .doctor: return "stethoscope"
        case .settings: return "gearshape.fill"
        }
    }
}

final class SwitchStore: ObservableObject {
    @Published var status: StatusPayload?
    @Published var doctor: DoctorPayload?
    @Published var toast: String = ""
    @Published var isBusy: Bool = false
    @Published var isRefreshing: Bool = false

    private let scriptPath = "/Users/tom/Desktop/workspace/agy-switch/server.py"

    init() {
        refresh()
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
        DispatchQueue.main.async {
            self.toast = msg
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            if self.toast == msg { self.toast = "" }
        }
    }

    func runDoctor() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let data = self.runCLI(["--cli-doctor"]),
                  let decoded = try? JSONDecoder().decode(DoctorPayload.self, from: data) else { return }
            DispatchQueue.main.async {
                self.doctor = decoded
            }
        }
    }

    func refresh(showFeedback: Bool = false) {
        DispatchQueue.main.async { self.isRefreshing = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let data = self.runCLI(["--cli-status"]),
                  let decoded = try? JSONDecoder().decode(StatusPayload.self, from: data) else {
                DispatchQueue.main.async {
                    self?.isRefreshing = false
                    if showFeedback { self?.showToast("刷新失败，请检查 server.py") }
                }
                return
            }
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            let nowStr = fmt.string(from: Date())
            DispatchQueue.main.async {
                self.status = decoded
                self.isRefreshing = false
                if showFeedback {
                    self.showToast("已刷新（\(nowStr)）· 当前运行：\(decoded.running_id.isEmpty ? "无" : decoded.running_id)")
                }
            }
        }
    }

    func calibrate(_ accId: String, pct5h: Int, pct7d: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-calibrate", accId, "\(pct5h)", "\(pct7d)"])
            DispatchQueue.main.async {
                self?.showToast("已校准 \(accId) 真实余量：5h \(pct5h)% · 周 \(pct7d)%")
                self?.refresh()
            }
        }
    }

    func saveHandoff(transcript: String, note: String) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self?.runCLI(["--cli-handoff-save", transcript, note])
            DispatchQueue.main.async {
                self?.isBusy = false
                self?.showToast("已生成 HANDOFF_AUTO.md，接力词已复制到剪贴板")
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
                self.showToast("已创建隔离账号 \(id)（已自动软链 Skills 与启动器）")
                self.refresh()
                if launchNow {
                    self.switchTo(id)
                }
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
}

// MARK: - 固定强调色主按钮（失焦也不变灰）
struct PrimaryAccentButtonStyle: ButtonStyle {
    var compact: Bool = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 5 : 9)
            .background(
                RoundedRectangle(cornerRadius: compact ? 7 : 9)
                    .fill(isEnabled ? Color.blue.opacity(configuration.isPressed ? 0.78 : 0.95) : Color.gray.opacity(0.35))
            )
    }
}

// MARK: - 通用剩余电量条组件（满血=满格，越用越短）
struct QuotaProgressBar: View {
    let label: String
    let remainPct: Int
    let used: Int
    let limit: Int
    let suffix: String
    let accent: Color

    var body: some View {
        let clamped = max(0, min(100, remainPct))
        let remainRatio = Double(clamped) / 100.0
        let tint: Color = clamped <= 10 ? .red : (clamped <= 25 ? .orange : accent)

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("余 \(clamped)% (\(used)轮)\(suffix)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(clamped <= 25 ? tint : .primary)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.16))
                    Capsule().fill(tint).frame(width: max(clamped > 0 ? 4 : 0, geo.size.width * remainRatio))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - 精致账号卡片
struct PoolAccountCard: View {
    let acc: AccountInfo
    let isBusy: Bool
    let onSwitch: () -> Void
    let onToggleCooldown: () -> Void
    var onEditNote: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        let dotColor: Color = acc.running ? .blue : (!acc.logged_in ? .orange : (acc.health == "cooldown" ? .red : (acc.health == "warning" ? .orange : .green)))
        let resetStr = acc.reset_5h_min > 0 ? " · \(acc.reset_5h_min / 60)h\(acc.reset_5h_min % 60)m" : ""

        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(acc.label)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let editAction = onEditNote {
                        Button(action: editAction) {
                            Label(acc.note.isEmpty ? "加备注" : acc.note, systemImage: "tag")
                                .font(.caption2)
                                .foregroundColor(acc.note.isEmpty ? .secondary : .accentColor)
                        }
                        .buttonStyle(.plain)
                    } else if !acc.note.isEmpty {
                        Text(acc.note).font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
                if acc.running {
                    Text("运行中")
                        .font(.caption2.bold())
                        .foregroundColor(.blue)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.14))
                        .cornerRadius(99)
                } else if !acc.logged_in {
                    Text("待登录")
                        .font(.caption2.bold())
                        .foregroundColor(.orange)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.14))
                        .cornerRadius(99)
                } else if acc.health == "cooldown" {
                    Text("冷却 \(acc.cooldown_remaining_min)m")
                        .font(.caption2.bold())
                        .foregroundColor(.red)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.red.opacity(0.14))
                        .cornerRadius(99)
                } else {
                    Text("满血")
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.green.opacity(0.14))
                        .cornerRadius(99)
                }
            }

            VStack(spacing: 8) {
                QuotaProgressBar(label: acc.calibrated ? "5h 窗口（已校准）" : "5h 窗口", remainPct: acc.remain_5h_pct, used: acc.turns_5h, limit: acc.limit_5h, suffix: resetStr, accent: .green)
                QuotaProgressBar(label: acc.calibrated ? "周额度（已校准）" : "周额度", remainPct: acc.remain_7d_pct, used: acc.turns_7d, limit: acc.limit_7d, suffix: "", accent: .blue)
            }

            HStack(spacing: 6) {
                Text("活跃 \(acc.latest_active)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if acc.id != "main", let delAction = onDelete {
                    Button(action: delAction) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除此隔离账号（移入废纸篓）")
                }
                Button(acc.health == "cooldown" ? "恢复" : "冷却") {
                    onToggleCooldown()
                }
                .controlSize(.small)

                Button(acc.running ? "当前" : (!acc.logged_in ? "去登录" : "切到此号")) {
                    onSwitch()
                }
                .buttonStyle(PrimaryAccentButtonStyle(compact: true))
                .disabled(acc.running || !acc.app_exists || isBusy)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(acc.running ? Color.blue.opacity(0.6) : Color.secondary.opacity(0.15), lineWidth: acc.running ? 1.5 : 1)
        )
    }
}

// MARK: - 1. 总览页 (Hero + 推荐备用池)
struct DashboardView: View {
    @ObservedObject var store: SwitchStore
    @State private var showCalibrate: Bool = false
    @State private var cal5h: Double = 80
    @State private var cal7d: Double = 95

    var body: some View {
        let accounts = store.status?.accounts ?? []
        let activeAcc = accounts.first(where: { $0.running })
        let recommended = accounts.filter { $0.health == "ready" && !$0.running && $0.app_exists }.prefix(4)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Hero 当前账号大卡片
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("当前活跃账号")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 8) {
                                Text(activeAcc?.label ?? "当前无运行实例")
                                    .font(.title2.bold())
                                if let a = activeAcc, a.pid > 0 {
                                    Text("PID \(a.pid)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(Color.blue.opacity(0.12))
                                        .cornerRadius(6)
                                }
                                if let a = activeAcc, a.reset_5h_min > 0 {
                                    Text("5h 窗口 \(a.reset_5h_min / 60)h\(a.reset_5h_min % 60)m 后滚动重置")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.12))
                                        .cornerRadius(6)
                                }
                            }
                            Text("当前接力工作区：\(store.status?.workspace ?? "-")")
                                .font(.caption)
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
                                .controlSize(.large)
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
                            .controlSize(.large)
                            .disabled(store.isRefreshing)

                            Button(action: { store.switchTo("") }) {
                                Label("一键接力到下一个满血号", systemImage: "bolt.fill")
                            }
                            .buttonStyle(PrimaryAccentButtonStyle(compact: false))
                            .disabled(store.isBusy)
                        }
                    }

                    if let a = activeAcc {
                        HStack(spacing: 24) {
                            QuotaProgressBar(
                                label: a.calibrated ? "5小时窗口（已校准）" : "5小时窗口（本地估算）",
                                remainPct: a.remain_5h_pct,
                                used: a.turns_5h,
                                limit: a.limit_5h,
                                suffix: "",
                                accent: .green
                            )
                            QuotaProgressBar(
                                label: a.calibrated ? "本周累计 7d（已校准）" : "本周累计 7d（本地估算）",
                                remainPct: a.remain_7d_pct,
                                used: a.turns_7d,
                                limit: a.limit_7d,
                                suffix: "",
                                accent: .blue
                            )
                        }
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.35), lineWidth: 1.2))
                .sheet(isPresented: $showCalibrate) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("校准真实剩余额度：\(activeAcc?.label ?? "")")
                            .font(.headline)
                        Text("对照 Antigravity 右下角弹窗里的真实余量拖动滑块，保存后将以此为基准随对话自动递减。")
                            .font(.caption)
                            .foregroundColor(.secondary)

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
                                if let a = activeAcc {
                                    store.calibrate(a.id, pct5h: Int(cal5h), pct7d: Int(cal7d))
                                }
                                showCalibrate = false
                            }
                            .buttonStyle(PrimaryAccentButtonStyle(compact: true))
                        }
                    }
                    .padding(20)
                    .frame(width: 380)
                }

                // 推荐备用账号网格
                HStack {
                    Text("推荐备用满血号")
                        .font(.headline)
                    Spacer()
                    Text("满血 \(accounts.filter { $0.health == "ready" }.count) / 共 \(accounts.count) 个")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(Array(recommended)) { acc in
                        PoolAccountCard(
                            acc: acc,
                            isBusy: store.isBusy,
                            onSwitch: { store.switchTo(acc.id) },
                            onToggleCooldown: { store.setCooldown(acc.id, hours: 5) }
                        )
                    }
                }
            }
            .padding(22)
        }
    }
}

// MARK: - 2. 账号池页（含增删改备注与刷新）
struct AccountsView: View {
    @ObservedObject var store: SwitchStore
    @State private var filter: String = "all"
    @State private var searchText: String = ""
    @State private var showAddSheet: Bool = false
    @State private var newAccId: String = ""
    @State private var newAccNote: String = ""
    @State private var launchAfterAdd: Bool = false

    @State private var editingNoteAcc: AccountInfo? = nil
    @State private var editingNoteText: String = ""
    @State private var deletingAcc: AccountInfo? = nil

    var body: some View {
        let all = store.status?.accounts ?? []
        let filtered = all.filter { acc in
            let matchFilter = (filter == "all") || (filter == "ready" && acc.health == "ready") || (filter == "cooldown" && acc.health == "cooldown")
            let q = searchText.trimmingCharacters(in: .whitespaces)
            let matchSearch = q.isEmpty || acc.label.localizedCaseInsensitiveContains(q) || acc.note.localizedCaseInsensitiveContains(q)
            return matchFilter && matchSearch
        }

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("搜索账号名或备注...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)

                Picker("", selection: $filter) {
                    Text("全部 (\(all.count))").tag("all")
                    Text("满血 (\(all.filter { $0.health == "ready" }.count))").tag("ready")
                    Text("冷却 (\(all.filter { $0.health == "cooldown" }.count))").tag("cooldown")
                }
                .pickerStyle(.segmented)
                .frame(width: 245)

                Spacer()

                Button(action: { store.refresh() }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }

                Button(action: {
                    newAccId = ""
                    newAccNote = ""
                    launchAfterAdd = false
                    showAddSheet = true
                }) {
                    Label("添加账号", systemImage: "plus")
                }
                .buttonStyle(PrimaryAccentButtonStyle(compact: true))
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(filtered) { acc in
                        PoolAccountCard(
                            acc: acc,
                            isBusy: store.isBusy,
                            onSwitch: { store.switchTo(acc.id) },
                            onToggleCooldown: {
                                store.setCooldown(acc.id, hours: acc.health == "cooldown" ? 0 : 5)
                            },
                            onEditNote: {
                                editingNoteAcc = acc
                                editingNoteText = acc.note
                            },
                            onDelete: {
                                deletingAcc = acc
                            }
                        )
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        // 新增账号弹窗
        .sheet(isPresented: $showAddSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("添加新的隔离账号")
                    .font(.title3.bold())
                Text("系统将自动创建独立 HOME 目录、软链公共 Skills 与桌面 .app 启动器，创建后登录一次即可加入接力池。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("账号标识（如 11-myaccount，仅字母数字横线）", text: $newAccId)
                    .textFieldStyle(.roundedBorder)
                TextField("备注（可选，如 邮箱 / Pro主力）", text: $newAccNote)
                    .textFieldStyle(.roundedBorder)
                Toggle("创建后立即切换到此号并打开登录", isOn: $launchAfterAdd)
                    .font(.callout)

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
                    .buttonStyle(PrimaryAccentButtonStyle(compact: true))
                    .disabled(newAccId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
        // 编辑备注弹窗
        .sheet(item: $editingNoteAcc) { acc in
            VStack(alignment: .leading, spacing: 12) {
                Text("编辑备注：\(acc.label)").font(.headline)
                TextField("输入备注（留空清除）", text: $editingNoteText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("取消") { editingNoteAcc = nil }
                    Button("保存") {
                        store.updateNote(acc.id, note: editingNoteText)
                        editingNoteAcc = nil
                    }
                    .buttonStyle(PrimaryAccentButtonStyle(compact: true))
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        // 删除二次确认
        .alert("确认删除账号？", isPresented: Binding(get: { deletingAcc != nil }, set: { if !$0 { deletingAcc = nil } })) {
            Button("取消", role: .cancel) { deletingAcc = nil }
            Button("移入废纸篓", role: .destructive) {
                if let target = deletingAcc {
                    store.deleteAccount(target.id)
                }
                deletingAcc = nil
            }
        } message: {
            Text("将把 \(deletingAcc?.label ?? "") 的隔离目录和桌面启动器安全移入废纸篓，随时可从废纸篓恢复。")
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
                Text("生成跨账号交接单 (HANDOFF_AUTO.md)")
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

                    Button("生成交接单并复制接力词") {
                        store.saveHandoff(transcript: selectedPath, note: extraNote)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)
                }

                TextField("可选：给下一个号的特别交代（例如：先修登录报错，不要改数据库）", text: $extraNote)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))

            HStack {
                Text("当前 HANDOFF_AUTO.md 预览")
                    .font(.subheadline.bold())
                Spacer()
                if let upd = store.status?.handoff_updated, !upd.isEmpty {
                    Text("更新于 \(upd)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ScrollView {
                Text(store.status?.handoff_preview.isEmpty == false ? store.status!.handoff_preview : "当前工作区尚未生成 HANDOFF_AUTO.md，点击上方按钮即可生成。")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
        }
        .padding(22)
    }
}

// MARK: - 4. 运行体检页
struct DoctorView: View {
    @ObservedObject var store: SwitchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地运行环境体检")
                        .font(.title3.bold())
                    Text(store.doctor != nil ? "最近检查：\(store.doctor!.checked_at)" : "点击右侧按钮开始检查本机运行状态")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("重新体检") { store.runDoctor() }
                    .buttonStyle(PrimaryAccentButtonStyle(compact: true))
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.doctor?.checks ?? []) { item in
                        let icon = item.status == "ok" ? "checkmark.circle.fill" : (item.status == "warn" ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                        let color: Color = item.status == "ok" ? .green : (item.status == "warn" ? .orange : .red)

                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: icon)
                                .foregroundColor(color)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.headline)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.25), lineWidth: 1))
                    }
                }
            }
        }
        .padding(22)
        .onAppear { store.runDoctor() }
    }
}

// MARK: - 5. 设置页
struct SettingsView: View {
    @ObservedObject var store: SwitchStore
    @State private var workspace: String = ""
    @State private var limit5h: Int = 80
    @State private var limit7d: Int = 400

    var body: some View {
        Form {
            Section("接力工作区") {
                HStack {
                    TextField("工作区目录", text: $workspace)
                        .textFieldStyle(.roundedBorder)
                    Button("选择文件夹...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            workspace = url.path
                        }
                    }
                }
            }

            Section("本地额度预警参考线（按对话轮数估算）") {
                Stepper("5 小时窗口上限：\(limit5h) 轮", value: $limit5h, in: 20...500, step: 10)
                Stepper("7 天周上限：\(limit7d) 轮", value: $limit7d, in: 100...3000, step: 50)
            }

            HStack {
                Spacer()
                Button("保存设置") {
                    store.saveConfig(workspace: workspace, limit5h: limit5h, limit7d: limit7d)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onAppear {
            if let s = store.status {
                workspace = s.workspace
                limit5h = s.warn_5h_limit
                limit7d = s.warn_7d_limit
            }
        }
    }
}

// MARK: - 主框架 (侧边栏 + 内容区)
struct MainRootView: View {
    @ObservedObject var store: SwitchStore
    @State private var tab: SidebarTab = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $tab) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 155, ideal: 175, max: 200)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack {
                        Circle()
                            .fill(store.status?.running_id.isEmpty == false ? Color.blue : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(store.status?.running_id.isEmpty == false ? store.status!.running_id : "未运行")
                            .font(.caption.bold())
                            .lineLimit(1)
                        Spacer()
                        Button(action: { store.refresh() }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
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
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !store.toast.isEmpty {
                    Text(store.toast)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.accentColor))
                        .shadow(radius: 6)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 880, minHeight: 580)
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
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "AGY Switch"
        window.titlebarAppearsTransparent = false
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
