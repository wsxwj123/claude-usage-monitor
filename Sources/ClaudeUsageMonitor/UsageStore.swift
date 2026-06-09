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

    /// TTL 缓存：60s 内不重复触发 claude CLI（启动昂贵，约 1–3s）
    /// 手动点刷新按钮 force=true 强制绕过
    private let cacheTTL: TimeInterval = 60

    func refresh(force: Bool = false) {
        Task { await reload(force: force) }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        // 定时器走非 force 路径；若距上次刷新不足 TTL 会自动跳过
        let t = Timer(timeInterval: TimeInterval(intervalSeconds), repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func reload(force: Bool) async {
        // TTL 命中：直接返回缓存，不点亮 spinner、不动 claude CLI
        if !force, let last = lastUpdated, Date().timeIntervalSince(last) < cacheTTL {
            return
        }

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

        // 解析失败时保留上次百分比，避免菜单栏闪回 --%
        var merged = newUsage
        if merged.sessionPercent == nil, let last = self.usage.sessionPercent {
            merged.sessionPercent = last
            merged.sessionResetText = self.usage.sessionResetText
        }
        if merged.weekAllPercent == nil, let last = self.usage.weekAllPercent {
            merged.weekAllPercent = last
            merged.weekAllResetText = self.usage.weekAllResetText
        }
        if merged.weekSonnetPercent == nil, let last = self.usage.weekSonnetPercent {
            merged.weekSonnetPercent = last
            merged.weekSonnetResetText = self.usage.weekSonnetResetText
        }
        self.usage = merged
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
