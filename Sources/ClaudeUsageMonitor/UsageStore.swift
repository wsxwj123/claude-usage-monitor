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
    private var intervalSeconds: Int = 180

    // 429 限流退避：连续限流时拉长重试间隔(180→360→720→900s 封顶)，避免死磕延长限流窗口
    private var backoffUntil: Date?
    private var consecutive429 = 0

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

    /// TTL 缓存：popover 反复开关防抖。设 120s(<最小轮询间隔 180s)，
    /// 既不误挡定时刷新，又能抑制频繁开关 popover 时的重复请求。
    private let cacheTTL: TimeInterval = 120

    func refresh(force: Bool = false) {
        Task { await reload(force: force) }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        // 定时器走 force=false：受限流退避节制；TTL(120s)<间隔(≥180s) 保证不被 TTL 误挡
        let t = Timer(timeInterval: TimeInterval(intervalSeconds), repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func reload(force: Bool) async {
        // 非强制(定时器/popover)：TTL 防抖 + 限流退避，任一命中都跳过本次请求(保留上次值)。
        // 手动刷新按钮 force=true 可绕过二者主动试探。
        if !force {
            if let last = lastUpdated, Date().timeIntervalSince(last) < cacheTTL {
                return
            }
            if let until = backoffUntil, Date() < until {
                return
            }
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

        // 限流退避：连续 429 → 180→360→720→900s(封顶15min)；成功则清零
        if newUsage.isRateLimited {
            consecutive429 += 1
            let delay = min(180.0 * pow(2.0, Double(consecutive429 - 1)), 900)
            backoffUntil = Date().addingTimeInterval(delay)
        } else if newUsage.error == nil {
            consecutive429 = 0
            backoffUntil = nil
        }

        // 解析失败/限流时保留上次百分比，避免菜单栏闪回 --%
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
        // 仅成功时推进 lastUpdated：限流/失败不污染"上次成功时间"与 TTL 判定
        if newUsage.error == nil {
            self.lastUpdated = Date()
        }
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
