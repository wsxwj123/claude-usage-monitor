#!/usr/bin/env swift
// 生成 AppIcon.png (1024x1024)
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

// 圆角矩形背景：使用类似 macOS Big Sur 圆角比例
let cornerRadius: CGFloat = size * 0.2237
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
ctx.saveGState()
bgPath.addClip()

// 背景渐变：深色基底 → 顶部稍亮（深色模式友好）
let bgGrad = CGGradient(colorsSpace: nil, colors: [
    NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.16, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.24, alpha: 1).cgColor,
] as CFArray, locations: [0.0, 1.0])!
ctx.drawLinearGradient(bgGrad,
    start: CGPoint(x: size / 2, y: 0),
    end: CGPoint(x: size / 2, y: size),
    options: [])
ctx.restoreGState()

// 仪表盘弧：从左下 (210°) 顺时针扫到右下 (-30°)，覆盖 240°
let center = CGPoint(x: size / 2, y: size / 2 + size * 0.04)
let radius = size * 0.32
let lineWidth = size * 0.085
let startAngle: CGFloat = 210 * .pi / 180   // 左下
let endAngle: CGFloat = -30 * .pi / 180     // 右下（顺时针经过顶部）

// 1) 弧底色（暗淡灰）
ctx.saveGState()
ctx.setLineWidth(lineWidth)
ctx.setLineCap(.round)
ctx.setStrokeColor(NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.10).cgColor)
ctx.addArc(center: center, radius: radius,
           startAngle: startAngle, endAngle: endAngle, clockwise: true)
ctx.strokePath()
ctx.restoreGState()

// 2) 弧填充：绿→黄→红 角度渐变，通过分段画弧近似
let segments = 120
let totalSweep = startAngle - endAngle   // 240° = 4π/3
for i in 0..<segments {
    let t0 = CGFloat(i) / CGFloat(segments)
    let t1 = CGFloat(i + 1) / CGFloat(segments)
    let a0 = startAngle - totalSweep * t0
    let a1 = startAngle - totalSweep * t1
    // 颜色按 t 在 hue 120°→0° 之间
    let hue = (120 - 120 * t0) / 360.0
    let color = NSColor(hue: hue, saturation: 0.85, brightness: 0.95, alpha: 1)
    ctx.saveGState()
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.butt)
    ctx.setStrokeColor(color.cgColor)
    ctx.addArc(center: center, radius: radius,
               startAngle: a0, endAngle: a1, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()
}

// 3) 中央百分号
let percentFont = NSFont.systemFont(ofSize: size * 0.30, weight: .heavy)
let percentAttr = NSAttributedString(string: "%", attributes: [
    .font: percentFont,
    .foregroundColor: NSColor.white,
])
let pSize = percentAttr.size()
percentAttr.draw(at: NSPoint(
    x: center.x - pSize.width / 2,
    y: center.y - pSize.height / 2 - size * 0.01
))

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("无法生成 PNG")
}
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")
try png.write(to: out)
print("已生成: \(out.path)")
