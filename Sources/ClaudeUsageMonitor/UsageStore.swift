import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var usage: UsageSnapshot
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var pausedReason: String?

    private var timer: Timer?
    private var intervalSeconds: Int = 60

    private let usageKey = "UsageStore.cachedUsage.v1"
    private let lastUpdatedKey = "UsageStore.lastUpdated.v1"

    init() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: usageKey),
           let decoded = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
            self.usage = decoded
        } else {
            self.usage = UsageSnapshot()
        }
        self.lastUpdated = ud.object(forKey: lastUpdatedKey) as? Date
    }

    func start(intervalSeconds: Int) {
        self.intervalSeconds = intervalSeconds
        refresh(force: true) // 启动立即拉新数据，不被历史 lastUpdated 的 TTL 挡住
        scheduleTimer()
    }

    func updateInterval(_ seconds: Int) {
        guard seconds != intervalSeconds else { return }
        intervalSeconds = seconds
        scheduleTimer()
    }

    /// TTL 缓存：仅用于 popover 反复开关时的防抖（togglePopover 走 force=false）。
    /// 定时器与启动走 force=true：timer 间隔本身即节流，HTTP 接口便宜(~1s)，不必再被 TTL 挡。
    private let cacheTTL: TimeInterval = 30

    func refresh(force: Bool = false) {
        Task { await reload(force: force) }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        // 定时器间隔本身即节流，强制刷新；否则间隔==TTL 的临界会让定时刷新被吃掉
        let t = Timer(timeInterval: TimeInterval(intervalSeconds), repeats: true) { [weak self] _ in
            self?.refresh(force: true)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func reload(force: Bool) async {
        // TTL 仅用于 popover 反复开关防抖；启动/定时走 force=true 必刷
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

        // 百分比来自 HTTP 接口(~1s)，纯网络、几乎零内存，不扫任何本地会话文件
        let newUsage = await Task.detached { UsageService.fetch() }.value

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
        self.lastUpdated = Date()
        persist()
    }

    private func persist() {
        let ud = UserDefaults.standard
        if let data = try? JSONEncoder().encode(usage) {
            ud.set(data, forKey: usageKey)
        }
        if let t = lastUpdated {
            ud.set(t, forKey: lastUpdatedKey)
        }
    }
}
