import Foundation

struct AppSettings: Codable, Equatable {
    var refreshIntervalSeconds: Int = 60
    var menubarShowPercent: Bool = true
    var menubarMetric: MenubarMetric = .session
    var showTodayTokens: Bool = true
    var showWeekTokens: Bool = true
    var showCacheHits: Bool = true
    var showSonnetWeek: Bool = true

    enum MenubarMetric: String, Codable, CaseIterable {
        case all, session, weekAll, weekSonnet
        var label: String {
            switch self {
            case .all: return "全部显示（5h + 周）"
            case .session: return "5小时窗口"
            case .weekAll: return "周（全模型）"
            case .weekSonnet: return "周（Sonnet）"
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
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
