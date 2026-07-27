import Foundation

struct AppSettings: Codable, Equatable {
    var refreshIntervalSeconds: Int = 180
    var menubarShowPercent: Bool = true
    var menubarMetric: MenubarMetric = .session
    var showScopedWeek: Bool = true

    enum MenubarMetric: String, Codable, CaseIterable {
        case all, session, weekAll, weekScoped
        var label: String {
            switch self {
            case .all: return "全部显示（5h + 周）"
            case .session: return "5小时窗口"
            case .weekAll: return "周（全模型）"
            case .weekScoped: return "周（单模型）"
            }
        }
    }
}

final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { save() }
    }

    private let key = "AppSettings.v1"

    init() {
        var s: AppSettings
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            s = decoded
        } else {
            s = AppSettings()
        }
        // 迁移：低于 180s 的旧间隔会触发 /api/oauth/usage 激进限流，强制抬到安全线
        if s.refreshIntervalSeconds < 180 { s.refreshIntervalSeconds = 180 }
        self.settings = s
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
