import Cocoa
import SwiftUI

// MARK: - 3 层冷灰表面色板与品牌色
enum DS {
    static let canvasBg = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.085, green: 0.095, blue: 0.125, alpha: 1)
            : NSColor(calibratedRed: 0.955, green: 0.965, blue: 0.982, alpha: 1)
    })
    static let cardBg = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.13, green: 0.142, blue: 0.18, alpha: 1)
            : NSColor.white
    })
    static let insetBg = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.145, alpha: 1)
            : NSColor(calibratedRed: 0.968, green: 0.975, blue: 0.988, alpha: 1)
    })
    static let border = Color.primary.opacity(0.08)
    static let brandBlue = Color(red: 0.14, green: 0.45, blue: 0.98)
    static let brandGreen = Color(red: 0.08, green: 0.70, blue: 0.45)
    static let brandOrange = Color(red: 0.94, green: 0.54, blue: 0.10)
    static let brandRed = Color(red: 0.90, green: 0.26, blue: 0.26)
    static let brandPurple = Color(red: 0.49, green: 0.35, blue: 0.90)
    static let brandTeal = Color(red: 0.06, green: 0.63, blue: 0.72)
    static let brandPink = Color(red: 0.86, green: 0.30, blue: 0.56)
}

// MARK: - 外观主题持久化与启动同步
enum ThemeManager {
    static let key = "agy_theme"

    static var currentMode: String {
        UserDefaults.standard.string(forKey: key) ?? "system"
    }

    static func apply(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: key)
        switch mode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    static func applySavedTheme() {
        apply(currentMode)
    }
}

// MARK: - 家庭组视觉映射（A-F 全覆盖 + 动态独享识别）
struct FamilyVisual {
    let groupKey: String      // "家庭组 A" .. "家庭组 F" / "未分组"
    let shortBadge: String    // "A组" .. "F组" / ""
    let letter: String        // "A" .. "F" / ""
    let isManager: Bool
    let isSolo: Bool
    let isFlagged: Bool
    let cleanNote: String
    let tint: Color

    static func color(for letter: String) -> Color {
        switch letter.uppercased() {
        case "A": return DS.brandPurple
        case "B": return DS.brandBlue
        case "C": return DS.brandOrange
        case "D": return DS.brandGreen
        case "E": return DS.brandTeal
        case "F": return DS.brandPink
        default: return .secondary
        }
    }

    static func from(_ acc: AccountInfo) -> FamilyVisual {
        let g = acc.groupLetter
        if !g.isEmpty {
            return FamilyVisual(
                groupKey: "家庭组 \(g)",
                shortBadge: "\(g)组",
                letter: g,
                isManager: acc.isGroupManager,
                isSolo: acc.isSoloGroup,
                isFlagged: acc.isFlagged,
                cleanNote: acc.displayCleanNote,
                tint: color(for: g)
            )
        }
        return FamilyVisual(
            groupKey: "未分组",
            shortBadge: "",
            letter: "",
            isManager: false,
            isSolo: false,
            isFlagged: acc.isFlagged,
            cleanNote: acc.displayCleanNote,
            tint: .secondary
        )
    }

    static func composeNote(group: String, isManager: Bool, isSolo: Bool, isFlagged: Bool, note: String) -> String {
        var body = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSolo && !body.contains("独享") {
            body = body.isEmpty ? "独享 AI Pro" : "独享 · \(body)"
        }
        if isFlagged && !body.contains("⚠️") {
            body = body.isEmpty ? "⚠️待二次验证" : "⚠️ \(body)"
        }
        let g = group.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if g.isEmpty {
            return body
        }
        let role = isManager ? "主" : "子"
        return body.isEmpty ? "[家庭组\(g)-\(role)]" : "[家庭组\(g)-\(role)] \(body)"
    }
}

// MARK: - 通用胶囊按钮样式
struct PrimaryPillButtonStyle: ButtonStyle {
    var compact: Bool = false
    var tint: Color = DS.brandBlue
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .system(size: 11.5, weight: .semibold) : .system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 11 : 16)
            .padding(.vertical, compact ? 5 : 8)
            .background(
                Capsule()
                    .fill(isEnabled ? tint.opacity(configuration.isPressed ? 0.8 : 1.0) : Color.gray.opacity(0.30))
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
                    .fill(DS.cardBg.opacity(configuration.isPressed ? 0.72 : 1.0))
                    .overlay(Capsule().stroke(DS.border, lineWidth: 1))
            )
    }
}
