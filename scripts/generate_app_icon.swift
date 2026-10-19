import AppKit
import Foundation

func generateAppIcon(outputPath: String) {
    let width: CGFloat = 1024
    let height: CGFloat = 1024
    let size = NSSize(width: width, height: height)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width),
        pixelsHigh: Int(height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Failed to create NSBitmapImageRep")
    }

    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Failed to create NSGraphicsContext")
    }
    NSGraphicsContext.current = context
    let cgContext = context.cgContext

    // Enable high quality antialiasing
    cgContext.setAllowsAntialiasing(true)
    cgContext.setShouldAntialias(true)
    cgContext.interpolationQuality = CGInterpolationQuality.high

    // 1. App Icon Squircle Dimensions (Standard macOS: 824x824 at 100,100)
    let squircleRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircleRadius: CGFloat = 185.0
    let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: squircleRadius, yRadius: squircleRadius)

    // Squircle drop shadow
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
    shadow.shadowOffset = NSSize(width: 0, height: -22)
    shadow.shadowBlurRadius = 32
    shadow.set()

    // Fill squircle base with dark space-gray gradient
    let baseGradient = NSGradient(
        colors: [
            NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1.0),
            NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        ]
    )!
    baseGradient.draw(in: squirclePath, angle: -90.0)

    // Remove shadow for subsequent drawing
    let noShadow = NSShadow()
    noShadow.set()

    // Inner bevel rim
    cgContext.saveGState()
    squirclePath.addClip()
    let rimPath = NSBezierPath(roundedRect: squircleRect.insetBy(dx: 1.5, dy: 1.5), xRadius: squircleRadius - 1.5, yRadius: squircleRadius - 1.5)
    NSColor(white: 1.0, alpha: 0.12).setStroke()
    rimPath.lineWidth = 2.5
    rimPath.stroke()
    cgContext.restoreGState()

    // Subtle background mesh/radial highlight in top center
    let radialGradient = NSGradient(
        colors: [
            NSColor(red: 0.25, green: 0.30, blue: 0.38, alpha: 0.25),
            NSColor.clear
        ]
    )!
    radialGradient.draw(fromCenter: NSPoint(x: 512, y: 750), radius: 0,
                        toCenter: NSPoint(x: 512, y: 750), radius: 450,
                        options: [.drawsAfterEndingLocation])

    // 2. Aluminum SSD Drive Enclosure
    let driveRect = NSRect(x: 200, y: 260, width: 624, height: 504)
    let driveRadius: CGFloat = 36.0
    let drivePath = NSBezierPath(roundedRect: driveRect, xRadius: driveRadius, yRadius: driveRadius)

    // Drive shadow
    let driveShadow = NSShadow()
    driveShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    driveShadow.shadowOffset = NSSize(width: 0, height: -14)
    driveShadow.shadowBlurRadius = 24
    driveShadow.set()

    let driveGradient = NSGradient(
        colors: [
            NSColor(red: 0.24, green: 0.26, blue: 0.30, alpha: 1.0), // metallic titanium top
            NSColor(red: 0.14, green: 0.15, blue: 0.18, alpha: 1.0)  // deep charcoal bottom
        ]
    )!
    driveGradient.draw(in: drivePath, angle: -90.0)
    noShadow.set()

    // Drive border stroke
    NSColor(red: 0.35, green: 0.38, blue: 0.44, alpha: 0.8).setStroke()
    drivePath.lineWidth = 2.0
    drivePath.stroke()

    // Inner recessed telemetry chamber
    let chamberRect = driveRect.insetBy(dx: 28, dy: 28)
    let chamberRadius: CGFloat = 22.0
    let chamberPath = NSBezierPath(roundedRect: chamberRect, xRadius: chamberRadius, yRadius: chamberRadius)
    let chamberGradient = NSGradient(
        colors: [
            NSColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0),
            NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0)
        ]
    )!
    chamberGradient.draw(in: chamberPath, angle: -90.0)
    NSColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1.0).setStroke()
    chamberPath.lineWidth = 1.5
    chamberPath.stroke()

    // Gold S.M.A.R.T. Interface Pins on the bottom notch
    let pinWidth: CGFloat = 16
    let pinHeight: CGFloat = 22
    let pinSpacing: CGFloat = 24
    let pinStartX: CGFloat = 360
    let pinY: CGFloat = 264
    for i in 0..<13 {
        let pinX = pinStartX + CGFloat(i) * pinSpacing
        let pinRect = NSRect(x: pinX, y: pinY, width: pinWidth, height: pinHeight)
        let pinGradient = NSGradient(
            colors: [
                NSColor(red: 0.95, green: 0.78, blue: 0.25, alpha: 1.0), // Gold highlight
                NSColor(red: 0.72, green: 0.52, blue: 0.12, alpha: 1.0)  // Bronze shadow
            ]
        )!
        pinGradient.draw(in: pinRect, angle: -90.0)
    }

    // Glowing Telemetry Status LED (Emerald Green)
    let ledCenter = NSPoint(x: driveRect.maxX - 62, y: driveRect.maxY - 62)
    let ledRadius: CGFloat = 9.0

    // Radial Glow
    let ledGlow = NSGradient(
        colors: [
            NSColor(red: 0.0, green: 1.0, blue: 0.55, alpha: 0.85),
            NSColor(red: 0.0, green: 0.9, blue: 0.45, alpha: 0.25),
            NSColor.clear
        ]
    )!
    ledGlow.draw(fromCenter: ledCenter, radius: 0, toCenter: ledCenter, radius: 36, options: [.drawsAfterEndingLocation])

    let ledPath = NSBezierPath(ovalIn: NSRect(x: ledCenter.x - ledRadius, y: ledCenter.y - ledRadius, width: ledRadius * 2, height: ledRadius * 2))
    NSColor(red: 0.2, green: 1.0, blue: 0.65, alpha: 1.0).setFill()
    ledPath.fill()

    // Header Labels: "DISK HEALTH" and "NVMe S.M.A.R.T."
    let headerAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 22, weight: .bold),
        .foregroundColor: NSColor(red: 0.78, green: 0.82, blue: 0.88, alpha: 0.9)
    ]
    let headerStr = NSAttributedString(string: "DISK HEALTH", attributes: headerAttrs)
    headerStr.draw(at: NSPoint(x: chamberRect.minX + 24, y: chamberRect.maxY - 46))

    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: NSColor(red: 0.0, green: 0.85, blue: 0.6, alpha: 0.85)
    ]
    let subStr = NSAttributedString(string: "NVMe S.M.A.R.T. TELEMETRY", attributes: subAttrs)
    subStr.draw(at: NSPoint(x: chamberRect.minX + 24, y: chamberRect.maxY - 70))

    // 3. ECG Heartbeat Pulse Line Across Chamber
    cgContext.saveGState()
    chamberPath.addClip()

    // Grid lines inside chamber (subtle telemetry oscilloscope grid)
    NSColor(red: 0.16, green: 0.20, blue: 0.25, alpha: 0.35).setStroke()
    let gridPath = NSBezierPath()
    gridPath.lineWidth = 1.0
    for y in stride(from: chamberRect.minY + 20, to: chamberRect.maxY - 70, by: 32) {
        gridPath.move(to: NSPoint(x: chamberRect.minX, y: y))
        gridPath.line(to: NSPoint(x: chamberRect.maxX, y: y))
    }
    gridPath.stroke()

    // ECG Pulse Waveform
    let ecgPath = NSBezierPath()
    let cy: CGFloat = chamberRect.midY - 14

    ecgPath.move(to: NSPoint(x: chamberRect.minX + 16, y: cy))
    ecgPath.line(to: NSPoint(x: chamberRect.minX + 120, y: cy))
    // Small pre-pulse
    ecgPath.line(to: NSPoint(x: chamberRect.minX + 140, y: cy + 18))
    ecgPath.line(to: NSPoint(x: chamberRect.minX + 160, y: cy))
    ecgPath.line(to: NSPoint(x: chamberRect.minX + 185, y: cy))
    // QRS complex
    ecgPath.line(to: NSPoint(x: chamberRect.minX + 205, y: cy - 28))  // Q dip
    ecgPath.line(to: NSPoint(x: chamberRect.minX + 245, y: cy + 130)) // R peak (high spike)
    ecgPath.line(to: NSPoint(x: chamberRect.minX + 285, y: cy - 65))  // S dip (deep)
    ecgPath.line(to: NSPoint(x: chamberRect.minX + 325, y: cy + 32))  // T wave
    ecgPath.line(to: NSPoint(x: chamberRect.minX + 365, y: cy))
    ecgPath.line(to: NSPoint(x: chamberRect.maxX - 16, y: cy))

    // Pulse glow layer
    let pulseGlow = NSShadow()
    pulseGlow.shadowColor = NSColor(red: 0.0, green: 0.95, blue: 0.70, alpha: 0.85)
    pulseGlow.shadowOffset = .zero
    pulseGlow.shadowBlurRadius = 14
    pulseGlow.set()

    NSColor(red: 0.0, green: 1.0, blue: 0.75, alpha: 0.95).setStroke()
    ecgPath.lineWidth = 7.0
    ecgPath.lineCapStyle = .round
    ecgPath.lineJoinStyle = .round
    ecgPath.stroke()

    // Sharp bright core
    noShadow.set()
    NSColor(red: 0.85, green: 1.0, blue: 0.95, alpha: 1.0).setStroke()
    ecgPath.lineWidth = 2.5
    ecgPath.stroke()

    // Peak Pulse Indicator Dot at R peak
    let peakDotCenter = NSPoint(x: chamberRect.minX + 245, y: cy + 130)
    let dotGlow = NSShadow()
    dotGlow.shadowColor = NSColor(red: 0.1, green: 1.0, blue: 0.8, alpha: 0.9)
    dotGlow.shadowOffset = .zero
    dotGlow.shadowBlurRadius = 18
    dotGlow.set()

    let dotPath = NSBezierPath(ovalIn: NSRect(x: peakDotCenter.x - 7, y: peakDotCenter.y - 7, width: 14, height: 14))
    NSColor.white.setFill()
    dotPath.fill()
    noShadow.set()

    cgContext.restoreGState()

    // Flush and write PNG
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to convert image to PNG")
    }

    let url = URL(fileURLWithPath: outputPath)
    do {
        try pngData.write(to: url)
        print("Generated app icon: \(outputPath)")
    } catch {
        fatalError("Error saving image: \(error.localizedDescription)")
    }
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/AppIcon.png"
generateAppIcon(outputPath: output)
