import Foundation

struct UsageSnapshot: Equatable {
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
        process.arguments = ["-p", "/usage"]
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
        // 输出形如：
        // Current session: 36% used · resets Jun 9 at 7:10pm (Asia/Shanghai)
        // Current week (all models): 48% used · resets Jun 14 at 11pm (Asia/Shanghai)
        // Current week (Sonnet only): 13% used · resets Jun 14 at 11pm (Asia/Shanghai)
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let percent = extractPercent(line) else { continue }
            let reset = extractReset(line)
            if line.contains("Current session") {
                snap.sessionPercent = percent
                snap.sessionResetText = reset
            } else if line.contains("all models") {
                snap.weekAllPercent = percent
                snap.weekAllResetText = reset
            } else if line.contains("Sonnet only") {
                snap.weekSonnetPercent = percent
                snap.weekSonnetResetText = reset
            }
        }
    }

    private static func extractPercent(_ line: String) -> Int? {
        // 匹配 "36%"
        guard let range = line.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
        let s = line[range].dropLast()
        return Int(s)
    }

    private static func extractReset(_ line: String) -> String? {
        guard let r = line.range(of: "resets ") else { return nil }
        return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}
