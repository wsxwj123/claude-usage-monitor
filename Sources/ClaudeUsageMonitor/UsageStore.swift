import Foundation
import Combine

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var usage: UsageSnapshot = .init()
    @Published private(set) var tokens: AggregatedUsage = .init()
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastUpdated: Date?

    private var timer: Timer?
    private var intervalSeconds: Int = 60

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
        Task {
            await reload()
        }
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
        async let u = Task.detached { UsageService.fetch() }.value
        async let t = Task.detached { JSONLAggregator.aggregate() }.value
        let (newUsage, newTokens) = await (u, t)
        self.usage = newUsage
        self.tokens = newTokens
        self.lastUpdated = Date()
    }
}
