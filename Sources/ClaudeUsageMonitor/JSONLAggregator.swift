import Foundation

struct TokenTotals: Equatable, Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation: Int = 0
    var cacheRead: Int = 0

    var totalNonCache: Int { input + output }
    var totalWithCache: Int { input + output + cacheCreation + cacheRead }
    var cacheHitRate: Double {
        let denom = cacheRead + cacheCreation
        guard denom > 0 else { return 0 }
        return Double(cacheRead) / Double(denom)
    }
}

struct AggregatedUsage: Equatable, Codable {
    var today: TokenTotals = .init()
    var week: TokenTotals = .init()       // 最近 7 天滚动
    var fetchedAt: Date = Date()
    var scannedEntries: Int = 0
}

enum JSONLAggregator {
    /// 扫描 ~/.claude/projects/**/*.jsonl，聚合今日 + 最近 7 天 token 统计。
    static func aggregate() -> AggregatedUsage {
        var result = AggregatedUsage()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return result
        }

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: now) ?? now

        // 收集每个 (requestId, model) 仅计一次，避免 streaming 重复
        var seenRequestKeys = Set<String>()

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        for projectDir in entries where projectDir.hasDirectoryPath {
            guard let files = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                // 跳过 7 天前都没碰过的文件
                if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   mtime < sevenDaysAgo {
                    continue
                }
                guard let data = try? Data(contentsOf: file),
                      let content = String(data: data, encoding: .utf8) else { continue }
                for line in content.split(separator: "\n") {
                    guard let lineData = line.data(using: .utf8) else { continue }
                    guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                    guard (obj["type"] as? String) == "assistant" else { continue }
                    guard let ts = obj["timestamp"] as? String,
                          let date = isoFormatter.date(from: ts) ?? isoFormatterNoFrac.date(from: ts) else { continue }
                    if date < sevenDaysAgo { continue }
                    guard let msg = obj["message"] as? [String: Any],
                          let usage = msg["usage"] as? [String: Any] else { continue }

                    let model = msg["model"] as? String ?? "unknown"
                    let requestId = (obj["requestId"] as? String) ?? (msg["id"] as? String) ?? (obj["uuid"] as? String ?? "")
                    let key = "\(requestId)::\(model)"
                    if !requestId.isEmpty {
                        if seenRequestKeys.contains(key) { continue }
                        seenRequestKeys.insert(key)
                    }

                    let input = (usage["input_tokens"] as? Int) ?? 0
                    let output = (usage["output_tokens"] as? Int) ?? 0
                    let cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0

                    // 过滤 streaming 占位（usage 全 0 的条目）
                    if input == 0 && output == 0 && cacheCreate == 0 && cacheRead == 0 { continue }

                    result.scannedEntries += 1
                    result.week.input += input
                    result.week.output += output
                    result.week.cacheCreation += cacheCreate
                    result.week.cacheRead += cacheRead

                    if date >= startOfToday {
                        result.today.input += input
                        result.today.output += output
                        result.today.cacheCreation += cacheCreate
                        result.today.cacheRead += cacheRead
                    }
                }
            }
        }

        return result
    }
}
