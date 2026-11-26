// Renders proof frames from the shipped pose math and the icon pixel face.
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
    var activity: TomLensActivity
    var time: TimeInterval
}

func motionShots() -> [MotionShot] {
    var shots: [MotionShot] = []
    for index in 0..<6 {
        shots.append(MotionShot(velocityX: 0, activity: .idle, time: 0.40 + Double(index) * 0.05))
    }
    shots.append(MotionShot(velocityX: 0, activity: .idle, time: 0.03))
    shots.append(MotionShot(velocityX: 0, activity: .idle, time: 0.08))
    for index in 0..<8 {
        shots.append(MotionShot(velocityX: 520, activity: .idle, time: 0.12 + Double(index) * 0.07))
    }
    for index in 0..<8 {
        shots.append(MotionShot(velocityX: 0, activity: .listening, time: 0.05 + Double(index) * 0.08))
    }
    for index in 0..<8 {
        shots.append(MotionShot(velocityX: 0, activity: .speaking, time: 0.08 + Double(index) * 0.08))
    }
    return shots
}

func iconPose(from cursor: TomCursorPose) -> TomIconPose {
    TomIconPose(
        tiltDegrees: cursor.tiltDegrees,
        eyeOffsetX: cursor.eyeOffsetX,
        eyeOffsetY: cursor.eyeOffsetY,
        scaleX: cursor.scaleX,
        scaleY: cursor.scaleY,
        eyeScaleX: cursor.eyeScaleX,
        eyeScaleY: cursor.eyeScaleY,
        verticalPoints: cursor.bobOffsetY + cursor.hopOffsetY,
        pulseScale: cursor.pulseScale,
        showsPulse: cursor.showsPulse,
        earFlapDegrees: cursor.earFlapDegrees
    )
}

func renderMotionProof() throws {
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/tom-motion-frames")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let stage = TomIconColor.rgb(0.16, 0.16, 0.18)
let frameSize = 180
for (index, shot) in motionShots().enumerated() {
    let cursor = TomCursorMotion.pose(
        velocityX: shot.velocityX,
        velocityY: 0,
        activity: shot.activity,
        isPointing: false,
        reduceMotion: false,
        time: shot.time
    )
    let pixels = TomIconPixels.render(size: frameSize, pose: iconPose(from: cursor), background: stage)
    let url = outputDirectory.appendingPathComponent(String(format: "frame-%02d.png", index))
    try pngData(width: frameSize, height: frameSize, rgba: pixels).write(to: url)
    print("wrote \(url.lastPathComponent) ears \(cursor.earFlapDegrees) hop \(cursor.hopOffsetY)")
}

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
