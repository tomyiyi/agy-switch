import Cocoa
import SwiftUI

final class SwitchStore: ObservableObject {
    @Published var status: StatusPayload?
    @Published var doctor: DoctorPayload?
    @Published var toast: String = ""
    @Published var isBusy: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var autoStartEnabled: Bool = false
    @Published var lowQuotaThreshold: Int = UserDefaults.standard.object(forKey: "agy_low_threshold") == nil ? 15 : UserDefaults.standard.integer(forKey: "agy_low_threshold")

    private let cliQueue = DispatchQueue(label: "io.agyswitch.cli.serial", qos: .userInitiated)
    private var lastAlertedAccount: String = ""
    private var lastAlertTime: Date = .distantPast
    private var pollTimer: Timer?

    private var pythonPath: String {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") ? "/usr/bin/python3" : "/usr/bin/env"
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

    func setLowQuotaThreshold(_ val: Int) {
        let clamped = max(5, min(50, val))
        lowQuotaThreshold = clamped
        UserDefaults.standard.set(clamped, forKey: "agy_low_threshold")
    }

    private func sanitizeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func sendSafeNotification(message: String, title: String) {
        let safeMsg = sanitizeAppleScript(message)
        let safeTitle = sanitizeAppleScript(title)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "display notification \"\(safeMsg)\" with title \"\(safeTitle)\""]
        try? proc.run()
    }

    private func checkLowQuotaNotification(_ decoded: StatusPayload) {
        guard let active = decoded.accounts.first(where: { $0.running }), active.calibrated else { return }
        let threshold = lowQuotaThreshold
        let low = active.remain_5h_pct <= threshold || active.remain_7d_pct <= threshold
        guard low else { return }
        let now = Date()
        if lastAlertedAccount == active.id && now.timeIntervalSince(lastAlertTime) < 1800 {
            return
        }
        lastAlertedAccount = active.id
        lastAlertTime = now
        let pct = min(active.remain_5h_pct, active.remain_7d_pct)
        sendSafeNotification(
            message: "当前账号 \(active.label) 校准余量仅剩 \(pct)%（≤\(threshold)%），建议一键跨家庭组接力！",
            title: "AGY Switch · 低余量预警"
        )
    }

    private func runCLISync(_ args: [String]) -> (data: Data?, exitCode: Int32) {
        let proc = Process()
        let py = pythonPath
        if py == "/usr/bin/env" {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", scriptPath] + args
        } else {
            proc.executableURL = URL(fileURLWithPath: py)
            proc.arguments = [scriptPath] + args
        }
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (data, proc.terminationStatus)
        } catch {
            return (nil, -1)
        }
    }

    /// 统一校验退出码与 JSON {"error": ...}，杜绝写操作静默吞错假报成功
    private func runMutation(_ args: [String], successToast: String, onSuccess: (([String: Any]) -> Void)? = nil) {
        cliQueue.async { [weak self] in
            guard let self = self else { return }
            let res = self.runCLISync(args)
            guard res.exitCode == 0,
                  let data = res.data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.showToast("操作失败：后端执行异常 (code \(res.exitCode))")
                }
                return
            }
            if let err = obj["error"] as? String, !err.isEmpty {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.showToast("失败：\(err)")
                }
                return
            }
            DispatchQueue.main.async {
                self.isBusy = false
                self.showToast(successToast)
                onSuccess?(obj)
                self.refresh()
            }
        }
    }

    func showToast(_ msg: String) {
        DispatchQueue.main.async { self.toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            if self.toast == msg { self.toast = "" }
        }
    }

    func runDoctor() {
        cliQueue.async { [weak self] in
            guard let self = self else { return }
            let res = self.runCLISync(["--cli-doctor"])
            guard res.exitCode == 0,
                  let data = res.data,
                  let decoded = try? JSONDecoder().decode(DoctorPayload.self, from: data) else {
                DispatchQueue.main.async { self.showToast("体检读取失败") }
                return
            }
            DispatchQueue.main.async { self.doctor = decoded }
        }
    }

    func refresh(showFeedback: Bool = false) {
        DispatchQueue.main.async { self.isRefreshing = true }
        cliQueue.async { [weak self] in
            guard let self = self else { return }
            let res = self.runCLISync(["--cli-status"])
            guard res.exitCode == 0,
                  let data = res.data,
                  let decoded = try? JSONDecoder().decode(StatusPayload.self, from: data) else {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    if showFeedback { self.showToast("刷新失败，请检查本地运行环境") }
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
                    self.showToast("已刷新（\(nowStr)）· 当前：\(decoded.running_id.isEmpty ? "未运行" : decoded.running_id)")
                }
            }
        }
    }

    func calibrate(_ accId: String, pct5h: Int, pct7d: Int) {
        runMutation(["--cli-calibrate", accId, "\(pct5h)", "\(pct7d)"], successToast: "已记录 \(accId) 余量校准 · 5h \(pct5h)% / 周 \(pct7d)%")
    }

    func fetchAutoStart() {
        cliQueue.async { [weak self] in
            guard let self = self else { return }
            let res = self.runCLISync(["--cli-autostart", "status"])
            guard res.exitCode == 0,
                  let data = res.data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let en = obj["enabled"] as? Bool else { return }
            DispatchQueue.main.async { self.autoStartEnabled = en }
        }
    }

    func setAutoStart(_ enabled: Bool) {
        runMutation(
            ["--cli-autostart", enabled ? "on" : "off"],
            successToast: enabled ? "已开启登录 macOS 自动启动" : "已关闭开机自动启动"
        ) { [weak self] _ in
            self?.autoStartEnabled = enabled
        }
    }

    func saveHandoff(transcript: String, note: String) {
        DispatchQueue.main.async { self.isBusy = true }
        runMutation(["--cli-handoff-save", transcript, note], successToast: "已生成 HANDOFF_AUTO.md，接力词已写入剪贴板")
    }

    func saveConfig(workspace: String, limit5h: Int, limit7d: Int) {
        runMutation(["--cli-config", workspace, "\(limit5h)", "\(limit7d)"], successToast: "设置已保存")
    }

    func switchTo(_ targetId: String) {
        guard !isBusy else { return }
        DispatchQueue.main.async {
            self.isBusy = true
            self.showToast(targetId.isEmpty ? "正在保存交接单并跨家庭组挑选最优满血号..." : "正在优雅退旧号并切换到 \(targetId)...")
        }
        cliQueue.async { [weak self] in
            guard let self = self else { return }
            let res = self.runCLISync(["--cli-switch", targetId])
            guard res.exitCode == 0,
                  let data = res.data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.showToast("切换失败：后端异常退出")
                }
                return
            }
            if let err = obj["error"] as? String, !err.isEmpty {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.showToast("切换未执行：\(err)")
                }
                return
            }
            let switchedLabel = (obj["switched_to"] as? String) ?? targetId
            DispatchQueue.main.async {
                self.isBusy = false
                self.showToast("已切至 \(switchedLabel) · 新窗口直接 Cmd+V 继续")
                self.refresh()
            }
        }
    }

    func setCooldown(_ accId: String, hours: Int) {
        runMutation(
            ["--cli-cooldown", accId, "\(hours)"],
            successToast: hours > 0 ? "已标记 \(accId) 冷却 \(hours) 小时" : "已恢复 \(accId) 为可用"
        )
    }

    func clearAllCooldowns() {
        runMutation(["--cli-clear-cooldowns"], successToast: "已一键解除全部账号冷却")
    }

    func addAccount(id: String, note: String, launchNow: Bool) {
        DispatchQueue.main.async { self.isBusy = true }
        runMutation(["--cli-add", id, note], successToast: "已创建隔离账号 \(id)") { [weak self] _ in
            if launchNow { self?.switchTo(id) }
        }
    }

    func deleteAccount(_ accId: String) {
        runMutation(["--cli-delete", accId], successToast: "已将 \(accId) 安全移入废纸篓")
    }

    func updateNote(_ accId: String, note: String) {
        runMutation(["--cli-note", accId, note], successToast: "已更新 \(accId) 分组与备注")
    }

    func restoreHandoff(_ filename: String) {
        runMutation(["--cli-restore-handoff", filename], successToast: "已恢复 \(filename) 为当前交接单，接力词已复制")
    }

    func manageWorkspace(_ action: String, path: String) {
        let msg = action == "remove" ? "已移除工作区" : "已切换接力工作区：\(URL(fileURLWithPath: path).lastPathComponent)"
        runMutation(["--cli-workspaces", action, path], successToast: msg)
    }

    var topRecommendedAccount: AccountInfo? {
        guard let s = status else { return nil }
        if let topId = s.recommended_ids?.first {
            return s.accounts.first(where: { $0.id == topId })
        }
        return s.accounts.first(where: { $0.logged_in && !$0.running && $0.health != "cooldown" && !$0.isFlagged })
    }

    var recommendedAccounts: [AccountInfo] {
        guard let s = status else { return [] }
        if let ids = s.recommended_ids, !ids.isEmpty {
            let map = Dictionary(uniqueKeysWithValues: s.accounts.map { ($0.id, $0) })
            return ids.compactMap { map[$0] }
        }
        return s.accounts.filter { $0.logged_in && !$0.running && $0.health != "cooldown" && $0.app_exists && !$0.isFlagged }
    }
}
