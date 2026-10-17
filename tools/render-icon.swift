import AppKit
import CoreGraphics
import Foundation

/// 把 designs/xclip-logo/app-icon.svg 的图形渲染成 macOS 图标所需的各尺寸 PNG。
/// 图形是纯几何（两张斜切圆角卡片错位堆叠 + 圆角容器），用 CoreGraphics 直接画，
/// 不依赖任何外部转换工具。母版 SVG 的坐标写死在下面的路径里，改图形请两边同步。
///
/// 用法：swift tools/render-icon.swift [输出目录]
/// 输出：<输出目录>/AppIcon.iconset/icon_*.png（iconutil 直接可用）

let canvas: CGFloat = 1024

// 母版里的三个颜色
let containerColor = NSColor(calibratedRed: 0x15 / 255, green: 0x17 / 255, blue: 0x1F / 255, alpha: 1)
let backCardColor = NSColor(calibratedRed: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255, alpha: 1)
let frontCardColor = NSColor(calibratedRed: 0xF4 / 255, green: 0xF1 / 255, blue: 0xEA / 255, alpha: 1)

/// 一张卡片的路径：圆角矩形，右上角换成斜切（clip 手势）。
/// - Parameters:
///   - x, y: 左上角（1024 画布坐标）
///   - width, height: 尺寸
///   - corner: 圆角半径
///   - chamfer: 右上角斜切的直角边长度
func cardPath(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, corner: CGFloat, chamfer: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: x + corner, y: y))                          // 顶边（左圆角之后）
    path.addLine(to: CGPoint(x: x + width - chamfer, y: y))             // 到斜切起点
    path.addLine(to: CGPoint(x: x + width, y: y + chamfer))             // 斜切
    path.addLine(to: CGPoint(x: x + width, y: y + height - corner))     // 右边到右下圆角
    path.addArc(tangent1End: CGPoint(x: x + width, y: y + height),
                tangent2End: CGPoint(x: x + width - corner, y: y + height),
                radius: corner)                                         // 右下圆角
    path.addLine(to: CGPoint(x: x + corner, y: y + height))             // 底边到左下圆角
    path.addArc(tangent1End: CGPoint(x: x, y: y + height),
                tangent2End: CGPoint(x: x, y: y + height - corner),
                radius: corner)                                         // 左下圆角
    path.addLine(to: CGPoint(x: x, y: y + corner))                      // 左边到左上圆角
    path.addArc(tangent1End: CGPoint(x: x, y: y),
                tangent2End: CGPoint(x: x + corner, y: y),
                radius: corner)                                         // 左上圆角
    path.closeSubpath()
    return path
}

func render(size: CGFloat) -> NSImage? {
    let imageRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: imageRep)
    guard let context = NSGraphicsContext.current?.cgContext else { return nil }

    let scale = size / canvas
    context.scaleBy(x: scale, y: scale)

    // 容器：圆角矩形（macOS 图标网格，r ≈ 21.9%）
    let container = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: canvas, height: canvas),
                                 xRadius: 224, yRadius: 224)
    containerColor.setFill()
    container.fill()

    // 后卡（accent 蓝）向右上偏移 119，只露出右上角一块，形成堆叠感
    backCardColor.setFill()
    context.addPath(cardPath(x: 309, y: 267, width: 526, height: 372, corner: 55, chamfer: 104))
    context.fillPath()

    // 前卡（暖白）
    frontCardColor.setFill()
    context.addPath(cardPath(x: 190, y: 386, width: 526, height: 372, corner: 55, chamfer: 104))
    context.fillPath()

    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(imageRep)
    return image
}

// MARK: - 输出

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("AppIcon.iconset")

let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconutil 需要的命名：基础尺寸 + @2x
let sizes: [(base: Int, name: String)] = [
    (16, "icon_16x16"),
    (32, "icon_32x32"),
    (128, "icon_128x128"),
    (256, "icon_256x256"),
    (512, "icon_512x512")
]

for entry in sizes {
    for multiplier in [1, 2] {
        let pixels = entry.base * multiplier
        let suffix = multiplier == 2 ? "@2x" : ""
        let fileName = "\(entry.name)\(suffix).png"
        guard let image = render(size: CGFloat(pixels)),
              let rep = image.representations.first as? NSBitmapImageRep,
              let data = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write("渲染 \(fileName) 失败\n".data(using: .utf8)!)
            exit(1)
        }
        try data.write(to: iconset.appendingPathComponent(fileName))
    }
}

FileHandle.standardOutput.write("已渲染 \(sizes.count * 2) 个 PNG 到 \(iconset.path)\n".data(using: .utf8)!)
