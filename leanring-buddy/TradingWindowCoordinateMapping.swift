//
//  TradingWindowCoordinateMapping.swift
//  leanring-buddy
//
//  Pure math that maps a point in the captured window screenshot (pixels,
//  top-left origin) to AppKit global coordinates (points, bottom-left
//  origin) so the click-through overlay can draw on the picked window.
//

import Foundation

enum TradingWindowCoordinateMapping {
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
}
