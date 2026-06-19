import Foundation

struct UsageSnapshot: Equatable, Codable {
    var sessionPercent: Int?
    var sessionResetText: String?
    var weekAllPercent: Int?
    var weekAllResetText: String?
    var weekSonnetPercent: Int?
    var weekSonnetResetText: String?
    var rawOutput: String = ""
    var fetchedAt: Date = Date()
    var error: String?
    var isRateLimited: Bool = false
}

/// Claude Code 版本号，用于 User-Agent。
/// 缺 `User-Agent: claude-code/<ver>` 会让 /api/oauth/usage 落入激进限流桶 → 持续 429。
/// 与本机 claude 同步即可，前缀 claude-code/ 是关键。
let claudeCodeUA = "claude-code/2.1.179"

enum UsageService {
    /// 官方限额百分比来自 GET https://api.anthropic.com/api/oauth/usage
    /// 之前用的 `claude -p /usage` 在 CLI 2.1+ 既慢(~14s 扫本地 session)又不再返回百分比，已弃用。
    static func fetch() -> UsageSnapshot {
        var snap = UsageSnapshot()

        guard let token = readOAuthToken() else {
            snap.error = "未找到 Claude 登录凭证（请在 Claude Code 中登录）"
            return snap
        }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            snap.error = "URL 构造失败"
            return snap
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(claudeCodeUA, forHTTPHeaderField: "User-Agent") // 关键：避免落入激进限流桶

        let sem = DispatchSemaphore(value: 0)
        var respData: Data?
        var statusCode = 0
        var netErr: Error?
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            respData = data
            statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            netErr = err
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 13) == .timedOut {
            task.cancel()
            snap.error = "用量接口超时（>12s）"
            return snap
        }
        if let netErr = netErr {
            snap.error = "网络错误: \(netErr.localizedDescription)"
            return snap
        }
        guard statusCode == 200, let data = respData else {
            switch statusCode {
            case 401: snap.error = "登录已过期，请在 Claude Code 中重新登录"
            case 429:
                snap.error = "接口限流中，显示上次数据（已自动延长重试）"
                snap.isRateLimited = true
            default:  snap.error = "用量接口 HTTP \(statusCode)"
            }
            return snap
        }

        snap.rawOutput = String(data: data, encoding: .utf8) ?? ""
        parse(data: data, into: &snap)
        if snap.sessionPercent == nil && snap.weekAllPercent == nil && snap.error == nil {
            snap.error = "无法解析用量数据"
        }
        return snap
    }

    private static func parse(data: Data, into snap: inout UsageSnapshot) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let fh = json["five_hour"] as? [String: Any] {
            snap.sessionPercent = roundPercent(fh["utilization"])
            snap.sessionResetText = formatReset(fh["resets_at"] as? String)
        }
        if let sd = json["seven_day"] as? [String: Any] {
            snap.weekAllPercent = roundPercent(sd["utilization"])
            snap.weekAllResetText = formatReset(sd["resets_at"] as? String)
        }
        if let son = json["seven_day_sonnet"] as? [String: Any] {
            snap.weekSonnetPercent = roundPercent(son["utilization"])
            snap.weekSonnetResetText = formatReset(son["resets_at"] as? String)
        }
    }

    private static func roundPercent(_ v: Any?) -> Int? {
        if let d = v as? Double { return Int(d.rounded()) }
        if let i = v as? Int { return i }
        return nil
    }

    /// ISO8601 UTC → "6月17日 13:59"（本地时区，不带前缀，由视图加标签）
    private static func formatReset(_ iso: String?) -> String? {
        guard let iso = iso else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        guard let date = f1.date(from: iso) ?? f2.date(from: iso) else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 HH:mm"
        return df.string(from: date)
    }

    /// 从 macOS 钥匙串读取 Claude Code OAuth token
    private static func readOAuthToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String else { return nil }
            return token
        } catch {
            return nil
        }
    }

    /// 判断当前 Claude 是否走官方订阅（base URL 是 api.anthropic.com 或未设置）
    /// 第三方 provider 时返回 false，调用方跳过刷新、显示上次官方数据
    static func isOfficialProvider() -> Bool {
        let settingsEnv = readClaudeSettingsEnv()
        let envBase = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"]
        let baseUrl = (settingsEnv["ANTHROPIC_BASE_URL"] ?? envBase ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if baseUrl.isEmpty { return true }
        return baseUrl.contains("api.anthropic.com")
    }

    private static func readClaudeSettingsEnv() -> [String: String] {
        let path = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let envBlock = json["env"] as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (k, v) in envBlock {
            result[k] = "\(v)"
        }
        return result
    }
}
