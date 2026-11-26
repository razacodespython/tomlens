//
//  TomCursorMotion.swift
//  leanring-buddy
//
//  Pure motion for the Tom face that follows the pointer. No AppKit, so
//  the blink, tilt, eye look, and squash rules can be tested on Linux.
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
    var pulseScale: Double
    var showsPulse: Bool
}

nonisolated enum TomFaceGeometry {
    /// Flat green from the mascot reference, #5AC078.
    static let greenRed = 90.0 / 255.0
    static let greenGreen = 192.0 / 255.0
    static let greenBlue = 120.0 / 255.0
    /// Near-black eyes, #0E0E0E.
    static let eyeRed = 14.0 / 255.0
    static let eyeGreen = 14.0 / 255.0
    static let eyeBlue = 14.0 / 255.0
    /// Dark rounded-square tile, #1C1C1E.
    static let tileRed = 28.0 / 255.0
    static let tileGreen = 28.0 / 255.0
    static let tileBlue = 30.0 / 255.0

    /// Eyes sit slightly below the face center.
    static let eyeCenterYFraction = 0.10
    static let eyeSpacingFraction = 0.34
    static let eyeWidthFraction = 0.16
    static let eyeHeightFraction = 0.34
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
        var showsPulse = false
        var pulseScale = 1.0

        switch activity {
        case .listening:
            eyeScaleX = 1.16
            eyeScaleY = 1.28
            showsPulse = !reduceMotion
            pulseScale = reduceMotion ? 1 : 1.12 + 0.10 * sin(time * 3.2)
        case .thinking:
            eyeOffsetX = 0.62
            eyeOffsetY = -0.72
            bobOffsetY = reduceMotion ? 0 : sin(time * 1.3) * 2.4
        case .speaking:
            bobOffsetY = reduceMotion ? 0 : abs(sin(time * 6.5)) * -3.2
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
            pulseScale: pulseScale,
            showsPulse: showsPulse
        )
    }

    static func isBlinking(time: TimeInterval, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        let phase = time.truncatingRemainder(dividingBy: blinkPeriodSeconds)
        let normalizedPhase = phase < 0 ? phase + blinkPeriodSeconds : phase
        return normalizedPhase < blinkDurationSeconds
    }
}
