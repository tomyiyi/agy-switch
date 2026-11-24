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
        let badgeText: String = acc.running
            ? "当前运行"
            : (!acc.logged_in ? "待登录" : (acc.health == "cooldown" ? "冷却 \(acc.cooldown_remaining_min)m" : (fam.isFlagged ? "待验证" : "已登录")))
        let sub5h = !acc.logged_in
            ? "需先登录"
            : (acc.reset_5h_min > 0 ? "\(acc.reset_5h_min / 60)h\(acc.reset_5h_min % 60)m 后重置" : "空闲满血")
        let sub7d = !acc.logged_in ? "无本地记录" : "活跃 \(acc.latest_active)"

        VStack(alignment: .leading, spacing: 0) {
            // 主账号专属顶部 3.5px 主题色识别色带
            if fam.isManager {
                LinearGradient(
                    colors: [fam.tint, fam.tint.opacity(0.55)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 3.5)
            }

            VStack(alignment: .leading, spacing: fam.isManager ? 11 : 9) {
                // 顶行：主号大号皇冠圆章 + 15pt Bold，子号 7px 圆点 + 13pt Semibold
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

                    if isTopRecommended {
                        Text("跨组首选")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(DS.brandGreen)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2)
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

                    Text(badgeText)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(badgeColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(badgeColor.opacity(0.13)))
                }

                // 家庭组胶囊行：主号用实心高亮胶囊，子号用轻量描边胶囊
                HStack(spacing: 6) {
                    Button(action: { onEditNote?() }) {
                        HStack(spacing: 6) {
                            if !fam.shortBadge.isEmpty {
                                if fam.isManager {
                                    HStack(spacing: 3) {
                                        Image(systemName: "star.fill").font(.system(size: 8))
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
                                        .foregroundColor(fam.tint.opacity(0.92))
                                        .padding(.horizontal, 6.5)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(fam.tint.opacity(0.08))
                                                .overlay(Capsule().stroke(fam.tint.opacity(0.25), lineWidth: 0.7))
                                        )
                                }

                                if fam.isSolo {
                                    Text("独享")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundColor(DS.brandGreen)
                                        .padding(.horizontal, 5.5)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(DS.brandGreen.opacity(0.12)))
                                }

                                if !fam.cleanNote.isEmpty {
                                    Text(fam.cleanNote)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(fam.isFlagged ? DS.brandOrange : .secondary)
                                        .lineLimit(1)
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
                    Text(fam.cleanNote.isEmpty ? "活跃 \(acc.latest_active)" : fam.cleanNote)
                        .font(.system(size: 10.5))
                        .foregroundColor(fam.isFlagged ? DS.brandOrange : .secondary)
                        .lineLimit(1)
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
