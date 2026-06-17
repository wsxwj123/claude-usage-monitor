import Foundation

enum Fmt {
    static func percent(_ p: Int?) -> String {
        guard let p else { return "--%" }
        return "\(p)%"
    }

    static func remaining(_ p: Int?) -> String {
        guard let p else { return "--%" }
        return "\(max(0, 100 - p))%"
    }
}
