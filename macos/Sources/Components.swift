import Cocoa
import SwiftUI

// MARK: - 真实本地用量指标微块（零假云端百分比）
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

// MARK: - 结构化家庭组与角色编辑弹窗（免手敲方括号语法）
struct NoteEditorSheet: View {
    let title: String
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var selectedGroup: String
    @State private var isManager: Bool
    @State private var isSolo: Bool
    @State private var isFlagged: Bool
    @State private var customNote: String

    init(
        title: String,
        acc: AccountInfo,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.onCancel = onCancel
        self.onSave = onSave

        let clean = acc.displayCleanNote
            .replacingOccurrences(of: "⚠️待二次验证", with: "")
            .replacingOccurrences(of: "⚠️", with: "")
            .replacingOccurrences(of: "独享 · ", with: "")
            .replacingOccurrences(of: "独享 AI Pro", with: "")
            .replacingOccurrences(of: "独享AI Pro", with: "")
            .replacingOccurrences(of: "独享", with: "")
            .trimmingCharacters(in: .whitespaces)
        _selectedGroup = State(initialValue: acc.groupLetter)
        _isManager = State(initialValue: acc.isGroupManager)
        _isSolo = State(initialValue: acc.isExplicitSolo)
        _isFlagged = State(initialValue: acc.isFlagged)
        _customNote = State(initialValue: clean)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                Text("所属 Google 家庭组").font(.caption).foregroundColor(.secondary)
                Picker("", selection: $selectedGroup) {
                    Text("未分组").tag("")
                    ForEach(["A", "B", "C", "D", "E", "F"], id: \.self) { g in
                        Text("\(g) 组").tag(g)
                    }
                }
                .pickerStyle(.segmented)
            }

            if !selectedGroup.isEmpty {
                HStack(spacing: 16) {
                    Picker("组内角色", selection: $isManager) {
                        Text("★ 主账号 (管理员)").tag(true)
                        Text("成员 (子账号)").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Toggle("标记为独享组（未与他人共享，切号最高优先级）", isOn: $isSolo)
                    .font(.system(size: 12))
            }

            Toggle("⚠️ 标记异常 / 待二次验证（自动接力时跳过此号）", isOn: $isFlagged)
                .font(.system(size: 12))
                .foregroundColor(isFlagged ? DS.brandOrange : .primary)

            VStack(alignment: .leading, spacing: 6) {
                Text("补充说明（可选，如绑定邮箱、剩余邀请名额）").font(.caption).foregroundColor(.secondary)
                TextField("例如：AI Pro 5TB · 余 3 名额", text: $customNote)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("清空全部标签") {
                    onSave("")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .buttonStyle(.plain)

                Spacer()
                Button("取消", action: onCancel)
                Button("保存") {
                    let composed = FamilyVisual.composeNote(
                        group: selectedGroup,
                        isManager: isManager,
                        isSolo: isSolo,
                        isFlagged: isFlagged,
                        note: customNote
                    )
                    onSave(composed)
                }
                .buttonStyle(PrimaryPillButtonStyle(compact: true))
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - 标准网格精致卡片（强区分主账号 vs 子账号 + 跨组推荐徽章 + 右键快捷菜单）
struct CockpitStyleAccountCard: View {
    let acc: AccountInfo
    let isBusy: Bool
    var activeGroupKey: String? = nil
    var isTopRecommended: Bool = false
    let onSwitch: () -> Void
    let onToggleCooldown: () -> Void
    var onEditNote: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovered: Bool = false

    var body: some View {
        let fam = FamilyVisual.from(acc)
        let isSameGroupAsActive = !acc.running && fam.groupKey != "未分组" && fam.groupKey == activeGroupKey
        let badgeColor: Color = acc.running
            ? DS.brandBlue
            : (!acc.logged_in ? DS.brandOrange : (acc.health == "cooldown" ? DS.brandRed : (fam.isFlagged ? DS.brandOrange : DS.brandGreen)))
        let badgeText: String? = acc.running
            ? "当前运行"
            : (!acc.logged_in ? "待登录" : (acc.health == "cooldown" ? "冷却 \(acc.cooldown_remaining_min)m" : (fam.isFlagged ? "待验证" : nil)))
        let sub5h = !acc.logged_in
            ? "需先登录"
            : (acc.reset_5h_min > 0 ? "\(acc.reset_5h_min / 60)h\(acc.reset_5h_min % 60)m 后重置" : "空闲满血")
        let sub7d = !acc.logged_in ? "无本地记录" : "活跃 \(acc.latest_active)"

        VStack(alignment: .leading, spacing: 0) {
            // 主账号专属顶部细识别色带（跨组首选改用主卡绿边，避免双色抢镜）
            if fam.isManager {
                LinearGradient(
                    colors: [fam.tint.opacity(0.85), fam.tint.opacity(0.35)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 2.5)
            }

            VStack(alignment: .leading, spacing: fam.isManager ? 10 : 8.5) {
                // 顶行：聚焦账号名，去掉常态“已登录”冗余胶囊杜绝标题截断
                HStack(alignment: .center, spacing: 7) {
                    if fam.isManager {
                        ZStack {
                            Circle()
                                .fill(fam.tint.opacity(0.14))
                                .frame(width: 21, height: 21)
                            Image(systemName: "crown.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(fam.tint)
                        }
                    } else {
                        Circle().fill(badgeColor).frame(width: 7, height: 7)
                    }

                    Text(acc.label)
                        .font(.system(size: fam.isManager ? 14.5 : 13.5, weight: fam.isManager ? .bold : .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    if isTopRecommended {
                        Label("跨组首选", systemImage: "sparkles")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(DS.brandGreen)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(DS.brandGreen.opacity(0.14)))
                    } else if isSameGroupAsActive {
                        Text("同组")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                            .help("与当前运行账号同属 \(fam.groupKey)，建议跨组切号")
                    }

                    if let bText = badgeText {
                        Text(bText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(badgeColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(badgeColor.opacity(0.13)))
                    }
                }

                // 真实绑定 Google 邮箱或撞车提示
                if !acc.displayEmail.isEmpty {
                    Text(acc.displayEmail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if !acc.logged_in && !acc.duplicateTarget.isEmpty {
                    Label("与 \(acc.duplicateTarget) 邮箱重复，无需再登", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.brandOrange)
                        .lineLimit(1)
                }

                // 家庭组胶囊行：克制的语义描边风格，避免高饱和色块堆叠
                HStack(spacing: 6) {
                    Button(action: { onEditNote?() }) {
                        HStack(spacing: 5) {
                            if !fam.shortBadge.isEmpty {
                                HStack(spacing: 3) {
                                    if fam.isManager {
                                        Image(systemName: "star.fill").font(.system(size: 7.5))
                                    }
                                    Text(fam.isManager ? "\(fam.shortBadge)·主" : "\(fam.shortBadge)·成员")
                                        .font(.system(size: 10, weight: fam.isManager ? .bold : .medium))
                                }
                                .foregroundColor(fam.tint)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(fam.tint.opacity(fam.isManager ? 0.13 : 0.07))
                                        .overlay(Capsule().stroke(fam.tint.opacity(fam.isManager ? 0.35 : 0.2), lineWidth: 0.7))
                                )

                                if fam.isSolo {
                                    Text("独享")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundColor(DS.brandGreen)
                                        .padding(.horizontal, 5.5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(DS.brandGreen.opacity(0.11)))
                                }

                                if !fam.cleanNote.isEmpty {
                                    Text(fam.cleanNote)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(fam.isFlagged ? DS.brandOrange : .secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(fam.cleanNote)
                                }
                            } else {
                                Image(systemName: "tag")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.secondary.opacity(0.7))
                                Text(fam.cleanNote.isEmpty ? "设置家庭组 / 备注" : fam.cleanNote)
                                    .font(.system(size: 11))
                                    .foregroundColor(fam.cleanNote.isEmpty ? .secondary.opacity(0.7) : .secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(onEditNote == nil)

                    Spacer(minLength: 0)
                }

                // 中部：双列 100% 真实本地对话轮数
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

                // 底行：操作图标 + 切换按钮
                HStack(spacing: 9) {
                    if let edit = onEditNote {
                        Button(action: edit) {
                            Image(systemName: "slider.horizontal.below.rectangle")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("设置家庭组角色与备注")
                    }

                    if acc.logged_in {
                        Button(action: onToggleCooldown) {
                            Image(systemName: acc.health == "cooldown" ? "bolt.heart" : "snowflake")
                                .font(.system(size: 12))
                                .foregroundColor(acc.health == "cooldown" ? DS.brandGreen : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(acc.health == "cooldown" ? "解除冷却恢复可用" : "标记冷却 5 小时")
                    }

                    if acc.id != "main", let del = onDelete {
                        Button(action: del) {
                            Image(systemName: "trash")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("安全移入废纸篓")
                    }

                    Spacer()

                    Button(acc.running ? "使用中" : (!acc.logged_in ? "去登录" : "切换")) {
                        onSwitch()
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true, tint: isTopRecommended ? DS.brandGreen : DS.brandBlue))
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
                .shadow(
                    color: Color.black.opacity(isHovered ? 0.09 : (fam.isManager ? 0.06 : 0.035)),
                    radius: isHovered ? 10 : (fam.isManager ? 8 : 5),
                    y: 2
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(
                    acc.running
                        ? DS.brandBlue.opacity(0.78)
                        : (isTopRecommended
                            ? DS.brandGreen.opacity(0.55)
                            : (fam.isManager ? fam.tint.opacity(isHovered ? 0.65 : 0.42) : (isHovered ? DS.brandBlue.opacity(0.3) : DS.border))),
                    lineWidth: (acc.running || fam.isManager || isTopRecommended) ? 1.5 : 1
                )
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contextMenu {
            if !acc.running && acc.app_exists {
                Button("切换到 \(acc.label)", action: onSwitch)
            }
            if let edit = onEditNote {
                Button("编辑家庭组与备注...", action: edit)
            }
            if acc.logged_in {
                Button(acc.health == "cooldown" ? "解除冷却" : "标记冷却 5 小时", action: onToggleCooldown)
            }
            Button("复制账号名") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(acc.label, forType: .string)
            }
        }
    }
}

// MARK: - 紧凑小卡片（高密度模式）
struct CompactMiniAccountCard: View {
    let acc: AccountInfo
    let isBusy: Bool
    let onSwitch: () -> Void
    var onEditNote: (() -> Void)? = nil

    var body: some View {
        let fam = FamilyVisual.from(acc)
        let dotColor: Color = acc.running ? DS.brandBlue : (!acc.logged_in ? DS.brandOrange : (acc.health == "cooldown" ? DS.brandRed : DS.brandGreen))

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if fam.isManager {
                    Image(systemName: "crown.fill").font(.system(size: 9.5)).foregroundColor(fam.tint)
                } else {
                    Circle().fill(dotColor).frame(width: 6.5, height: 6.5)
                }
                Text(acc.label)
                    .font(.system(size: fam.isManager ? 12.5 : 12, weight: fam.isManager ? .bold : .semibold))
                    .lineLimit(1)
                Spacer()
                if !fam.shortBadge.isEmpty {
                    Text(fam.isManager ? "\(fam.shortBadge)·主" : fam.shortBadge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(fam.isManager ? .white : fam.tint)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(fam.isManager ? fam.tint : fam.tint.opacity(0.13)))
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
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(acc.running ? DS.brandBlue.opacity(0.65) : (fam.isManager ? fam.tint.opacity(0.4) : DS.border), lineWidth: (acc.running || fam.isManager) ? 1.4 : 1)
        )
        .contextMenu {
            if let edit = onEditNote { Button("编辑家庭组与备注...", action: edit) }
        }
    }
}

// MARK: - 横向列表行（表格模式）
struct AccountListRow: View {
    let acc: AccountInfo
    let isBusy: Bool
    let onSwitch: () -> Void
    let onToggleCooldown: () -> Void
    let onEditNote: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let fam = FamilyVisual.from(acc)
        let dotColor: Color = acc.running ? DS.brandBlue : (!acc.logged_in ? DS.brandOrange : (acc.health == "cooldown" ? DS.brandRed : DS.brandGreen))

        HStack(spacing: 14) {
            HStack(spacing: 8) {
                if fam.isManager {
                    Image(systemName: "crown.fill").font(.system(size: 11)).foregroundColor(fam.tint)
                } else {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(acc.label).font(.system(size: fam.isManager ? 13.5 : 13, weight: fam.isManager ? .bold : .semibold)).lineLimit(1)
                        if !fam.shortBadge.isEmpty {
                            Text("\(fam.shortBadge)·\(fam.isManager ? "主账号" : "成员")")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(fam.isManager ? .white : fam.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(fam.isManager ? fam.tint : fam.tint.opacity(0.13)))
                        }
                    }
                    let subLine = !acc.displayEmail.isEmpty
                        ? (fam.cleanNote.isEmpty ? acc.displayEmail : "\(acc.displayEmail) · \(fam.cleanNote)")
                        : (fam.cleanNote.isEmpty ? "活跃 \(acc.latest_active)" : fam.cleanNote)
                    Text(subLine)
                        .font(.system(size: 10.5))
                        .foregroundColor(fam.isFlagged ? DS.brandOrange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 245, alignment: .leading)

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
                Button(action: onEditNote) {
                    Image(systemName: "slider.horizontal.below.rectangle").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("编辑家庭组与备注")

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
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(acc.running ? DS.brandBlue.opacity(0.65) : (fam.isManager ? fam.tint.opacity(0.4) : DS.border), lineWidth: (acc.running || fam.isManager) ? 1.4 : 1)
        )
    }
}

// MARK: - 极简 HUD 悬浮切号面板 (Cockpit HUD v5.6 · 真·全键盘 + 即时搜索 + 零重复)

final class HUDController: ObservableObject {
    @Published var searchText: String = ""
    @Published var selectedIndex: Int = 0
    @Published var focusTrigger: UUID = UUID()

    func resetForOpen() {
        searchText = ""
        selectedIndex = 0
        focusTrigger = UUID()
    }

    func moveSelection(delta: Int, count: Int) {
        guard count > 0 else {
            selectedIndex = 0
            return
        }
        selectedIndex = (selectedIndex + delta + count) % count
    }
}

struct QuickSwitchHUDView: View {
    @ObservedObject var store: SwitchStore
    @ObservedObject var hud: HUDController
    var onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    private var allCandidates: [AccountInfo] {
        guard let s = store.status else { return [] }
        return s.accounts.filter { acc in
            acc.logged_in && !acc.running && acc.health != "cooldown" && acc.app_exists && !acc.isFlagged
        }
    }

    var displayItems: [AccountInfo] {
        let clean = hud.searchText.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty {
            let rec = store.recommendedAccounts
            if !rec.isEmpty { return Array(rec.prefix(8)) }
            return Array(allCandidates.prefix(8))
        }
        let q = clean.lowercased()
        return Array(allCandidates.filter { acc in
            acc.label.lowercased().contains(q) ||
            acc.id.lowercased().contains(q) ||
            acc.displayEmail.lowercased().contains(q) ||
            acc.groupLetter.lowercased().contains(q) ||
            acc.note.lowercased().contains(q)
        }.prefix(8))
    }

    private func triggerSwitch(_ acc: AccountInfo, isTopAuto: Bool = false) {
        onDismiss()
        store.switchTo(isTopAuto ? "" : acc.id)
    }

    var body: some View {
        let items = displayItems
        let safeIndex = items.isEmpty ? 0 : min(max(0, hud.selectedIndex), items.count - 1)

        VStack(spacing: 0) {
            // 顶栏：当前运行账号 + 真实邮箱 + 快捷键提示
            HStack(spacing: 8) {
                let activeId = store.status?.running_id ?? ""
                let activeAcc = store.status?.accounts.first(where: { a in a.running })
                let pct = activeAcc?.remain_5h_pct ?? 100

                Circle()
                    .fill(activeId.isEmpty ? Color.gray : (pct >= 60 ? DS.brandGreen : (pct >= 20 ? DS.brandOrange : Color.red)))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    let activeTag = activeAcc.map { a -> String in
                        let g = a.groupLetter
                        return g.isEmpty ? a.label : "\(a.label) (\(g)组\(a.isGroupManager ? "·主" : ""))"
                    } ?? (activeId.isEmpty ? "无运行实例" : activeId)

                    Text("当前：\(activeTag)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let email = activeAcc?.displayEmail, !email.isEmpty {
                        Text(email)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 6)

                Text("↑↓ 选 · ↩ 切 · ⌘1-5 · Esc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color.primary.opacity(0.03))

            Divider()

            // 即时搜索框（呼出自动聚焦，输入回车直切当前选中项）
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                TextField("搜索账号、邮箱、组别 (A/B/C/D) 或备注...", text: $hud.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onChange(of: hud.searchText) {
                        hud.selectedIndex = 0
                    }
                    .onSubmit {
                        if !items.isEmpty {
                            let target = items[safeIndex]
                            let isTopAuto = hud.searchText.trimmingCharacters(in: .whitespaces).isEmpty && safeIndex == 0
                            triggerSwitch(target, isTopAuto: isTopAuto)
                        }
                    }

                if !hud.searchText.isEmpty {
                    Button(action: { hud.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.02))

            Divider()

            // 合并候选列表（第 0 项即为跨组首选黄金高亮，消除重复卡片）
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                    Text("未找到匹配的就绪账号")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 36)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, acc in
                                let fam = FamilyVisual.from(acc)
                                let isSelected = (index == safeIndex)
                                let isTopHero = (index == 0 && hud.searchText.trimmingCharacters(in: .whitespaces).isEmpty)

                                Button(action: {
                                    triggerSwitch(acc, isTopAuto: isTopHero)
                                }) {
                                    HStack(spacing: 10) {
                                        if isTopHero {
                                            ZStack {
                                                Circle()
                                                    .fill(LinearGradient(colors: [DS.brandBlue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                    .frame(width: 28, height: 28)
                                                Image(systemName: "bolt.fill")
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundColor(.white)
                                            }
                                        } else {
                                            Text(index < 5 ? "⌘\(index + 1)" : "·")
                                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                                .foregroundColor(isSelected ? DS.brandBlue : .secondary)
                                                .frame(width: 26, height: 20)
                                                .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? DS.brandBlue.opacity(0.14) : Color.primary.opacity(0.06)))
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 5) {
                                                Circle().fill(fam.tint).frame(width: 7, height: 7)
                                                Text(acc.label)
                                                    .font(.system(size: isTopHero ? 13 : 12.5, weight: isTopHero || isSelected ? .bold : .medium))
                                                    .foregroundColor(.primary)
                                                    .lineLimit(1)
                                                if fam.isManager {
                                                    Image(systemName: "crown.fill")
                                                        .font(.system(size: 9.5))
                                                        .foregroundColor(.orange)
                                                }
                                                if !fam.shortBadge.isEmpty {
                                                    Text(fam.shortBadge)
                                                        .font(.system(size: 9.5, weight: .semibold))
                                                        .foregroundColor(fam.tint)
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 1)
                                                        .background(Capsule().fill(fam.tint.opacity(0.13)))
                                                }
                                                if isTopHero {
                                                    Text("跨组首选")
                                                        .font(.system(size: 9.5, weight: .bold))
                                                        .foregroundColor(.white)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 1.5)
                                                        .background(Capsule().fill(DS.brandBlue))
                                                }
                                            }

                                            let subtitle = !acc.displayEmail.isEmpty
                                                ? acc.displayEmail
                                                : (acc.recommendTag.isEmpty ? fam.cleanNote : acc.recommendTag)
                                            if !subtitle.isEmpty {
                                                Text(subtitle)
                                                    .font(.system(size: 10.5, design: !acc.displayEmail.isEmpty ? .monospaced : .default))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }

                                        Spacer(minLength: 6)

                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text("5h \(acc.turns_5h)轮")
                                                .font(.system(size: 10.5, weight: .medium))
                                                .foregroundColor(acc.turns_5h == 0 ? DS.brandGreen : .secondary)
                                            if isSelected {
                                                Text("↩ 接力")
                                                    .font(.system(size: 9.5, weight: .bold))
                                                    .foregroundColor(DS.brandBlue)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, isTopHero ? 9 : 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9)
                                            .fill(isSelected ? DS.brandBlue.opacity(0.11) : (isTopHero ? DS.brandBlue.opacity(0.05) : Color.primary.opacity(0.03)))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9)
                                            .stroke(isSelected ? DS.brandBlue.opacity(0.6) : (isTopHero ? DS.brandBlue.opacity(0.25) : Color.clear), lineWidth: isSelected ? 1.4 : 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(acc.id)
                                .onHover { hovering in
                                    if hovering { hud.selectedIndex = index }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: hud.selectedIndex) {
                        if !items.isEmpty {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(items[safeIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }

            Divider()

            // 底部操作栏：复制接力词 + 3TB 状态 + 可点击重测的节点哨兵 + 完整控制台
            HStack(spacing: 8) {
                Button(action: {
                    onDismiss()
                    store.saveHandoff(transcript: "", note: "")
                }) {
                    Label("复制接力词", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)

                let tbOnline = store.status?.tb3_online ?? false
                HStack(spacing: 4) {
                    Circle()
                        .fill(tbOnline ? DS.brandGreen : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(tbOnline ? "3TB" : "3TB离线")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(tbOnline ? DS.brandGreen : .secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.05)))

                if let net = store.networkStatus ?? store.status?.network {
                    Button(action: { store.probeNetwork(showFeedback: true) }) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(net.clean_for_antigravity ? DS.brandGreen : Color.red)
                                .frame(width: 6, height: 6)
                            Text(store.isProbingNetwork ? "测活中..." : net.badgeTitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(net.clean_for_antigravity ? DS.brandGreen : .red)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(net.clean_for_antigravity ? Color.green.opacity(0.08) : Color.red.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help(net.helpDetail)
                }

                Spacer()

                Button(action: {
                    onDismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { w in !(w is HUDWindow) })?.makeKeyAndOrderFront(nil)
                }) {
                    Text("控制台 ↗")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.brandBlue)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 460, height: 430)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 24, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
        .onChange(of: hud.focusTrigger) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                searchFocused = true
            }
        }
    }
}

// MARK: - 反重力代理哨兵 + Clash Verge 节点直控 Popover
struct NetworkSentinelPopover: View {
    @ObservedObject var store: SwitchStore

    var body: some View {
        let net = store.networkStatus ?? store.status?.network
        let clash = store.clashStatus ?? net?.clash ?? store.status?.clash

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill((net?.clean_for_antigravity ?? false) ? DS.brandGreen : DS.brandRed)
                    .frame(width: 8, height: 8)
                Text("代理节点哨兵")
                    .font(.system(size: 13.5, weight: .bold))
                Spacer()
                Button(action: { store.probeNetwork(showFeedback: true) }) {
                    HStack(spacing: 4) {
                        if store.isProbingNetwork {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10.5))
                        }
                        Text(store.isProbingNetwork ? "测活中" : "重测出口")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(SubtlePillButtonStyle())
                .disabled(store.isProbingNetwork || store.isSwitchingClash)
            }

            if let n = net {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("出口 IP / 地区")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(n.exit_ip.isEmpty ? "未知" : n.exit_ip) · \(n.country.isEmpty ? "—" : n.country)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    HStack {
                        Text("Antigravity 通道")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(n.clean_for_antigravity ? "畅通 (\(n.latency_ms)ms)" : (n.error_message.isEmpty ? "异常" : "受限/不可达"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(n.clean_for_antigravity ? DS.brandGreen : DS.brandRed)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(DS.insetBg))
            }

            if let c = clash, c.available {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clash Verge · \(c.active_group)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("当前：\(c.active_node)")
                            .font(.system(size: 12.5, weight: .bold))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(action: { store.clashAutoSelect(group: c.active_group) }) {
                        HStack(spacing: 4) {
                            if store.isSwitchingClash {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "wand.and.stars").font(.system(size: 10.5))
                            }
                            Text(store.isSwitchingClash ? "优选中..." : "自动优选")
                        }
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true, tint: DS.brandBlue))
                    .disabled(store.isSwitchingClash)
                }

                if !c.candidates.isEmpty {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(c.candidates) { item in
                                Button(action: {
                                    if !item.selected {
                                        store.clashSwitchNode(group: c.active_group, node: item.name)
                                    }
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: item.selected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 11))
                                            .foregroundColor(item.selected ? DS.brandGreen : .secondary.opacity(0.6))
                                        Text(item.name)
                                            .font(.system(size: 11.5, weight: item.selected ? .semibold : .regular))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer()
                                        if item.delay_ms > 0 {
                                            Text("\(item.delay_ms)ms")
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundColor(item.delay_ms < 220 ? DS.brandGreen : DS.brandOrange)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(item.selected ? DS.brandGreen.opacity(0.08) : Color.clear))
                                }
                                .buttonStyle(.plain)
                                .disabled(store.isSwitchingClash)
                            }
                        }
                    }
                    .frame(maxHeight: 165)
                }
            } else {
                Text("未检测到本地 Clash Verge 控制通道，仅显示公网出口探测。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - 轻量交接单 Markdown 渲染（零第三方依赖，提升长文档可读性）
struct MarkdownPreviewView: View {
    let markdown: String

    var body: some View {
        let lines = markdown.components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# ") {
                    Text(String(trimmed.dropFirst(2)))
                        .font(.system(size: 15, weight: .bold))
                        .padding(.top, 4)
                } else if trimmed.hasPrefix("## ") {
                    Text(String(trimmed.dropFirst(3)))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DS.brandBlue)
                        .padding(.top, 6)
                } else if trimmed.hasPrefix("### ") {
                    Text(String(trimmed.dropFirst(4)))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.top, 3)
                } else if trimmed == "---" || trimmed == "***" {
                    Divider().padding(.vertical, 3)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundColor(DS.brandBlue).font(.system(size: 12, weight: .bold))
                        Text(String(trimmed.dropFirst(2)))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if trimmed.hasPrefix("> ") {
                    Text(String(trimmed.dropFirst(2)))
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                        .overlay(Rectangle().fill(DS.brandBlue.opacity(0.4)).frame(width: 2), alignment: .leading)
                } else if !trimmed.isEmpty {
                    Text(line)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Spacer().frame(height: 3)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}
