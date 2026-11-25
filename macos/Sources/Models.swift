import Cocoa
import SwiftUI

let APP_VERSION = "5.8.0"

enum ToastKind {
    case info, success, warning, error
}

struct AccountInfo: Decodable, Identifiable {
    let id: String
    let label: String
    let email: String?
    let note: String
    let family_group: String?
    let is_manager: Bool?
    let solo_group: Bool?
    let explicit_solo: Bool?
    let flagged: Bool?
    let clean_note: String?
    let recommend_reason: String?
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
    let duplicate_of: String?

    var groupLetter: String { (family_group ?? "").uppercased() }
    var isGroupManager: Bool { is_manager ?? false }
    var isSoloGroup: Bool { solo_group ?? false }
    var isExplicitSolo: Bool { explicit_solo ?? false }
    var isFlagged: Bool { flagged ?? false }
    var displayCleanNote: String { clean_note ?? note }
    var recommendTag: String { recommend_reason ?? "" }
    var displayEmail: String { (email ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var duplicateTarget: String { (duplicate_of ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var shortTitle: String {
        if id == "main" && !displayEmail.isEmpty {
            let prefix = displayEmail.split(separator: "@").first.map(String.init) ?? ""
            if !prefix.isEmpty { return "主账号 · \(prefix)" }
        }
        return label
    }
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

struct SwitchRecord: Decodable, Identifiable {
    var id: String { "\(time)-\(from_id)-\(to_id)" }
    let time: String
    let from_id: String
    let to_id: String
    let from_group: String?
    let to_group: String?
    let cross_group: Bool?
    let reason: String?
}


struct ClashNodeCandidate: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let delay_ms: Int
    let type: String?
    let selected: Bool
}

struct ClashGroupInfo: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let active_node: String
    let delay_ms: Int
    let candidates: [ClashNodeCandidate]
}

struct ClashStatusInfo: Decodable {
    let available: Bool
    let active_group: String
    let active_node: String
    let delay_ms: Int
    let candidates: [ClashNodeCandidate]
    let groups: [ClashGroupInfo]?
}

struct NetworkStatusInfo: Decodable {
    let ok: Bool
    let exit_ip: String
    let country: String
    let region: String
    let org: String
    let latency_ms: Int
    let antigravity_ok: Bool
    let auth_ok: Bool
    let clean_for_antigravity: Bool
    let error_message: String
    let clash: ClashStatusInfo?

    var badgeTitle: String {
        if !clean_for_antigravity {
            return country.isEmpty ? "⚠️ 节点异常" : "⚠️ \(country) 受限"
        }
        let loc = country.isEmpty ? "已连通" : country
        if let c = clash, c.available, !c.active_node.isEmpty {
            return "\(loc) · \(c.active_node)"
        }
        return "\(loc) · \(latency_ms)ms"
    }

    var helpDetail: String {
        if clean_for_antigravity {
            let ipPart = exit_ip.isEmpty ? "IP未知" : exit_ip
            let regPart = region.isEmpty ? (country.isEmpty ? "可用区域" : country) : region
            let nodePart = (clash?.available == true && !(clash?.active_node.isEmpty ?? true)) ? " · 节点: \(clash!.active_node)" : ""
            return "出口: \(ipPart) (\(regPart))\(nodePart) · 点击管理节点"
        }
        return error_message.isEmpty ? "当前节点处于不可用地区或鉴权失败 · 点击切换健康节点" : "\(error_message) · 点击切换健康节点"
    }
}

struct BlockedSwitchAlert: Identifiable {
    let id = UUID()
    let targetId: String
    let message: String
}

struct StatusPayload: Decodable {
    let version: String?
    let relay_prompt: String?
    let workspace: String
    let workspaces: [String]?
    let running_id: String
    let recommended_ids: [String]?
    let accounts: [AccountInfo]
    let sessions: [SessionInfo]
    let warn_5h_limit: Int
    let warn_7d_limit: Int
    let handoff_preview: String
    let handoff_updated: String
    let handoff_history: [HandoffHistItem]?
    let last_switch: String?
    let switch_history: [SwitchRecord]?
    let auto_paste: Bool?
    let tb3_online: Bool?
    let tb3_mount: String?
    let network: NetworkStatusInfo?
    let clash: ClashStatusInfo?
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
