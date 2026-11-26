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
    /// Matte lime ball, #7BC62D, with a softer #8FD13A highlight.
    static let greenRed = 123.0 / 255.0
    static let greenGreen = 198.0 / 255.0
    static let greenBlue = 45.0 / 255.0
    static let highlightRed = 143.0 / 255.0
    static let highlightGreen = 209.0 / 255.0
    static let highlightBlue = 58.0 / 255.0
    /// Red LED ovals, #C8102E.
    static let eyeRed = 200.0 / 255.0
    static let eyeGreen = 16.0 / 255.0
    static let eyeBlue = 46.0 / 255.0
    /// Darker green for the closed panel lines and the seam.
    static let earRed = 46.0 / 255.0
    static let earGreen = 110.0 / 255.0
    static let earBlue = 24.0 / 255.0
    /// Open-panel interior, a darker magenta.
    static let earInteriorRed = 138.0 / 255.0
    static let earInteriorGreen = 28.0 / 255.0
    static let earInteriorBlue = 58.0 / 255.0
    static let seamRed = 28.0 / 255.0
    static let seamGreen = 48.0 / 255.0
    static let seamBlue = 18.0 / 255.0
    /// Dark rounded-square tile, #1C1C1E.
    static let tileRed = 28.0 / 255.0
    static let tileGreen = 28.0 / 255.0
    static let tileBlue = 30.0 / 255.0

    /// Fractions of the ball diameter. Positive Y is down.
    /// Two small vertical ovals sit just above a lower-middle seam.
    /// Spacing is the gap between the ovals.
    static let eyeCenterYFraction = -0.02
    static let eyeSpacingFraction = 0.02
    static let eyeWidthFraction = 0.055
    static let eyeHeightFraction = 0.105
    /// Wide shallow curve: the middle sits lower than the ends.
    static let seamCenterYFraction = 0.12
    static let seamHalfSpanFraction = 0.34
    static let seamLiftFraction = 0.055
    static let seamThicknessFraction = 0.018
    /// Closed at rest. Listening holds them open; speaking flaps them.
    static let earRestDegrees = 0.0
    static let earOpenDegrees = 68.0
    static let iconEarDegrees = 0.0
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
            earFlapDegrees = TomFaceGeometry.earOpenDegrees
        case .thinking:
            eyeOffsetX = 0.62
            eyeOffsetY = -0.72
            bobOffsetY = reduceMotion ? 0 : sin(time * 1.3) * 2.4
        case .speaking:
            bobOffsetY = reduceMotion ? 0 : abs(sin(time * 6.5)) * -3.2
            if !reduceMotion {
                hopOffsetY += -abs(sin(time * 7.2)) * 3.6
            }
            earFlapDegrees = speakingEarDegrees(time: time, reduceMotion: reduceMotion)
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

    /// Speaking swings the open panels. Reduce Motion holds them open.
    static func speakingEarDegrees(time: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion {
            return TomFaceGeometry.earOpenDegrees
        }
        let wave = abs(sin(time * 8))
        return TomFaceGeometry.earOpenDegrees * (0.42 + 0.58 * wave)
    }

    static func isBlinking(time: TimeInterval, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        let phase = time.truncatingRemainder(dividingBy: blinkPeriodSeconds)
        let normalizedPhase = phase < 0 ? phase + blinkPeriodSeconds : phase
        return normalizedPhase < blinkDurationSeconds
    }
}
