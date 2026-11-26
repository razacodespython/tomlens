//
//  TomCursorMotion.swift
//  leanring-buddy
//
//  Pure motion for the round Tom mascot that follows the pointer. No AppKit,
//  so the blink, tilt, hop, and ear-flap rules can be tested on Linux.
//

import Foundation

nonisolated struct TomCursorPose: Equatable {
    var tiltDegrees: Double
    var eyeOffsetX: Double
    var eyeOffsetY: Double
    var scaleX: Double
    var scaleY: Double
    var eyeScaleX: Double
    var eyeScaleY: Double
    var bobOffsetY: Double
    var hopOffsetY: Double
    var pulseScale: Double
    var showsPulse: Bool
    /// Side panels swing out by this many degrees. Zero is tucked in.
    var earFlapDegrees: Double
}

nonisolated enum TomFaceGeometry {
    /// Flat green from the mascot reference, #5AC078.
    static let greenRed = 90.0 / 255.0
    static let greenGreen = 192.0 / 255.0
    static let greenBlue = 120.0 / 255.0
    /// Glowing LED cores, near white with a green cast.
    static let eyeRed = 244.0 / 255.0
    static let eyeGreen = 255.0 / 255.0
    static let eyeBlue = 232.0 / 255.0
    /// Soft glow around each LED.
    static let glowRed = 198.0 / 255.0
    static let glowGreen = 255.0 / 255.0
    static let glowBlue = 140.0 / 255.0
    /// Darker green for the side panels and the equator seam.
    static let earRed = 36.0 / 255.0
    static let earGreen = 122.0 / 255.0
    static let earBlue = 68.0 / 255.0
    static let seamRed = 24.0 / 255.0
    static let seamGreen = 92.0 / 255.0
    static let seamBlue = 52.0 / 255.0
    /// Dark rounded-square tile, #1C1C1E.
    static let tileRed = 28.0 / 255.0
    static let tileGreen = 28.0 / 255.0
    static let tileBlue = 30.0 / 255.0

    /// Fractions of the ball diameter. Negative Y is up (SwiftUI and the
    /// icon renderer both treat a negative value as the upper half).
    /// The eyes are horizontal LED slits. Spacing is the gap between them.
    static let eyeCenterYFraction = -0.17
    static let eyeSpacingFraction = 0.08
    static let eyeWidthFraction = 0.20
    static let eyeHeightFraction = 0.11
    static let mouthWidthFraction = 0.22
    static let mouthHeightFraction = 0.06
    static let mouthCenterYFraction = 0.16
    static let seamThicknessFraction = 0.05
    static let earWidthFraction = 0.15
    static let earHeightFraction = 0.34
    /// Tucked in at rest. Listening and speaking swing them out.
    static let earRestDegrees = 0.0
    static let earActiveDegrees = 34.0
    /// App icon shows the panels a little open so the mark reads at 32 px.
    static let iconEarDegrees = 22.0
}

nonisolated enum TomCursorMotion {
    static let blinkPeriodSeconds: TimeInterval = 4.5
    static let blinkDurationSeconds: TimeInterval = 0.12

    static func pose(
        velocityX: Double,
        velocityY: Double,
        activity: TomLensActivity,
        isPointing: Bool,
        reduceMotion: Bool,
        time: TimeInterval
    ) -> TomCursorPose {
        let speed = hypot(velocityX, velocityY)
        var eyeOffsetX = 0.0
        var eyeOffsetY = 0.0
        var tiltDegrees = 0.0
        var scaleX = 1.0
        var scaleY = 1.0

        if !reduceMotion {
            if speed >= 40 {
                eyeOffsetX = min(1, max(-1, velocityX / 520))
                eyeOffsetY = min(1, max(-1, velocityY / 520))
                tiltDegrees = min(18, max(-18, velocityX / 45))
            }
            if speed > 220 {
                let stretch = min(0.14, (speed - 220) / 4200)
                if abs(velocityX) >= abs(velocityY) {
                    scaleX = 1 + stretch
                    scaleY = 1 - stretch * 0.55
                } else {
                    scaleY = 1 + stretch
                    scaleX = 1 - stretch * 0.55
                }
            }
        }

        var eyeScaleX = 1.0
        var eyeScaleY = 1.0
        var bobOffsetY = 0.0
        var hopOffsetY = 0.0
        var showsPulse = false
        var pulseScale = 1.0
        var earFlapDegrees = TomFaceGeometry.earRestDegrees

        if !reduceMotion && speed >= 40 {
            hopOffsetY = -abs(sin(time * 9)) * min(4.5, speed / 160)
        }

        switch activity {
        case .listening:
            eyeScaleX = 1.16
            eyeScaleY = 1.28
            showsPulse = !reduceMotion
            pulseScale = reduceMotion ? 1 : 1.12 + 0.10 * sin(time * 3.2)
            earFlapDegrees = flappingEarDegrees(time: time, reduceMotion: reduceMotion)
        case .thinking:
            eyeOffsetX = 0.62
            eyeOffsetY = -0.72
            bobOffsetY = reduceMotion ? 0 : sin(time * 1.3) * 2.4
        case .speaking:
            bobOffsetY = reduceMotion ? 0 : abs(sin(time * 6.5)) * -3.2
            if !reduceMotion {
                hopOffsetY += -abs(sin(time * 7.2)) * 3.6
            }
            earFlapDegrees = flappingEarDegrees(time: time, reduceMotion: reduceMotion)
        case .off, .idle:
            break
        }

        if isPointing {
            bobOffsetY += reduceMotion ? 0 : sin(time * 2.1) * 2.0
        }

        if isBlinking(time: time, reduceMotion: reduceMotion) {
            eyeScaleY *= 0.1
        }

        return TomCursorPose(
            tiltDegrees: tiltDegrees,
            eyeOffsetX: eyeOffsetX,
            eyeOffsetY: eyeOffsetY,
            scaleX: scaleX,
            scaleY: scaleY,
            eyeScaleX: eyeScaleX,
            eyeScaleY: eyeScaleY,
            bobOffsetY: bobOffsetY,
            hopOffsetY: hopOffsetY,
            pulseScale: pulseScale,
            showsPulse: showsPulse,
            earFlapDegrees: earFlapDegrees
        )
    }

    /// Side panels stay open, without oscillating, when Reduce Motion is on.
    static func flappingEarDegrees(time: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion {
            return TomFaceGeometry.earRestDegrees + TomFaceGeometry.earActiveDegrees
        }
        let wave = abs(sin(time * 8))
        return TomFaceGeometry.earRestDegrees + TomFaceGeometry.earActiveDegrees * (0.35 + 0.65 * wave)
    }

    static func isBlinking(time: TimeInterval, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        let phase = time.truncatingRemainder(dividingBy: blinkPeriodSeconds)
        let normalizedPhase = phase < 0 ? phase + blinkPeriodSeconds : phase
        return normalizedPhase < blinkDurationSeconds
    }
}
