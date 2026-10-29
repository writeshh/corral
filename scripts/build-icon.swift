// Builds Resources/AppIcon.icns (light) and Resources/AppIcon-Dark.icns from their SVGs. Run it after you change one:
//   swift scripts/build-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
for name in ["AppIcon", "AppIcon-Dark"] {
    let svg = root.appendingPathComponent("Resources/\(name).svg")
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).iconset")
    guard let image = NSImage(contentsOf: svg) else { fatalError("Cannot read \(svg.path)") }
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(file))
        }
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/\(name).icns").path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
}
