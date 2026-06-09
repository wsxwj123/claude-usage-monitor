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

        struct Seg { let text: String; let color: NSColor }
        var segs: [Seg] = []
        switch s.menubarMetric {
        case .session:
            segs.append(Seg(text: segText("5h", usageStore.usage.sessionPercent),
                            color: pillColor(palette: .session, percent: usageStore.usage.sessionPercent)))
        case .weekAll:
            segs.append(Seg(text: segText("周", usageStore.usage.weekAllPercent),
                            color: pillColor(palette: .week, percent: usageStore.usage.weekAllPercent)))
        case .weekSonnet:
            segs.append(Seg(text: segText("Son", usageStore.usage.weekSonnetPercent),
                            color: pillColor(palette: .week, percent: usageStore.usage.weekSonnetPercent)))
        case .all:
            segs.append(Seg(text: segText("5h", usageStore.usage.sessionPercent),
                            color: pillColor(palette: .session, percent: usageStore.usage.sessionPercent)))
            segs.append(Seg(text: segText("周", usageStore.usage.weekAllPercent),
                            color: pillColor(palette: .week, percent: usageStore.usage.weekAllPercent)))
        }

        button.title = ""
        button.attributedTitle = NSAttributedString()
        button.image = renderPillImage(segments: segs.map { ($0.text, $0.color) })
        button.imagePosition = .imageOnly
    }

    private func segText(_ prefix: String, _ percent: Int?) -> String {
        if settingsStore.settings.menubarShowPercent {
            return "\(prefix) \(Fmt.percent(percent))"
        }
        return prefix
    }

    private enum ColorPalette {
        case session  // 5h：青→红
        case week     // 周  ：紫→橙红
        var hueStart: CGFloat { self == .session ? 200 : 280 }
        var hueEnd: CGFloat   { self == .session ? 0   : 20  }
    }

    /// 高饱和填充色，作为药丸底色；白字在上面任何壁纸下都清晰
    private func pillColor(palette: ColorPalette, percent: Int?) -> NSColor {
        guard let raw = percent else {
            return NSColor.systemGray
        }
        let p = CGFloat(max(0, min(100, raw))) / 100.0
        // ease-in 曲线，20/50/80 后告警感更强
        let t = pow(p, 0.75)
        var start = palette.hueStart
        var end = palette.hueEnd
        if abs(end - start) > 180 {
            if start < end { start += 360 } else { end += 360 }
        }
        var hue = start + (end - start) * t
        hue = hue.truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        return NSColor(hue: hue / 360.0, saturation: 0.85, brightness: 0.85, alpha: 1.0)
    }

    /// 把若干段文字渲染成「圆角药丸 + 白字」的复合图，确保任何壁纸/菜单栏背景下都清晰
    private func renderPillImage(segments: [(text: String, color: NSColor)]) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let padH: CGFloat = 5
        let padV: CGFloat = 1
        let gap: CGFloat = 3
        let cornerRadius: CGFloat = 4
        let menubarHeight: CGFloat = 18

        let sizes = segments.map { NSAttributedString(string: $0.text, attributes: textAttrs).size() }
        let totalWidth = sizes.reduce(0) { $0 + $1.width + padH * 2 } + gap * CGFloat(max(0, segments.count - 1))
        let totalHeight = menubarHeight

        let image = NSImage(size: NSSize(width: max(totalWidth, 1), height: totalHeight), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, seg) in segments.enumerated() {
                let textSize = sizes[i]
                let segWidth = textSize.width + padH * 2
                let segHeight = textSize.height + padV * 2
                let segY = (totalHeight - segHeight) / 2
                let rect = NSRect(x: x, y: segY, width: segWidth, height: segHeight)
                seg.color.setFill()
                let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
                path.fill()
                let attr = NSAttributedString(string: seg.text, attributes: textAttrs)
                attr.draw(at: NSPoint(x: x + padH, y: segY + padV))
                x += segWidth + gap
            }
            return true
        }
        image.isTemplate = false  // 保持彩色，不被系统按 template 染色
        return image
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
