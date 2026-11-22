import Cocoa

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    exit(1)
}

// 1. macOS 规范圆角矩形底 (留约 10% 边距)
let inset: CGFloat = 96
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = 185
let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

// 深蓝 -> 亮青蓝对角渐变
let colors = [
    NSColor(calibratedRed: 0.06, green: 0.11, blue: 0.25, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.86, alpha: 1.0).cgColor,
    NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.96, alpha: 1.0).cgColor,
] as CFArray
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.55, 1.0])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.minX, y: rect.minY),
    end: CGPoint(x: rect.maxX, y: rect.maxY),
    options: []
)

// 顶部柔和环境光晕
let glowColors = [
    NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.22).cgColor,
    NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0).cgColor,
] as CFArray
let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0])!
ctx.drawRadialGradient(
    glow,
    startCenter: CGPoint(x: size * 0.5, y: size * 0.85),
    startRadius: 20,
    endCenter: CGPoint(x: size * 0.5, y: size * 0.85),
    endRadius: 520,
    options: []
)
ctx.restoreGState()

// 外描边微光
ctx.saveGState()
ctx.addPath(bgPath)
ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.22).cgColor)
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

// 2. 接力双圆弧轨道（象征多账号串行接力）
let center = CGPoint(x: size / 2, y: size / 2)
let orbitR: CGFloat = 250
ctx.saveGState()
ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.32).cgColor)
ctx.setLineWidth(26)
ctx.setLineCap(.round)
ctx.addArc(center: center, radius: orbitR, startAngle: 0.35, endAngle: CGFloat.pi - 0.35, clockwise: false)
ctx.strokePath()
ctx.addArc(center: center, radius: orbitR, startAngle: CGFloat.pi + 0.35, endAngle: CGFloat.pi * 2 - 0.35, clockwise: false)
ctx.strokePath()
ctx.restoreGState()

// 轨道两端接力节点圆点
for angle in [CGFloat(0.35), CGFloat.pi + 0.35] {
    let px = center.x + cos(angle) * orbitR
    let py = center.y + sin(angle) * orbitR
    ctx.saveGState()
    ctx.setFillColor(NSColor(calibratedRed: 0.32, green: 0.95, blue: 0.65, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: CGRect(x: px - 26, y: py - 26, width: 52, height: 52))
    ctx.restoreGState()
}

// 3. 居中锐利闪电图标（AGY Switch 核心视觉）
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: 545, y: 745))
bolt.addLine(to: CGPoint(x: 375, y: 495))
bolt.addLine(to: CGPoint(x: 495, y: 495))
bolt.addLine(to: CGPoint(x: 465, y: 275))
bolt.addLine(to: CGPoint(x: 650, y: 535))
bolt.addLine(to: CGPoint(x: 525, y: 535))
bolt.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0.35).cgColor)
ctx.addPath(bolt)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    exit(2)
}

let outPath = "/Users/tom/Desktop/workspace/agy-switch/macos/icon_1024.png"
try png.write(to: URL(fileURLWithPath: outPath))
print("ICON_OK:", outPath)
