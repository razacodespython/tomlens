#!/usr/bin/env swift
// Renders the TomLens app icon into leanring-buddy/Assets.xcassets/AppIcon.appiconset.
// Run from the repo root: swift scripts/render-icon.swift
//
// Matte lime ball, shallow upturned seam, red oval eyes, and thin side
// panels. Same fractions as TomFaceGeometry.
// This file is the generator. Do not hand-edit the PNGs.

import Foundation

struct TomIconColor {
    var r, g, b, a: Double

    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> TomIconColor {
        TomIconColor(r: r, g: g, b: b, a: a)
    }

    func mixed(toward other: TomIconColor, _ t: Double) -> TomIconColor {
        TomIconColor(
            r: r + (other.r - r) * t,
            g: g + (other.g - g) * t,
            b: b + (other.b - b) * t,
            a: a + (other.a - a) * t
        )
    }

    var bytes: (UInt8, UInt8, UInt8, UInt8) {
        func byte(_ value: Double) -> UInt8 {
            UInt8(min(255, max(0, (value * 255).rounded())))
        }
        return (byte(r), byte(g), byte(b), byte(a))
    }
}

struct TomIconPose {
    var tiltDegrees = 0.0
    var eyeOffsetX = 0.0
    var eyeOffsetY = 0.0
    var scaleX = 1.0
    var scaleY = 1.0
    var eyeScaleX = 1.0
    var eyeScaleY = 1.0
    var verticalPoints = 0.0
    var pulseScale = 1.0
    var showsPulse = false
    var earFlapDegrees = 0.0

    static let appIcon = TomIconPose(earFlapDegrees: 0)
}

enum TomIconPixels {
    // Keep these aligned with TomFaceGeometry.
    static let green = TomIconColor.rgb(123.0 / 255.0, 198.0 / 255.0, 45.0 / 255.0)
    static let highlight = TomIconColor.rgb(143.0 / 255.0, 209.0 / 255.0, 58.0 / 255.0)
    static let shade = TomIconColor.rgb(98.0 / 255.0, 158.0 / 255.0, 32.0 / 255.0)
    static let led = TomIconColor.rgb(176.0 / 255.0, 20.0 / 255.0, 30.0 / 255.0)
    static let ledRim = TomIconColor.rgb(122.0 / 255.0, 12.0 / 255.0, 18.0 / 255.0)
    static let ledGlow = TomIconColor.rgb(210.0 / 255.0, 48.0 / 255.0, 56.0 / 255.0)
    static let earLine = TomIconColor.rgb(46.0 / 255.0, 110.0 / 255.0, 24.0 / 255.0)
    static let earInterior = TomIconColor.rgb(138.0 / 255.0, 28.0 / 255.0, 58.0 / 255.0)
    static let seam = TomIconColor.rgb(28.0 / 255.0, 48.0 / 255.0, 18.0 / 255.0)
    static let tile = TomIconColor.rgb(28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0)
    static let eyeCenterYFraction = -0.05
    static let eyeSpacingFraction = 0.26
    static let eyeWidthFraction = 0.04
    static let eyeHeightFraction = 0.075
    static let seamCenterYFraction = 0.05
    static let seamHalfSpanFraction = 0.50
    static let seamDroopFraction = 0.11
    static let seamThicknessFraction = 0.014
    static let sizes = [16, 32, 64, 128, 256, 512, 1024]

    static func render(size: Int, pose: TomIconPose = .appIcon, background: TomIconColor? = nil) -> [UInt8] {
        let samples = 4
        let big = size * samples
        var accum = [UInt32](repeating: 0, count: size * size * 4)
        for y in 0..<big {
            for x in 0..<big {
                let pixel = sample(x: x, y: y, big: big, pose: pose, background: background).bytes
                let dx = x / samples
                let dy = y / samples
                let index = (dy * size + dx) * 4
                accum[index] += UInt32(pixel.0)
                accum[index + 1] += UInt32(pixel.1)
                accum[index + 2] += UInt32(pixel.2)
                accum[index + 3] += UInt32(pixel.3)
            }
        }
        let divisor = UInt32(samples * samples)
        return accum.map { UInt8($0 / divisor) }
    }

    /// Monochrome ball for the menu bar. On is filled with knocked-out eyes.
    /// Off is an outline, filled eyes, and a slash. No side panels: they
    /// do not read at 18 pt.
    static func renderMenuBar(size: Int, isOn: Bool) -> [UInt8] {
        let samples = 4
        let big = size * samples
        var accum = [UInt32](repeating: 0, count: size * size * 4)
        for y in 0..<big {
            for x in 0..<big {
                let pixel = menuBarSample(x: x, y: y, big: big, isOn: isOn).bytes
                let dx = x / samples
                let dy = y / samples
                let index = (dy * size + dx) * 4
                accum[index] += UInt32(pixel.0)
                accum[index + 1] += UInt32(pixel.1)
                accum[index + 2] += UInt32(pixel.2)
                accum[index + 3] += UInt32(pixel.3)
            }
        }
        let divisor = UInt32(samples * samples)
        return accum.map { UInt8($0 / divisor) }
    }

    static func sample(x: Int, y: Int, big: Int, pose: TomIconPose, background: TomIconColor?) -> TomIconColor {
        let n = (Double(x) + 0.5) / Double(big)
        let m = (Double(y) + 0.5) / Double(big)
        let clear = TomIconColor.rgb(0, 0, 0, 0)
        var color = background ?? clear
        if background == nil {
            if !insideRoundedSquare(n, m, radius: 0.223) {
                return clear
            }
            color = tile
            let shadowDistance = hypot(n - 0.50, m - 0.50 - 0.04)
            if shadowDistance < 0.40 {
                let shadeAmount = max(0, 1 - (shadowDistance - 0.32) / 0.08)
                color = color.mixed(toward: TomIconColor.rgb(0, 0, 0), min(0.38, shadeAmount * 0.55))
            }
        }

        let faceDiameter = background == nil ? 0.70 : 0.62
        let centerX = 0.50
        let centerY = 0.50 + (pose.verticalPoints / 30.0) * faceDiameter
        let dx = n - centerX
        let dy = m - centerY
        let radians = -pose.tiltDegrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let rotatedX = dx * cosine - dy * sine
        let rotatedY = dx * sine + dy * cosine
        let sx = rotatedX / max(pose.scaleX, 0.2) / faceDiameter
        let sy = rotatedY / max(pose.scaleY, 0.2) / faceDiameter

        for side in [-1.0, 1.0] {
            if pose.earFlapDegrees >= 8, let panel = openEar(sx, sy, side: side, degrees: pose.earFlapDegrees) {
                color = panel ? earInterior : earLine
            }
        }

        let distance = hypot(sx, sy)
        if distance <= 0.50 {
            color = ballColor(sx: sx, sy: sy)
            if pose.earFlapDegrees < 8 {
                for side in [-1.0, 1.0] where insideClosedEar(sx, sy, side: side) {
                    color = earLine
                }
            }
            let thickness = max(seamThicknessFraction, 2.4 / Double(big) / faceDiameter)
            if onSeam(sx, sy, thickness: thickness) {
                color = seam
            }
            color = paintEye(sx, sy, pose: pose, on: color)
        }
        return color
    }

    static func ballColor(sx: Double, sy: Double) -> TomIconColor {
        let light = max(0, 1 - hypot(sx + 0.16, sy + 0.18) / 0.70)
        let lower = max(0, (sy * 0.65 + sx * 0.35 + 0.08) / 0.55)
        var color = green.mixed(toward: highlight, min(0.85, light * 0.9))
        color = color.mixed(toward: shade, min(0.34, lower * 0.34))
        return color
    }

    static func onSeam(_ sx: Double, _ sy: Double, thickness: Double) -> Bool {
        let t = min(1.05, abs(sx) / 0.50)
        let curveY = seamCenterYFraction + seamDroopFraction * t * t
        if sx * sx + curveY * curveY > 0.252 { return false }
        return abs(sy - curveY) <= thickness / 2
    }

    static func paintEye(_ sx: Double, _ sy: Double, pose: TomIconPose, on color: TomIconColor) -> TomIconColor {
        let halfSpan = (eyeWidthFraction + eyeSpacingFraction) / 2
        var painted = color
        for side in [-1.0, 1.0] {
            let cx = side * halfSpan + pose.eyeOffsetX * 0.06
            let cy = eyeCenterYFraction + pose.eyeOffsetY * 0.06
            let coreW = eyeWidthFraction * pose.eyeScaleX
            let coreH = max(eyeHeightFraction * pose.eyeScaleY, 0.012)
            if pose.showsPulse && insideEllipse(sx, sy, cx: cx, cy: cy, w: coreW * 1.9, h: coreH * 1.55) {
                painted = painted.mixed(toward: ledGlow, 0.45)
            }
            if insideEllipse(sx, sy, cx: cx, cy: cy, w: coreW * 1.28, h: coreH * 1.18) {
                painted = ledRim
            }
            if insideEllipse(sx, sy, cx: cx, cy: cy, w: coreW, h: coreH) {
                painted = led
            }
        }
        return painted
    }

    static func insideClosedEar(_ sx: Double, _ sy: Double, side: Double) -> Bool {
        let start = (side * 0.045, -0.40)
        let control = (side * 0.16, -0.30)
        let end = (side * 0.24, -0.13)
        return distanceToQuad(sx, sy, start: start, control: control, end: end) <= 0.012
    }

    static func distanceToQuad(
        _ x: Double,
        _ y: Double,
        start: (Double, Double),
        control: (Double, Double),
        end: (Double, Double)
    ) -> Double {
        var best = 1.0
        var previous = start
        for step in 1...16 {
            let t = Double(step) / 16.0
            let u = 1 - t
            let px = u * u * start.0 + 2 * u * t * control.0 + t * t * end.0
            let py = u * u * start.1 + 2 * u * t * control.1 + t * t * end.1
            let dx = px - previous.0
            let dy = py - previous.1
            let lengthSquared = dx * dx + dy * dy
            let along = lengthSquared == 0 ? 0 : max(0, min(1, ((x - previous.0) * dx + (y - previous.1) * dy) / lengthSquared))
            let qx = previous.0 + along * dx
            let qy = previous.1 + along * dy
            best = min(best, hypot(x - qx, y - qy))
            previous = (px, py)
        }
        return best
    }

    /// Returns true for the magenta interior, false for the green rim.
    static func openEar(_ sx: Double, _ sy: Double, side: Double, degrees: Double) -> Bool? {
        let hingeX = side * 0.08
        let hingeY = -0.40
        let radians = degrees * .pi / 180
        let dirX = side * sin(radians)
        let dirY = -cos(radians)
        let dx = sx - hingeX
        let dy = sy - hingeY
        let along = dx * dirX + dy * dirY
        let across = dx * (-dirY) + dy * dirX
        let length = 0.58
        let halfWidth = 0.085
        if along < 0 || along > length || abs(across) > halfWidth { return nil }
        let tip = along - (length - halfWidth)
        if tip > 0 && tip * tip + across * across > halfWidth * halfWidth { return nil }
        return abs(across) < halfWidth * 0.62
    }

    static func insideEllipse(_ x: Double, _ y: Double, cx: Double, cy: Double, w: Double, h: Double) -> Bool {
        let nx = (x - cx) / (w / 2)
        let ny = (y - cy) / (h / 2)
        return nx * nx + ny * ny <= 1
    }

    static func insideRoundedSquare(_ x: Double, _ y: Double, radius: Double) -> Bool {
        let dx = max(abs(x - 0.5) - (0.5 - radius), 0)
        let dy = max(abs(y - 0.5) - (0.5 - radius), 0)
        return dx * dx + dy * dy <= radius * radius
    }

    static func insidePill(_ x: Double, _ y: Double, cx: Double, cy: Double, w: Double, h: Double) -> Bool {
        let dx = abs(x - cx)
        let dy = abs(y - cy)
        let radius = min(w, h) / 2
        if dx > w / 2 || dy > h / 2 { return false }
        let px = max(dx - (w / 2 - radius), 0)
        let py = max(dy - (h / 2 - radius), 0)
        return px * px + py * py <= radius * radius
    }

    static func menuBarSample(x: Int, y: Int, big: Int, isOn: Bool) -> TomIconColor {
        let n = (Double(x) + 0.5) / Double(big)
        let m = (Double(y) + 0.5) / Double(big)
        let clear = TomIconColor.rgb(0, 0, 0, 0)
        let black = TomIconColor.rgb(0, 0, 0, 1)
        let diameter = 0.86
        let cx = 0.5
        let cy = 0.5
        let sx = (n - cx) / diameter
        let sy = (m - cy) / diameter
        let distance = hypot(sx, sy)
        let strokeHalf = (1.4 / 2) / (18.0 * 0.86)
        let eye = menuBarEye(sx, sy)
        let seam = menuBarSeam(sx, sy)
        if isOn {
            if distance <= 0.50 {
                return (eye || seam) ? clear : black
            }
            return clear
        }
        let slashInset = 2.0 / 18.0
        let slashHalf = (1.4 / 2) / 18.0
        let slash = abs((n - slashInset) - (m - slashInset)) < slashHalf && n > slashInset && n < 1 - slashInset
        if (eye || seam) && distance < 0.52 {
            return black
        }
        if abs(distance - 0.50) < strokeHalf {
            return black
        }
        if slash {
            return black
        }
        return clear
    }

    static func menuBarEye(_ sx: Double, _ sy: Double) -> Bool {
        let width = 0.07
        let height = 0.12
        for center in [-0.15, 0.15] {
            if insideEllipse(sx, sy, cx: center, cy: -0.05, w: width, h: height) {
                return true
            }
        }
        return false
    }

    static func menuBarSeam(_ sx: Double, _ sy: Double) -> Bool {
        let t = min(1.05, abs(sx) / 0.50)
        let curveY = 0.05 + 0.11 * t * t
        if sx * sx + curveY * curveY > 0.26 { return false }
        return abs(sy - curveY) <= 0.028
    }
}

func crc32(_ data: Data) -> UInt32 {
    var checksum: UInt32 = 0xFFFF_FFFF
    for byte in data {
        checksum ^= UInt32(byte)
        for _ in 0..<8 {
            checksum = (checksum & 1) == 1 ? (checksum >> 1) ^ 0xEDB8_8320 : checksum >> 1
        }
    }
    return ~checksum
}

func zlibStore(_ raw: Data) -> Data {
    var s1: UInt32 = 1
    var s2: UInt32 = 0
    for byte in raw {
        s1 = (s1 + UInt32(byte)) % 65521
        s2 = (s2 + s1) % 65521
    }
    let adler = (s2 << 16) | s1
    var output = Data([0x78, 0x01])
    var offset = 0
    let bytes = [UInt8](raw)
    while offset < bytes.count {
        let length = min(65535, bytes.count - offset)
        let final = offset + length == bytes.count
        output.append(final ? 1 : 0)
        output.append(UInt8(length & 0xFF))
        output.append(UInt8((length >> 8) & 0xFF))
        let nlen = length ^ 0xFFFF
        output.append(UInt8(nlen & 0xFF))
        output.append(UInt8((nlen >> 8) & 0xFF))
        output.append(contentsOf: bytes[offset..<(offset + length)])
        offset += length
    }
    var checksum = adler.bigEndian
    output.append(Data(bytes: &checksum, count: 4))
    return output
}

func pngData(width: Int, height: Int, rgba: [UInt8]) -> Data {
    func chunk(_ tag: String, _ data: Data) -> Data {
        var body = Data(tag.utf8)
        body.append(data)
        var out = Data()
        var length = UInt32(data.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        out.append(body)
        var checksum = crc32(body).bigEndian
        out.append(Data(bytes: &checksum, count: 4))
        return out
    }
    var raw = Data()
    for row in 0..<height {
        raw.append(0)
        let start = row * width * 4
        raw.append(contentsOf: rgba[start..<(start + width * 4)])
    }
    var header = Data()
    var w = UInt32(width).bigEndian
    var h = UInt32(height).bigEndian
    header.append(Data(bytes: &w, count: 4))
    header.append(Data(bytes: &h, count: 4))
    header.append(contentsOf: [8, 6, 0, 0, 0])
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(chunk("IHDR", header))
    png.append(chunk("IDAT", zlibStore(raw)))
    png.append(chunk("IEND", Data()))
    return png
}

#if RENDER_MOTION
do {
    try renderMotionProof()
} catch {
    fputs("motion render failed: \(error)\n", stderr)
    exit(1)
}
#else
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconDirectory = root.appendingPathComponent("leanring-buddy/Assets.xcassets/AppIcon.appiconset")
for size in TomIconPixels.sizes {
    let pixels = TomIconPixels.render(size: size)
    let url = iconDirectory.appendingPathComponent("\(size)-mac.png")
    try pngData(width: size, height: size, rgba: pixels).write(to: url)
    print("wrote \(url.lastPathComponent)")
}
#endif
