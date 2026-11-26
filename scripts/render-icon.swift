#!/usr/bin/env swift
// Renders Tom's face into leanring-buddy/Assets.xcassets/AppIcon.appiconset.
// Run from the repo root: swift scripts/render-icon.swift
//
// The face matches TomFaceGeometry: a flat #5AC078 circle, two near-black
// vertical pills slightly below center, on a #1C1C1E rounded-square tile.
// This file is the generator. Do not hand-edit the PNGs.

import Foundation

enum TomIconPixels {
    static let green = (UInt8(90), UInt8(192), UInt8(120), UInt8(255))
    static let eye = (UInt8(14), UInt8(14), UInt8(14), UInt8(255))
    static let tile = (UInt8(28), UInt8(28), UInt8(30), UInt8(255))
    static let sizes = [16, 32, 64, 128, 256, 512, 1024]

    static func render(size: Int) -> [UInt8] {
        let samples = 4
        let big = size * samples
        var accum = [UInt32](repeating: 0, count: size * size * 4)
        for y in 0..<big {
            for x in 0..<big {
                let pixel = sample(x: x, y: y, big: big)
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

    static func sample(x: Int, y: Int, big: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let n = (Double(x) + 0.5) / Double(big)
        let m = (Double(y) + 0.5) / Double(big)
        let radius = 0.223
        if !insideRoundedSquare(n, m, radius: radius) {
            return (0, 0, 0, 0)
        }
        let faceCenter = 0.50
        let faceRadius = 0.30
        let shadowDy = 0.035
        let shadowDistance = hypot(n - faceCenter, m - faceCenter - shadowDy)
        var red = tile.0
        var greenChannel = tile.1
        var blue = tile.2
        if shadowDistance < faceRadius + 0.04 && shadowDistance > faceRadius {
            let shade = min(1, max(0, 1 - (shadowDistance - faceRadius) / 0.04))
            red = UInt8(Double(red) * (1 - 0.45 * shade))
            greenChannel = UInt8(Double(greenChannel) * (1 - 0.45 * shade))
            blue = UInt8(Double(blue) * (1 - 0.45 * shade))
        }
        let faceDistance = hypot(n - faceCenter, m - faceCenter)
        if faceDistance <= faceRadius {
            if insideEye(n, m, faceCenter: faceCenter, faceRadius: faceRadius) {
                return eye
            }
            return green
        }
        return (red, greenChannel, blue, 255)
    }

    static func insideRoundedSquare(_ x: Double, _ y: Double, radius: Double) -> Bool {
        let inset = radius
        let dx = max(abs(x - 0.5) - (0.5 - inset), 0)
        let dy = max(abs(y - 0.5) - (0.5 - inset), 0)
        return dx * dx + dy * dy <= inset * inset
    }

    static func insideEye(_ x: Double, _ y: Double, faceCenter: Double, faceRadius: Double) -> Bool {
        let eyeWidth = faceRadius * 0.16
        let eyeHeight = faceRadius * 0.34
        // 0.1.1 put each eye center 0.34 radii from the middle. The gap
        // between the pills was 0.52 radii. 0.294 keeps the same pills
        // and makes that gap about 17.6% smaller.
        let spacing = faceRadius * 0.294
        let eyeCenterY = faceCenter + faceRadius * 0.10
        for side in [-1.0, 1.0] {
            let eyeCenterX = faceCenter + side * spacing
            if insidePill(x, y, cx: eyeCenterX, cy: eyeCenterY, width: eyeWidth, height: eyeHeight) {
                return true
            }
        }
        return false
    }

    static func insidePill(_ x: Double, _ y: Double, cx: Double, cy: Double, width: Double, height: Double) -> Bool {
        let capsuleRadius = width / 2
        let dx = max(abs(x - cx) - 0, 0)
        let dy = max(abs(y - cy) - (height / 2 - capsuleRadius), 0)
        if abs(x - cx) > width / 2 { return false }
        return dx * dx + dy * dy <= capsuleRadius * capsuleRadius || abs(y - cy) <= height / 2 - capsuleRadius
    }

    /// Pointer face, in fractions of the face diameter. Same pills as the overlay.
    static func renderPointer(size: Int, pose: TomPointerPose, background: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let n = (Double(x) + 0.5) / Double(size)
                let m = (Double(y) + 0.5) / Double(size)
                let pixel = samplePointer(n, m, pose: pose, background: background)
                let index = (y * size + x) * 4
                pixels[index] = pixel.0
                pixels[index + 1] = pixel.1
                pixels[index + 2] = pixel.2
                pixels[index + 3] = pixel.3
            }
        }
        return pixels
    }

    static func samplePointer(_ n: Double, _ m: Double, pose: TomPointerPose, background: (UInt8, UInt8, UInt8, UInt8)) -> (UInt8, UInt8, UInt8, UInt8) {
        let faceDiameter = 0.62
        let cx = 0.5
        let cy = 0.5 + (pose.bobOffsetY / 30.0) * faceDiameter
        var dx = (n - cx) / faceDiameter
        var dy = (m - cy) / faceDiameter
        dx /= pose.scaleX
        dy /= pose.scaleY
        let radians = -pose.tiltDegrees * .pi / 180
        let cosR = cos(radians)
        let sinR = sin(radians)
        let rx = dx * cosR - dy * sinR
        let ry = dx * sinR + dy * cosR
        let distance = hypot(rx, ry)
        if distance <= 0.5 {
            if pointerEye(rx, ry, pose: pose) {
                return (14, 14, 14, 255)
            }
            return green
        }
        if pose.showsPulse {
            let ringRadius = 0.5 * pose.pulseScale
            let thickness = (2.0 / 30.0) * pose.pulseScale
            if abs(distance - ringRadius) <= thickness / 2 {
                return blend(background, green, 0.45)
            }
        }
        return background
    }

    static func pointerEye(_ x: Double, _ y: Double, pose: TomPointerPose) -> Bool {
        let width = 0.16 * pose.eyeScaleX
        let height = 0.34 * pose.eyeScaleY
        let halfSpan = (0.28 + width) / 2
        let cy = 0.10 + 0.08 * pose.eyeOffsetY
        let shiftX = 0.08 * pose.eyeOffsetX
        for side in [-1.0, 1.0] {
            if insidePill(x, y, cx: side * halfSpan + shiftX, cy: cy, width: width, height: height) {
                return true
            }
        }
        return false
    }

    static func blend(_ base: (UInt8, UInt8, UInt8, UInt8), _ over: (UInt8, UInt8, UInt8, UInt8), _ alpha: Double) -> (UInt8, UInt8, UInt8, UInt8) {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(Double(a) * (1 - alpha) + Double(b) * alpha)
        }
        return (mix(base.0, over.0), mix(base.1, over.1), mix(base.2, over.2), 255)
    }

    /// Menu-bar template. Filled circle when on, outline plus a slash when off.
    static func renderMenuBar(size: Int, isOn: Bool) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let center = 0.5
        let radius = 0.43
        for y in 0..<size {
            for x in 0..<size {
                let n = (Double(x) + 0.5) / Double(size)
                let m = (Double(y) + 0.5) / Double(size)
                let dx = n - center
                let dy = m - center
                let distance = hypot(dx, dy)
                let index = (y * size + x) * 4
                let eye = menuBarEye(n, m)
                var ink = false
                if isOn {
                    ink = distance <= radius && !eye
                } else {
                    let stroke = abs(distance - radius) <= 1.4 / Double(size)
                    let slash = abs((n - 0.08) - (m - 0.08)) <= 1.6 / Double(size) && n > 0.08 && n < 0.92
                    ink = stroke || eye || slash
                }
                if ink {
                    pixels[index] = 0
                    pixels[index + 1] = 0
                    pixels[index + 2] = 0
                    pixels[index + 3] = 255
                }
            }
        }
        return pixels
    }

    static func menuBarEye(_ x: Double, _ y: Double) -> Bool {
        let faceSize = 0.86
        let width = faceSize * 0.16
        let height = faceSize * 0.34
        let gap = faceSize * 0.28
        let cy = 0.5 + faceSize * 0.10
        let halfSpan = (gap + width) / 2
        for side in [-1.0, 1.0] {
            if insidePill(x, y, cx: 0.5 + side * halfSpan, cy: cy, width: width, height: height) {
                return true
            }
        }
        return false
    }
}

struct TomPointerPose {
    var tiltDegrees = 0.0
    var eyeOffsetX = 0.0
    var eyeOffsetY = 0.0
    var scaleX = 1.0
    var scaleY = 1.0
    var eyeScaleX = 1.0
    var eyeScaleY = 1.0
    var bobOffsetY = 0.0
    var pulseScale = 1.0
    var showsPulse = false
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
    var adler: UInt32 = 1
    var s1: UInt32 = 1
    var s2: UInt32 = 0
    for byte in raw {
        s1 = (s1 + UInt32(byte)) % 65521
        s2 = (s2 + s1) % 65521
    }
    adler = (s2 << 16) | s1
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
