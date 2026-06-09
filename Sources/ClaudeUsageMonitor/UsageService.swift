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
        // 确保子进程能找到 node 等依赖
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        process.environment = env

        // cwd 设为家目录，避免 cwd=/ 让 claude 扫到非预期目录
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        // 关闭 stdin，防止 claude 等 tty 输入卡死
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            // 15 秒超时硬保护
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.2)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                snap.error = "claude /usage 超时（>15s）"
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            snap.rawOutput = output
            parse(output: output, into: &snap)
            if process.terminationStatus != 0 && snap.sessionPercent == nil && snap.error == nil {
                snap.error = "claude /usage 退出码 \(process.terminationStatus)"
            }
        } catch {
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
        // 不再用 zsh -lc 兜底（会 source 用户 .zshrc，可能误触发 Music/Photos 等 TCC 权限提示）
        return nil
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
