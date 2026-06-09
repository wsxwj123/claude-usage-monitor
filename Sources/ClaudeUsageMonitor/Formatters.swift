import Foundation

enum Fmt {
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.2fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        } else {
            return "\(n)"
        }
    }

    static func percent(_ p: Int?) -> String {
        guard let p else { return "--%" }
        return "\(p)%"
    }

    static func remaining(_ p: Int?) -> String {
        guard let p else { return "--%" }
        return "\(max(0, 100 - p))%"
    }
}
