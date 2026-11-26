//
//  TradingWindowCoordinateMapping.swift
//  leanring-buddy
//
//  Pure math that maps a point in the captured window screenshot (pixels,
//  top-left origin) to AppKit global coordinates (points, bottom-left
//  origin) so the click-through overlay can draw on the picked window.
//

import Foundation

nonisolated enum TradingWindowCoordinateMapping {
    static func appKitGlobalPoint(
        fromScreenshotPoint screenshotPoint: CGPoint,
        screenshotSizeInPixels: CGSize,
        windowFrameInAppKitCoordinates windowFrame: CGRect
    ) -> CGPoint {
        // Clamp to the screenshot so a sloppy model coordinate can never land
        // outside the picked window.
        let clampedX = max(0, min(screenshotPoint.x, screenshotSizeInPixels.width))
        let clampedY = max(0, min(screenshotPoint.y, screenshotSizeInPixels.height))

        // Scale from screenshot pixels to window points
        let windowLocalX = clampedX * (windowFrame.width / screenshotSizeInPixels.width)
        let windowLocalY = clampedY * (windowFrame.height / screenshotSizeInPixels.height)

        // Flip from top-left origin (screenshot) to bottom-left origin (AppKit)
        let appKitLocalY = windowFrame.height - windowLocalY

        return CGPoint(
            x: windowLocalX + windowFrame.origin.x,
            y: appKitLocalY + windowFrame.origin.y
        )
    }

    /// Maps a screenshot pixel point to window-local points with a top-left
    /// origin (SwiftUI drawing space of an overlay sized to the window).
    /// Recomputed on every draw, so a moved or resized window stays aligned.
    static func windowLocalPoint(
        fromScreenshotPoint screenshotPoint: CGPoint,
        screenshotSizeInPixels: CGSize,
        windowSizeInPoints: CGSize
    ) -> CGPoint {
        guard screenshotSizeInPixels.width > 0, screenshotSizeInPixels.height > 0 else { return .zero }
        let clampedX = max(0, min(screenshotPoint.x, screenshotSizeInPixels.width))
        let clampedY = max(0, min(screenshotPoint.y, screenshotSizeInPixels.height))
        return CGPoint(
            x: clampedX * windowSizeInPoints.width / screenshotSizeInPixels.width,
            y: clampedY * windowSizeInPoints.height / screenshotSizeInPixels.height
        )
    }

    /// Scales a screenshot pixel length (e.g. a circle radius) to window points.
    static func windowLocalLength(
        fromScreenshotLength screenshotLength: CGFloat,
        screenshotSizeInPixels: CGSize,
        windowSizeInPoints: CGSize
    ) -> CGFloat {
        guard screenshotSizeInPixels.width > 0 else { return 0 }
        return screenshotLength * windowSizeInPoints.width / screenshotSizeInPixels.width
    }
}
