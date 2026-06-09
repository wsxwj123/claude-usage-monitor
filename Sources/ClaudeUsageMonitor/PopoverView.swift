import SwiftUI

struct PopoverView: View {
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var settingsStore: SettingsStore
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if usageStore.isPaused {
                pausedBanner
            }
            Divider()
            percentSection
            Divider()
            tokenSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .sheet(isPresented: $showSettings) {
            SettingsView(settingsStore: settingsStore)
        }
    }

    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").foregroundColor(.orange)
            Text(usageStore.pausedReason ?? "已暂停更新")
                .font(.caption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Claude Usage")
                .font(.headline)
            Spacer()
            Button(action: { usageStore.refresh() }) {
                ZStack {
                    if usageStore.isRefreshing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("立即刷新")

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("设置")

            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("退出")
        }
    }

    private var percentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                percentColumn(title: "5h",
                              percent: usageStore.usage.sessionPercent,
                              reset: usageStore.usage.sessionResetText,
                              color: tintForPercent(usageStore.usage.sessionPercent))
                Divider().frame(height: 80)
                percentColumn(title: "周",
                              percent: usageStore.usage.weekAllPercent,
                              reset: usageStore.usage.weekAllResetText,
                              color: tintForPercent(usageStore.usage.weekAllPercent))
            }
            if settingsStore.settings.showSonnetWeek {
                HStack {
                    Text("Sonnet 本周").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text(Fmt.percent(usageStore.usage.weekSonnetPercent))
                        .font(.caption).bold()
                    if let r = usageStore.usage.weekSonnetResetText {
                        Text("· 重置 \(r)").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            if let err = usageStore.usage.error {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func percentColumn(title: String, percent: Int?, reset: String?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(percent ?? 0)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(color)
            }
            Text("剩余 \(Fmt.remaining(percent))")
                .font(.caption2)
                .foregroundColor(.secondary)
            ProgressView(value: Double(percent ?? 0) / 100.0)
                .progressViewStyle(.linear)
                .tint(color)
            if let reset {
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tintForPercent(_ percent: Int?) -> Color {
        guard let raw = percent else { return .gray }
        let p = Double(max(0, min(100, raw))) / 100.0
        let t = pow(p, 0.85)
        // 绿(120°) → 红(0°)
        let hue = (120 - 120 * t) / 360.0
        return Color(hue: hue, saturation: 0.80, brightness: 0.85)
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if settingsStore.settings.showTodayTokens {
                tokenRow(title: "今日", totals: usageStore.tokens.today)
            }
            if settingsStore.settings.showWeekTokens {
                tokenRow(title: "近 7 天", totals: usageStore.tokens.week)
            }
        }
    }

    private func tokenRow(title: String, totals: TokenTotals) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline).bold()
                Spacer()
                Text("总计 \(Fmt.tokens(totals.totalWithCache))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                stat("输入", totals.input)
                stat("输出", totals.output)
                if settingsStore.settings.showCacheHits {
                    stat("缓存命中", totals.cacheRead)
                    stat("缓存写入", totals.cacheCreation)
                }
            }
            if settingsStore.settings.showCacheHits && (totals.cacheRead + totals.cacheCreation) > 0 {
                Text(String(format: "缓存命中率 %.0f%%", totals.cacheHitRate * 100))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(Fmt.tokens(value)).font(.caption).monospacedDigit()
        }
    }

    private var footer: some View {
        HStack {
            if let t = usageStore.lastUpdated {
                Text("更新于 \(t.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("扫描 \(usageStore.tokens.scannedEntries) 条")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置").font(.headline)

            Picker("菜单栏显示", selection: $settingsStore.settings.menubarMetric) {
                ForEach(AppSettings.MenubarMetric.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
            Toggle("菜单栏显示百分比数字", isOn: $settingsStore.settings.menubarShowPercent)

            Divider()

            Toggle("显示今日 token", isOn: $settingsStore.settings.showTodayTokens)
            Toggle("显示近 7 天 token", isOn: $settingsStore.settings.showWeekTokens)
            Toggle("显示缓存命中明细", isOn: $settingsStore.settings.showCacheHits)
            Toggle("显示本周 Sonnet 单独占比", isOn: $settingsStore.settings.showSonnetWeek)

            Divider()

            Toggle("开机自动启动", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    let ok = LaunchAtLogin.setEnabled(newValue)
                    if !ok {
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                }

            HStack {
                Text("刷新间隔")
                Spacer()
                Picker("", selection: $settingsStore.settings.refreshIntervalSeconds) {
                    Text("30 秒").tag(30)
                    Text("1 分钟").tag(60)
                    Text("2 分钟").tag(120)
                    Text("5 分钟").tag(300)
                }
                .labelsHidden()
                .frame(width: 120)
            }

            Spacer()

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360, height: 400)
    }
}
