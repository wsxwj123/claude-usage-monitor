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
        usageStore.$isPaused
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

        struct Cell { let label: String; let percent: Int? }
        var cells: [Cell] = []
        switch s.menubarMetric {
        case .session:
            cells.append(Cell(label: "5h", percent: usageStore.usage.sessionPercent))
        case .weekAll:
            cells.append(Cell(label: "周", percent: usageStore.usage.weekAllPercent))
        case .weekSonnet:
            cells.append(Cell(label: "Son", percent: usageStore.usage.weekSonnetPercent))
        case .all:
            cells.append(Cell(label: "5h", percent: usageStore.usage.sessionPercent))
            cells.append(Cell(label: "周",  percent: usageStore.usage.weekAllPercent))
        }

        button.attributedTitle = NSAttributedString()
        button.title = ""
        button.image = renderTwoLineImage(cells: cells.map { ($0.label, $0.percent) },
                                          dimmed: usageStore.isPaused)
        button.imagePosition = .imageOnly
    }

    /// 两行布局：上行 label 小字灰、下行 percent 大字渐变色。透明背景。
    private func renderTwoLineImage(cells: [(label: String, percent: Int?)], dimmed: Bool) -> NSImage {
        let isDark = isMenubarDark()
        let alpha: CGFloat = dimmed ? 0.55 : 1.0

        let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        let percentFont = NSFont.systemFont(ofSize: 11.5, weight: .bold)

        // 标签灰色，跟随菜单栏外观
        let labelColor: NSColor = (isDark
            ? NSColor.white.withAlphaComponent(0.62 * alpha)
            : NSColor.black.withAlphaComponent(0.55 * alpha))

        let cellGap: CGFloat = 7
        let menubarHeight: CGFloat = 22

        // 测量每个 cell 宽度（取标签和百分比的较大值）
        var cellSizes: [(label: NSSize, percent: NSSize, cellWidth: CGFloat)] = []
        for cell in cells {
            let labelAttr = NSAttributedString(string: cell.label, attributes: [.font: labelFont])
            let percentText = cell.percent.map { "\($0)%" } ?? "--%"
            let percentAttr = NSAttributedString(string: percentText, attributes: [.font: percentFont])
            let lsz = labelAttr.size()
            let psz = percentAttr.size()
            cellSizes.append((lsz, psz, max(lsz.width, psz.width)))
        }
        let totalWidth = cellSizes.reduce(0) { $0 + $1.cellWidth } + cellGap * CGFloat(max(0, cells.count - 1))

        let image = NSImage(size: NSSize(width: max(totalWidth, 1), height: menubarHeight), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, cell) in cells.enumerated() {
                let (lsz, psz, cw) = cellSizes[i]
                let labelAttr = NSAttributedString(string: cell.label, attributes: [
                    .font: labelFont,
                    .foregroundColor: labelColor
                ])
                let percentText = cell.percent.map { "\($0)%" } ?? "--%"
                let percentColor = self.gradientColor(percent: cell.percent, isDark: isDark)
                    .withAlphaComponent(alpha)
                let percentAttr = NSAttributedString(string: percentText, attributes: [
                    .font: percentFont,
                    .foregroundColor: percentColor
                ])

                // 上行 label（居中、底部 y≈12），下行 percent（居中、底部 y≈0）
                let labelX = x + (cw - lsz.width) / 2
                let percentX = x + (cw - psz.width) / 2
                labelAttr.draw(at: NSPoint(x: labelX, y: 12))
                percentAttr.draw(at: NSPoint(x: percentX, y: -1))

                x += cw + cellGap
            }
            return true
        }
        image.isTemplate = false
        return image
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
