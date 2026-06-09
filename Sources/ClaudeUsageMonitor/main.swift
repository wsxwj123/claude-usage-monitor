import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let usageStore = UsageStore()
    private let settingsStore = SettingsStore()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // 不在 Dock 显示

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "CL --%"
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeft
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 460)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(usageStore: usageStore, settingsStore: settingsStore)
        )

        // 监听 usage / settings 变化更新菜单栏标题
        usageStore.$usage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMenuBarTitle() }
            .store(in: &cancellables)
        settingsStore.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                self?.usageStore.updateInterval(settings.refreshIntervalSeconds)
                self?.updateMenuBarTitle()
            }
            .store(in: &cancellables)

        usageStore.start(intervalSeconds: settingsStore.settings.refreshIntervalSeconds)

        // 系统外观切换时刷新菜单栏配色
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func appearanceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateMenuBarTitle()
        }
    }

    private func updateMenuBarTitle() {
        guard let button = statusItem.button else { return }
        let s = settingsStore.settings
        let font = NSFont.menuBarFont(ofSize: 0)
        let isDark = isMenubarDark()

        func seg(_ prefix: String, _ percent: Int?) -> NSAttributedString {
            let text = s.menubarShowPercent ? "\(prefix) \(Fmt.percent(percent))" : prefix
            return NSAttributedString(string: text, attributes: [
                .foregroundColor: gradientColor(percent: percent, isDark: isDark),
                .font: font
            ])
        }
        let sepAttr = NSAttributedString(string: " · ", attributes: [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ])

        let attr = NSMutableAttributedString()
        switch s.menubarMetric {
        case .session:
            attr.append(seg("5h", usageStore.usage.sessionPercent))
        case .weekAll:
            attr.append(seg("周", usageStore.usage.weekAllPercent))
        case .weekSonnet:
            attr.append(seg("Son", usageStore.usage.weekSonnetPercent))
        case .all:
            attr.append(seg("5h", usageStore.usage.sessionPercent))
            attr.append(sepAttr)
            attr.append(seg("周", usageStore.usage.weekAllPercent))
        }
        button.image = nil
        button.title = ""
        button.attributedTitle = attr
    }

    /// 绿(120°)→红(0°) 渐变；自动跟随菜单栏外观调整亮度/饱和度保证对比
    private func gradientColor(percent: Int?, isDark: Bool) -> NSColor {
        guard let raw = percent else {
            return isDark ? .white : .black
        }
        let p = CGFloat(max(0, min(100, raw))) / 100.0
        // ease-in：低 % 保持绿，超过 50% 后快速变红
        let t = pow(p, 0.85)
        let hue: CGFloat = (120 - 120 * t) / 360.0
        // 深色菜单栏：高亮高饱和；浅色：降亮度提对比
        let sat: CGFloat = isDark ? 0.80 : 0.95
        let bri: CGFloat = isDark ? 1.00 : 0.55
        return NSColor(hue: hue, saturation: sat, brightness: bri, alpha: 1.0)
    }

    private func isMenubarDark() -> Bool {
        if let appearance = statusItem.button?.effectiveAppearance {
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            usageStore.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
