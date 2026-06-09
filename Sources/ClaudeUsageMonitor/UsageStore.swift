import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var usage: UsageSnapshot
    @Published private(set) var tokens: AggregatedUsage
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var pausedReason: String?

    private var timer: Timer?
    private var intervalSeconds: Int = 60

    private let usageKey = "UsageStore.cachedUsage.v1"
    private let tokensKey = "UsageStore.cachedTokens.v1"
    private let lastUpdatedKey = "UsageStore.lastUpdated.v1"

    init() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: usageKey),
           let decoded = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
            self.usage = decoded
        } else {
            self.usage = UsageSnapshot()
        }
        if let data = ud.data(forKey: tokensKey),
           let decoded = try? JSONDecoder().decode(AggregatedUsage.self, from: data) {
            self.tokens = decoded
        } else {
            self.tokens = AggregatedUsage()
        }
        self.lastUpdated = ud.object(forKey: lastUpdatedKey) as? Date
    }

    func start(intervalSeconds: Int) {
        self.intervalSeconds = intervalSeconds
        refresh()
        scheduleTimer()
    }

    func updateInterval(_ seconds: Int) {
        guard seconds != intervalSeconds else { return }
        intervalSeconds = seconds
        scheduleTimer()
    }

    func refresh() {
        Task { await reload() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: TimeInterval(intervalSeconds), repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func reload() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let isOfficial = await Task.detached { UsageService.isOfficialProvider() }.value
        if !isOfficial {
            isPaused = true
            pausedReason = "当前为第三方 provider，已暂停更新；切回 Claude 官方订阅后自动恢复"
            return
        }
        isPaused = false
        pausedReason = nil

        async let u = Task.detached { UsageService.fetch() }.value
        async let t = Task.detached { JSONLAggregator.aggregate() }.value
        let (newUsage, newTokens) = await (u, t)
        self.usage = newUsage
        self.tokens = newTokens
        self.lastUpdated = Date()
        persist()
    }

    private func persist() {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(usage) {
            ud.set(data, forKey: usageKey)
        }
        if let data = try? JSONEncoder().encode(tokens) {
            ud.set(data, forKey: tokensKey)
        }
        if let t = lastUpdated {
            ud.set(t, forKey: lastUpdatedKey)
        }
    }
}
