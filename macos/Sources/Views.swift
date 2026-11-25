import Cocoa
import SwiftUI

// MARK: - 1. 总览页（状态舱 + 工作区快切 + Hero 主卡 + 跨家庭组智能推荐池 + 接力轨迹）
struct DashboardView: View {
    @ObservedObject var store: SwitchStore
    @State private var showCalibrate: Bool = false
    @State private var cal5h: Double = 80
    @State private var cal7d: Double = 95

    var body: some View {
        let accounts = store.status?.accounts ?? []
        let activeAcc = accounts.first(where: { $0.running })
        let activeGroupKey = activeAcc.map { FamilyVisual.from($0).groupKey }
        let readyCount = accounts.filter { $0.logged_in && $0.health != "cooldown" && !$0.isFlagged }.count
        let total7dTurns = accounts.reduce(0) { $0 + $1.turns_7d }
        let recommended = Array(store.recommendedAccounts.prefix(6))
        let topTarget = recommended.first

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 紧凑状态舱 + 首页工作区一键快切
                HStack(spacing: 12) {
                    Label("账号池 \(accounts.count)", systemImage: "person.2")
                    Divider().frame(height: 12)
                    Label("可用 \(readyCount)", systemImage: "checkmark.circle.fill")
                        .foregroundColor(DS.brandGreen)
                    Divider().frame(height: 12)
                    Label("近 7 天 \(total7dTurns) 轮", systemImage: "chart.bar")
                        .foregroundColor(.secondary)

                    if let top = topTarget {
                        Divider().frame(height: 12)
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles").foregroundColor(DS.brandGreen)
                            Text("跨组首选：\(top.label)")
                                .foregroundColor(DS.brandGreen)
                                .fontWeight(.semibold)
                        }
                    }

                    Spacer()

                    // 反重力代理节点哨兵胶囊（点击可立即重测）
                    if let net = store.networkStatus ?? store.status?.network {
                        Button(action: { store.probeNetwork(showFeedback: true) }) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(net.clean_for_antigravity ? DS.brandGreen : DS.brandRed)
                                    .frame(width: 6.5, height: 6.5)
                                Text(store.isProbingNetwork ? "测活中..." : net.badgeTitle)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(net.clean_for_antigravity ? DS.brandGreen : DS.brandRed)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(net.clean_for_antigravity ? DS.brandGreen.opacity(0.1) : DS.brandRed.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help(net.helpDetail)
                    } else {
                        Button(action: { store.probeNetwork(showFeedback: true) }) {
                            Text(store.isProbingNetwork ? "节点测活中..." : "🌐 检测节点")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    // 3TB 中心仓在线感知胶囊
                    let tbOnline = store.status?.tb3_online ?? false
                    HStack(spacing: 4) {
                        Circle()
                            .fill(tbOnline ? DS.brandGreen : Color.secondary.opacity(0.45))
                            .frame(width: 6, height: 6)
                        Text(tbOnline ? "3TB 在线" : "3TB 离线")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(tbOnline ? DS.brandGreen : .secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.04)))
                    .help(tbOnline ? "3TB 知识库母本已挂载，交接单自动原子镜像" : "3TB 未挂载，仅本地保存交接单")

                    Divider().frame(height: 12)

                    let wsList = store.status?.workspaces ?? []
                    let curWs = store.status?.workspace ?? ""
                    if wsList.count > 1 {
                        Menu {
                            ForEach(wsList, id: \.self) { p in
                                Button(action: { store.manageWorkspace("use", path: p) }) {
                                    HStack {
                                        Text(p)
                                        if p == curWs { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                            Divider()
                            Button("在访达中打开当前目录") {
                                if !curWs.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: curWs)) }
                            }
                        } label: {
                            Label(URL(fileURLWithPath: curWs).lastPathComponent, systemImage: "folder.badge.gearshape")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else if !curWs.isEmpty {
                        Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: curWs)) }) {
                            Label(URL(fileURLWithPath: curWs).lastPathComponent, systemImage: "folder")
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("打开工作区：\(curWs)")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.cardBg).shadow(color: .black.opacity(0.03), radius: 4, y: 1))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.border, lineWidth: 1))

                // 低余量预警横幅（仅在用户主动校准了真实余量且低于自定义阈值时触发）
                if let a = activeAcc, a.calibrated, (a.remain_5h_pct <= store.lowQuotaThreshold || a.remain_7d_pct <= store.lowQuotaThreshold) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(DS.brandOrange)
                        Text("当前账号 \(a.label) 校准余量已 ≤ \(store.lowQuotaThreshold)%（5h: \(a.remain_5h_pct)% · 周: \(a.remain_7d_pct)%），建议立即跨家庭组接力。")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("立即跨组接力") { store.switchTo("") }
                            .buttonStyle(PrimaryPillButtonStyle(compact: true, tint: DS.brandOrange))
                            .disabled(store.isBusy)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DS.brandOrange.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.brandOrange.opacity(0.4), lineWidth: 1))
                }

                // Hero 当前运行账号主舱
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Circle().fill(activeAcc != nil ? DS.brandBlue : .gray).frame(width: 9, height: 9)
                                Text(activeAcc?.label ?? "当前无运行实例")
                                    .font(.system(size: 20, weight: .bold))

                                if let a = activeAcc {
                                    let fam = FamilyVisual.from(a)
                                    if !fam.shortBadge.isEmpty {
                                        Text("\(fam.shortBadge) · \(fam.isManager ? "主账号" : "成员")")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(fam.isManager ? .white : fam.tint)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(fam.isManager ? fam.tint : fam.tint.opacity(0.14)))
                                    }
                                    if a.pid > 0 {
                                        Text("PID \(a.pid)")
                                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                                            .foregroundColor(DS.brandBlue)
                                            .padding(.horizontal, 8).padding(.vertical, 2)
                                            .background(Capsule().fill(DS.brandBlue.opacity(0.12)))
                                    }
                                    if a.reset_5h_min > 0 {
                                        Text("\(a.reset_5h_min / 60)h\(a.reset_5h_min % 60)m 后滚动重置")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(DS.brandOrange)
                                            .padding(.horizontal, 8).padding(.vertical, 2)
                                            .background(Capsule().fill(DS.brandOrange.opacity(0.12)))
                                    }
                                }
                            }
                            HStack(spacing: 10) {
                                if let email = activeAcc?.displayEmail, !email.isEmpty {
                                    Label(email, systemImage: "envelope.fill")
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(DS.brandBlue)
                                        .lineLimit(1)
                                }
                                Text("当前接力工作区：\(store.status?.workspace ?? "-")")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            if let a = activeAcc {
                                Button("记录余量") {
                                    cal5h = Double(a.remain_5h_pct)
                                    cal7d = Double(a.remain_7d_pct)
                                    showCalibrate = true
                                }
                                .buttonStyle(SubtlePillButtonStyle())
                                .help("对照客户端右下角真实余量手动记录，用于低余量弹窗提醒")
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
                                Label(
                                    topTarget != nil ? "一键跨组接力 → \(topTarget!.label)" : "一键跨组接力",
                                    systemImage: "bolt.fill"
                                )
                            }
                            .buttonStyle(PrimaryPillButtonStyle(compact: false))
                            .disabled(store.isBusy || recommended.isEmpty)
                        }
                    }

                    if let a = activeAcc {
                        HStack(spacing: 12) {
                            RealUsageMetric(
                                title: "近 5 小时本地对话",
                                valueText: "\(a.turns_5h) 轮",
                                subtext: a.reset_5h_min > 0 ? "\(a.reset_5h_min / 60)h\(a.reset_5h_min % 60)m 后滚动重置" : "空闲状态",
                                accent: a.turns_5h == 0 ? DS.brandGreen : .primary
                            )
                            RealUsageMetric(
                                title: "近 7 天累计对话",
                                valueText: "\(a.turns_7d) 轮",
                                subtext: a.displayCleanNote.isEmpty ? "精确额度见客户端右下角 Usage" : a.displayCleanNote,
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
                        Text("记录真实余量快照：\(activeAcc?.label ?? "")").font(.headline)
                        Text("对照 Antigravity 右下角弹窗里的真实余量记录，低于设置阈值时将主动发出通知。")
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
                            Button("保存") {
                                if let a = activeAcc { store.calibrate(a.id, pct5h: Int(cal5h), pct7d: Int(cal7d)) }
                                showCalibrate = false
                            }
                            .buttonStyle(PrimaryPillButtonStyle(compact: true))
                        }
                    }
                    .padding(20)
                    .frame(width: 380)
                }

                // 跨家庭组智能推荐池
                HStack(alignment: .firstTextBaseline) {
                    Text("跨家庭组推荐接力池")
                        .font(.system(size: 14, weight: .bold))
                    Text("自动避开当前家庭组 · 独享组排第一")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                    Spacer()
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 255, maximum: 350), spacing: 12)], spacing: 12) {
                    ForEach(Array(recommended.enumerated()), id: \.element.id) { idx, acc in
                        CockpitStyleAccountCard(
                            acc: acc,
                            isBusy: store.isBusy,
                            activeGroupKey: activeGroupKey,
                            isTopRecommended: idx == 0,
                            onSwitch: { store.switchTo(acc.id) },
                            onToggleCooldown: { store.setCooldown(acc.id, hours: 5) }
                        )
                    }
                }

                // 最近接力轨迹 + 3 步引导合并底栏
                VStack(alignment: .leading, spacing: 8) {
                    if let hist = store.status?.switch_history, let latest = hist.first {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(DS.brandBlue)
                                .font(.system(size: 11.5))
                            Text("最近接力：\(latest.time)  \(latest.from_id) → \(latest.to_id)")
                                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            if latest.cross_group == true {
                                Text("跨家庭组")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundColor(DS.brandGreen)
                                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                                    .background(Capsule().fill(DS.brandGreen.opacity(0.12)))
                            }
                            Spacer()
                        }
                    }

                    HStack(spacing: 12) {
                        Label("无缝续接 3 步：", systemImage: "lightbulb.fill")
                            .foregroundColor(DS.brandBlue)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("① 点「一键跨组接力」自动生成 HANDOFF_AUTO.md 并安全退旧号")
                        Text("→")
                        Text("② 新号窗口自动拉起并同步历史")
                        Text("→")
                        Text("③ 新对话直接 Cmd+V 发送接力词")
                        Spacer()
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(DS.cardBg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DS.border, lineWidth: 1))
            }
            .padding(20)
        }
        .background(DS.canvasBg)
    }
}

// MARK: - 2. 账号池页（家庭组分区折叠 + 主号强区分 + 结构化分组编辑器）
struct AccountsView: View {
    @ObservedObject var store: SwitchStore
    @State private var filter: String = "all"
    @State private var layoutMode: String = UserDefaults.standard.string(forKey: "agy_layout") ?? "grid"
    @State private var groupByFamily: Bool = UserDefaults.standard.object(forKey: "agy_group_family") == nil ? true : UserDefaults.standard.bool(forKey: "agy_group_family")
    @State private var collapsedGroups: Set<String> = []
    @State private var searchText: String = ""

    @State private var showAddSheet: Bool = false
    @State private var newAccId: String = ""
    @State private var newAccGroup: String = ""
    @State private var newAccIsManager: Bool = false
    @State private var newAccNote: String = ""
    @State private var launchAfterAdd: Bool = false

    @State private var editingNoteAcc: AccountInfo? = nil
    @State private var deletingAcc: AccountInfo? = nil
    @State private var showDeleteConfirm: Bool = false

    private func buildSections(_ list: [AccountInfo]) -> [(key: String, tint: Color, isSoloSection: Bool, items: [AccountInfo])] {
        var bucket: [String: (tint: Color, items: [AccountInfo])] = [:]
        for acc in list {
            let fam = FamilyVisual.from(acc)
            var entry = bucket[fam.groupKey] ?? (tint: fam.tint, items: [])
            entry.items.append(acc)
            bucket[fam.groupKey] = entry
        }
        return bucket.map { (k, v) in
            let sortedItems = v.items.sorted { a, b in
                if a.isGroupManager != b.isGroupManager { return a.isGroupManager }
                if a.logged_in != b.logged_in { return a.logged_in }
                return a.label < b.label
            }
            let isSolo = k != "未分组" && sortedItems.contains(where: { $0.isSoloGroup })
            return (key: k, tint: v.tint, isSoloSection: isSolo, items: sortedItems)
        }.sorted { a, b in
            if a.key == "未分组" { return false }
            if b.key == "未分组" { return true }
            if a.isSoloSection != b.isSoloSection { return a.isSoloSection }
            return a.key < b.key
        }
    }

    @ViewBuilder
    private func renderAccounts(_ items: [AccountInfo], activeGroupKey: String?, topRecId: String?) -> some View {
        if layoutMode == "list" {
            LazyVStack(spacing: 8) {
                ForEach(items) { acc in
                    AccountListRow(
                        acc: acc,
                        isBusy: store.isBusy,
                        onSwitch: { store.switchTo(acc.id) },
                        onToggleCooldown: { store.setCooldown(acc.id, hours: acc.health == "cooldown" ? 0 : 5) },
                        onEditNote: { editingNoteAcc = acc },
                        onDelete: {
                            deletingAcc = acc
                            showDeleteConfirm = true
                        }
                    )
                }
            }
        } else if layoutMode == "compact" {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 185, maximum: 240), spacing: 10)], spacing: 10) {
                ForEach(items) { acc in
                    CompactMiniAccountCard(
                        acc: acc,
                        isBusy: store.isBusy,
                        onSwitch: { store.switchTo(acc.id) },
                        onEditNote: { editingNoteAcc = acc }
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
                        isTopRecommended: acc.id == topRecId,
                        onSwitch: { store.switchTo(acc.id) },
                        onToggleCooldown: { store.setCooldown(acc.id, hours: acc.health == "cooldown" ? 0 : 5) },
                        onEditNote: { editingNoteAcc = acc },
                        onDelete: {
                            deletingAcc = acc
                            showDeleteConfirm = true
                        }
                    )
                }
            }
        }
    }

    var body: some View {
        let all = store.status?.accounts ?? []
        let activeAcc = all.first(where: { $0.running })
        let activeGroupKey = activeAcc.map { FamilyVisual.from($0).groupKey }
        let topRecId = store.topRecommendedAccount?.id
        let filtered = all.filter { acc in
            let matchFilter = (filter == "all")
                || (filter == "ready" && acc.logged_in && acc.health != "cooldown" && !acc.isFlagged)
                || (filter == "cooldown" && acc.health == "cooldown")
                || (filter == "pending" && (!acc.logged_in || acc.isFlagged))
            let q = searchText.trimmingCharacters(in: .whitespaces)
            let matchSearch = q.isEmpty
                || acc.label.localizedCaseInsensitiveContains(q)
                || acc.note.localizedCaseInsensitiveContains(q)
            return matchFilter && matchSearch
        }
        let sections = buildSections(filtered)

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                TextField("搜索账号名或家庭组...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)

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

                Picker("", selection: $layoutMode) {
                    Image(systemName: "square.grid.2x2").tag("grid")
                    Image(systemName: "square.grid.3x3").tag("compact")
                    Image(systemName: "list.bullet").tag("list")
                }
                .pickerStyle(.segmented)
                .frame(width: 98)
                .onChange(of: layoutMode) { _, newVal in
                    UserDefaults.standard.set(newVal, forKey: "agy_layout")
                }

                Picker("", selection: $filter) {
                    Text("全部 (\(all.count))").tag("all")
                    Text("可用 (\(all.filter { $0.logged_in && $0.health != "cooldown" && !$0.isFlagged }.count))").tag("ready")
                    Text("待处理 (\(all.filter { !$0.logged_in || $0.isFlagged }.count))").tag("pending")
                    Text("冷却 (\(all.filter { $0.health == "cooldown" }.count))").tag("cooldown")
                }
                .pickerStyle(.segmented)
                .frame(width: 295)

                Spacer()

                if all.contains(where: { $0.health == "cooldown" }) {
                    Button("解除冷却") { store.clearAllCooldowns() }
                        .buttonStyle(SubtlePillButtonStyle())
                }

                Button(action: { store.refresh(showFeedback: true) }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SubtlePillButtonStyle())

                Button(action: {
                    newAccId = ""
                    newAccGroup = ""
                    newAccIsManager = false
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
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(sections, id: \.key) { sec in
                            let loggedCount = sec.items.filter { $0.logged_in }.count
                            let isCurrentGroup = sec.key != "未分组" && sec.key == activeGroupKey
                            let isCollapsed = collapsedGroups.contains(sec.key)
                            let subtitle = sec.isSoloSection
                                ? "独享 AI Pro · 跨组切号首选"
                                : (isCurrentGroup ? "当前运行所在组 · 切号建议避开" : "已登录 \(loggedCount)/\(sec.items.count)")

                            VStack(alignment: .leading, spacing: 10) {
                                Button(action: {
                                    if isCollapsed { collapsedGroups.remove(sec.key) } else { collapsedGroups.insert(sec.key) }
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.secondary)
                                            .frame(width: 12)
                                        RoundedRectangle(cornerRadius: 2.5)
                                            .fill(sec.tint)
                                            .frame(width: 4, height: 15)
                                        Text(sec.key)
                                            .font(.system(size: 13.5, weight: .bold))
                                            .foregroundColor(.primary)
                                        Text("\(sec.items.count) 个账号")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.primary.opacity(0.05)))
                                        Text(subtitle)
                                            .font(.system(size: 11, weight: (isCurrentGroup || sec.isSoloSection) ? .semibold : .regular))
                                            .foregroundColor(sec.isSoloSection ? DS.brandGreen : (isCurrentGroup ? DS.brandOrange : .secondary))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 2)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if !isCollapsed {
                                    renderAccounts(sec.items, activeGroupKey: activeGroupKey, topRecId: topRecId)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                } else {
                    renderAccounts(filtered, activeGroupKey: activeGroupKey, topRecId: topRecId)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
            }
        }
        .background(DS.canvasBg)
        .sheet(isPresented: $showAddSheet) {
            VStack(alignment: .leading, spacing: 14) {
                Text("添加新的隔离账号").font(.title3.bold())
                Text("自动创建独立 HOME 目录、软链全部共享 Skills 与桌面 .app 启动器，创建后走官方 Google 登录一次即可。")
                    .font(.caption).foregroundColor(.secondary)

                TextField("账号标识（如 11-myaccount）", text: $newAccId).textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 6) {
                    Text("所属 Google 家庭组（可选）").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $newAccGroup) {
                        Text("未分组").tag("")
                        ForEach(["A", "B", "C", "D", "E", "F"], id: \.self) { g in
                            Text("\(g) 组").tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if !newAccGroup.isEmpty {
                    Picker("组内角色", selection: $newAccIsManager) {
                        Text("★ 主账号 (管理员)").tag(true)
                        Text("成员 (子账号)").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                TextField("补充说明（可选，如 绑定邮箱 / 独享）", text: $newAccNote).textFieldStyle(.roundedBorder)
                Toggle("创建后立即切换到此号并打开登录", isOn: $launchAfterAdd).font(.callout)

                HStack {
                    Spacer()
                    Button("取消") { showAddSheet = false }
                    Button("确认创建") {
                        let idClean = newAccId.trimmingCharacters(in: .whitespaces)
                        if !idClean.isEmpty {
                            let composed = FamilyVisual.composeNote(
                                group: newAccGroup,
                                isManager: newAccIsManager,
                                isSolo: false,
                                isFlagged: false,
                                note: newAccNote
                            )
                            store.addAccount(id: idClean, note: composed, launchNow: launchAfterAdd)
                            showAddSheet = false
                        }
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                    .disabled(newAccId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 440)
        }
        .sheet(item: $editingNoteAcc) { acc in
            NoteEditorSheet(
                title: "设置家庭组与备注：\(acc.label)",
                acc: acc,
                onCancel: { editingNoteAcc = nil },
                onSave: { newNote in
                    store.updateNote(acc.id, note: newNote)
                    editingNoteAcc = nil
                }
            )
        }
        .alert("确认删除账号？", isPresented: $showDeleteConfirm, presenting: deletingAcc) { target in
            Button("取消", role: .cancel) { deletingAcc = nil }
            Button("移入废纸篓", role: .destructive) {
                store.deleteAccount(target.id)
                deletingAcc = nil
            }
        } message: { target in
            Text("将把 \(target.label) 的隔离目录和桌面启动器安全移入废纸篓，随时可恢复。")
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
                HStack {
                    Text("跨账号交接单 (HANDOFF_AUTO.md)")
                        .font(.headline)
                    Spacer()
                    Button("复制接力提示词") {
                        let prompt = store.status?.relay_prompt ?? "请先阅读 HANDOFF_AUTO.md，接力继续刚才未完成的工作。"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt, forType: .string)
                        store.showToast("接力提示词已复制到剪贴板")
                    }
                    .buttonStyle(SubtlePillButtonStyle())
                }

                HStack {
                    Picker("来源会话", selection: $selectedPath) {
                        Text("自动选择最近活跃会话").tag("")
                        ForEach(sessions) { s in
                            Text("\(s.account_label) · \(s.time)").tag(s.path)
                        }
                    }
                    .frame(maxWidth: 380)
                    Spacer()
                    Button("生成交接单并复制接力词") {
                        store.saveHandoff(transcript: selectedPath, note: extraNote)
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                    .disabled(store.isBusy)
                }
                TextField("可选：给下一个号的特别交代（例如：先完成 test_server.py 单测，不要改数据库）", text: $extraNote)
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
                .frame(width: 275)
            }
        }
        .padding(20)
        .background(DS.canvasBg)
    }
}

// MARK: - 4. 运行体检页（7 项巡检）
struct DoctorView: View {
    @ObservedObject var store: SwitchStore

    var body: some View {
        let checks = store.doctor?.checks ?? []
        let okCount = checks.filter { $0.status == "ok" }.count

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("本地运行环境体检").font(.title3.bold())
                        if !checks.isEmpty {
                            Text("通过 \(okCount)/\(checks.count)")
                                .font(.caption.bold())
                                .foregroundColor(okCount == checks.count ? DS.brandGreen : DS.brandOrange)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill((okCount == checks.count ? DS.brandGreen : DS.brandOrange).opacity(0.12)))
                        }
                    }
                    Text(store.doctor != nil ? "最近检查：\(store.doctor!.checked_at)" : "点击右侧开始检查")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { store.syncSharedAssets() }) {
                    Label("一键对齐 Skills 与插件", systemImage: "square.stack.3d.up.fill")
                }
                .buttonStyle(SubtlePillButtonStyle())
                .disabled(store.isBusy)
                .help("将主号与全部隔离号的 Skills、官方插件与 Rules 合流到单一主目录并全池软链共享")

                Button("重新体检") { store.runDoctor() }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(checks) { item in
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

// MARK: - 5. 通用设置页（零废弃 API 警告 + 自定义低余量预警阈值）
struct SettingsView: View {
    @ObservedObject var store: SwitchStore
    @State private var workspace: String = ""
    @State private var limit5h: Int = 200
    @State private var limit7d: Int = 1000
    @State private var themeMode: String = ThemeManager.currentMode

    var body: some View {
        Form {
            Section("外观与提醒") {
                Picker("明暗主题", selection: $themeMode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: themeMode) { _, newVal in
                    ThemeManager.apply(newVal)
                }

                Stepper(
                    "校准余量低于 \(store.lowQuotaThreshold)% 时通知提醒",
                    value: Binding(
                        get: { store.lowQuotaThreshold },
                        set: { store.setLowQuotaThreshold($0) }
                    ),
                    in: 5...50,
                    step: 5
                )
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

            Section("本地轮数参考线") {
                Stepper("5 小时窗口参考：\(limit5h) 轮", value: $limit5h, in: 20...500, step: 10)
                Stepper("7 天周参考：\(limit7d) 轮", value: $limit7d, in: 100...3000, step: 50)
            }

            Section("系统集成与自动化") {
                Toggle("登录 macOS 时自动启动 AGY Switch", isOn: Binding(
                    get: { store.autoStartEnabled },
                    set: { store.setAutoStart($0) }
                ))
                Toggle("切号后自动粘贴接力词（仅焦点确为 Antigravity 时触发）", isOn: Binding(
                    get: { store.autoPasteEnabled },
                    set: { store.setAutoPaste($0) }
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

// MARK: - 6. 关于页（统一引用单一真相版本号 APP_VERSION）
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
                            Text("版本 v\(APP_VERSION) · macOS 原生多账号池与跨家庭组智能接力工具")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("检查更新") {
                            if let url = URL(string: "https://github.com/tomyiyi/agy-switch/releases") {
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
                        Label("零第三方依赖 · 仅读本地文件与进程 · 严守 OAuth 安全边界", systemImage: "lock.shield.fill")
                            .font(.caption)
                            .foregroundColor(DS.brandGreen)
                        Spacer()
                        Button("去 GitHub 点 Star ⭐") {
                            if let url = URL(string: "https://github.com/tomyiyi/agy-switch") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(SubtlePillButtonStyle())
                    }
                    .padding(14)
                    .background(DS.brandGreen.opacity(0.07))
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(DS.cardBg).shadow(color: .black.opacity(0.04), radius: 8, y: 2))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(DS.border, lineWidth: 1))
                .frame(maxWidth: 640)
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .background(DS.canvasBg)
    }
}
