// Renders proof frames from the shipped pose math and the pointer face.
// Compile with the app's pure motion sources:
//   swiftc -D RENDER_MOTION -o /tmp/render-motion \
//     scripts/render-icon.swift \
//     leanring-buddy/TomLensStatusPresentation.swift \
//     leanring-buddy/TomCursorMotion.swift \
//     scripts/render-motion-gif.swift
//   /tmp/render-motion /tmp/tom-motion-frames

import Foundation

struct MotionShot {
    var velocityX: Double
    var velocityY: Double
    var activity: TomLensActivity
    var isPointing: Bool
    var time: TimeInterval
}

func motionShots() -> [MotionShot] {
    var shots: [MotionShot] = []
    for index in 0..<5 {
        shots.append(MotionShot(velocityX: 0, velocityY: 0, activity: .idle, isPointing: true, time: 0.40 + Double(index) * 0.12))
    }
    shots.append(MotionShot(velocityX: 0, velocityY: 0, activity: .idle, isPointing: false, time: 0.04))
    for index in 0..<6 {
        let step = Double(index)
        shots.append(MotionShot(velocityX: 280 + step * 40, velocityY: 0, activity: .idle, isPointing: false, time: 0.50 + step * 0.08))
    }
    for index in 0..<6 {
        shots.append(MotionShot(velocityX: 0, velocityY: 0, activity: .listening, isPointing: false, time: 0.30 + Double(index) * 0.16))
    }
    return shots
}

func pointerPose(from cursor: TomCursorPose) -> TomPointerPose {
    TomPointerPose(
        tiltDegrees: cursor.tiltDegrees,
        eyeOffsetX: cursor.eyeOffsetX,
        eyeOffsetY: cursor.eyeOffsetY,
        scaleX: cursor.scaleX,
        scaleY: cursor.scaleY,
        eyeScaleX: cursor.eyeScaleX,
        eyeScaleY: cursor.eyeScaleY,
        bobOffsetY: cursor.bobOffsetY,
        pulseScale: cursor.pulseScale,
        showsPulse: cursor.showsPulse
    )
}

func renderMotionProof() throws {
    let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/tom-motion-frames")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let stage = (UInt8(28), UInt8(28), UInt8(30), UInt8(255))
    let frameSize = 180
    for (index, shot) in motionShots().enumerated() {
        let cursor = TomCursorMotion.pose(
            velocityX: shot.velocityX,
            velocityY: shot.velocityY,
            activity: shot.activity,
            isPointing: shot.isPointing,
            reduceMotion: false,
            time: shot.time
        )
        let pixels = TomIconPixels.renderPointer(size: frameSize, pose: pointerPose(from: cursor), background: stage)
        let url = outputDirectory.appendingPathComponent(String(format: "frame-%02d.png", index))
        try pngData(width: frameSize, height: frameSize, rgba: pixels).write(to: url)
        print("wrote \(url.lastPathComponent) tilt \(cursor.tiltDegrees) pulse \(cursor.showsPulse)")
    }

    let still = TomCursorMotion.pose(
        velocityX: 0,
        velocityY: 0,
        activity: .idle,
        isPointing: false,
        reduceMotion: true,
        time: 1
    )
    let face = TomIconPixels.renderPointer(size: 482, pose: pointerPose(from: still), background: (0, 0, 0, 0))
    try pngData(width: 482, height: 482, rgba: face).write(to: outputDirectory.appendingPathComponent("pointer-face.png"))

    func compositeMenuBar(isOn: Bool, url: URL) throws {
        let size = 180
        let glyph = TomIconPixels.renderMenuBar(size: size, isOn: isOn)
        var paper = [UInt8](repeating: 242, count: size * size * 4)
        for index in stride(from: 0, to: paper.count, by: 4) {
            paper[index + 3] = 255
            let alpha = Double(glyph[index + 3]) / 255
            if alpha > 0 {
                paper[index] = UInt8(Double(glyph[index]) * alpha + Double(paper[index]) * (1 - alpha))
                paper[index + 1] = UInt8(Double(glyph[index + 1]) * alpha + Double(paper[index + 1]) * (1 - alpha))
                paper[index + 2] = UInt8(Double(glyph[index + 2]) * alpha + Double(paper[index + 2]) * (1 - alpha))
            }
        }
        try pngData(width: size, height: size, rgba: paper).write(to: url)
    }

    try compositeMenuBar(isOn: true, url: outputDirectory.appendingPathComponent("menubar-on.png"))
    try compositeMenuBar(isOn: false, url: outputDirectory.appendingPathComponent("menubar-off.png"))
    print("wrote menu-bar glyphs")
}
