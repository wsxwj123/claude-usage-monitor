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
}

enum UsageService {
    static func fetch() -> UsageSnapshot {
        var snap = UsageSnapshot()
        let claudePath = locateClaude()
        guard let bin = claudePath else {
            snap.error = "未找到 claude CLI（PATH 中无 claude）"
            return snap
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        // 纯文本模式 CLI 2.1+ 会吞掉 /usage 的百分比明细，只剩订阅提示
        // JSON 模式把完整文本放在 result 字段里，必须用 JSON 解
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "\(NSHomeDirectory())/.local/bin"]
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")

        // 透传 ~/.claude/settings.json 的 env 块（含 ANTHROPIC_BASE_URL/AUTH_TOKEN 等代理配置）
        for (k, v) in readClaudeSettingsEnv() {
            if env[k] == nil { env[k] = v }
        }
        process.environment = env

        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // 异步排空管道，避免 buffer 满导致子进程阻塞，也避免 readDataToEndOfFile 在 SIGKILL 后挂起
        var outData = Data()
        var errData = Data()
        let lock = NSLock()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); outData.append(d); lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            lock.lock(); errData.append(d); lock.unlock()
        }

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGTERM)
                Thread.sleep(forTimeInterval: 0.3)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                Thread.sleep(forTimeInterval: 0.2)
                snap.error = "claude /usage 超时（>15s）"
            }
            // 断开 handler 后管道 readabilityHandler 不再 fire；不再调用 readDataToEndOfFile 避免阻塞
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            lock.lock()
            let output = String(data: outData, encoding: .utf8) ?? ""
            let errOutput = String(data: errData, encoding: .utf8) ?? ""
            lock.unlock()

            // 不管输出是 JSON 包还是纯文本，正则直接扫整段；兼容 \n 字面量和真换行
            snap.rawOutput = output + (errOutput.isEmpty ? "" : "\n[stderr]\n\(errOutput)")
            parse(output: output, into: &snap)

            if snap.sessionPercent == nil && snap.error == nil {
                if process.terminationStatus != 0 {
                    let tail = errOutput.isEmpty ? "" : "：" + String(errOutput.prefix(120))
                    snap.error = "claude 退出码 \(process.terminationStatus)\(tail)"
                } else if output.isEmpty {
                    snap.error = "claude 无输出（PATH 或登录态异常）"
                } else {
                    snap.error = "无法解析 claude 输出"
                }
            }
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            snap.error = "执行 claude 失败: \(error.localizedDescription)"
        }
        return snap
    }

    private static func locateClaude() -> String? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "\(NSHomeDirectory())/.local/bin/claude"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    /// 判断当前 Claude 是否走官方订阅（base URL 是 api.anthropic.com 或未设置）
    /// 第三方 provider 时返回 false，调用方应跳过刷新、显示上次官方数据
    static func isOfficialProvider() -> Bool {
        let settingsEnv = readClaudeSettingsEnv()
        let envBase = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"]
        let baseUrl = (settingsEnv["ANTHROPIC_BASE_URL"] ?? envBase ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if baseUrl.isEmpty { return true }
        // 官方 host 白名单
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

    private static func parse(output: String, into snap: inout UsageSnapshot) {
        // 正则扫整段，兼容三种来源：纯文本、JSON 包（result 字段里的 \n 字面量）、stream-json
        let (sp, sr) = matchSegment(in: output, marker: "Current session")
        snap.sessionPercent = sp; snap.sessionResetText = sr
        let (wp, wr) = matchSegment(in: output, marker: "all models")
        snap.weekAllPercent = wp; snap.weekAllResetText = wr
        let (np, nr) = matchSegment(in: output, marker: "Sonnet only")
        snap.weekSonnetPercent = np; snap.weekSonnetResetText = nr
    }

    /// 匹配 "<marker>...<num>% used · resets <text>"，停在换行 / \\n 字面量 / 引号 / 句末
    private static func matchSegment(in text: String, marker: String) -> (Int?, String?) {
        let escaped = NSRegularExpression.escapedPattern(for: marker)
        let pattern = escaped + #"[^\n\r"]{0,80}?(\d+)%[^\n\r"]*?resets ([^\n\r"\\]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: []),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            // 兜底：只抓百分比，没 reset 文本也行
            let fallback = escaped + #"[^\n\r"]{0,80}?(\d+)%"#
            if let re2 = try? NSRegularExpression(pattern: fallback, options: []),
               let m2 = re2.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let pr = Range(m2.range(at: 1), in: text) {
                return (Int(text[pr]), nil)
            }
            return (nil, nil)
        }
        let percent = Range(m.range(at: 1), in: text).flatMap { Int(text[$0]) }
        let reset = Range(m.range(at: 2), in: text).map { text[$0].trimmingCharacters(in: .whitespaces) }
        return (percent, reset)
    }
}
