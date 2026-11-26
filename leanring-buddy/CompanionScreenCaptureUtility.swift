//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Captures exactly one window: the trading window the user picked. Uses
//  SCContentFilter(desktopIndependentWindow:), so nothing else on screen
//  (other windows, other displays, the desktop) is ever captured. Every
//  capture re-checks TradingWindowCapturePolicy and pauses on a mismatch.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let windowWidthInPoints: Int
    let windowHeightInPoints: Int
    /// The captured window's frame in AppKit global coordinates
    /// (bottom-left origin), used to map model coordinates onto the overlay.
    let windowFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let captureDecision: WindowCaptureDecision
    /// Tiny 8-bit grayscale thumbnail for the local frame-difference trigger.
    let grayscaleThumbnail: [UInt8]
    let capturedAt: Date

    var tutorFrame: TutorFrame {
        TutorFrame(
            jpegData: imageData,
            widthInPixels: screenshotWidthInPixels,
            heightInPixels: screenshotHeightInPixels,
            capturedAt: capturedAt
        )
    }
}

enum CompanionScreenCaptureError: LocalizedError {
    case noWindowPicked
    case pickedWindowUnavailable
    case captureDenied(reason: String)

    var errorDescription: String? {
        switch self {
        case .noWindowPicked:
            return "Pick your Tradovate window in the TomLens menu first."
        case .pickedWindowUnavailable:
            return "I can't find your trading window, so I'm paused."
        case .captureDenied(let reason):
            return "I'm paused because \(reason)."
        }
    }
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Lists on-screen windows as policy candidates, paired with their SCWindow.
    static func shareableWindows() async throws -> [(window: SCWindow, candidate: CapturableWindowCandidate)] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows
            .filter { $0.windowLayer == 0 }
            .map { window in
                (window: window, candidate: CapturableWindowCandidate(
                    windowID: window.windowID,
                    bundleIdentifier: window.owningApplication?.bundleIdentifier,
                    applicationName: window.owningApplication?.applicationName ?? "Unknown app",
                    windowTitle: window.title,
                    frame: window.frame
                ))
            }
    }

    /// Windows the user may pick, Tradovate desktop first. Denylisted
    /// windows and TomLens's own windows are never listed.
    static func pickerCandidates() async throws -> [CapturableWindowCandidate] {
        let liveCandidates = try await shareableWindows().map(\.candidate)
        return TradingWindowCapturePolicy.pickerCandidates(
            from: liveCandidates,
            excludingBundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    /// Captures the picked window only, as JPEG scaled to at most `maxDimension` px.
    static func capturePickedWindowAsJPEG(
        pickedSelection: PickedTradingWindowSelection?,
        maxDimension: Int = RecentFrameBuffer.frameMaximumDimension
    ) async throws -> CompanionScreenCapture {
        guard let pickedSelection else {
            throw CompanionScreenCaptureError.noWindowPicked
        }

        let liveWindows = try await shareableWindows()
        guard let liveCandidate = TradingWindowCapturePolicy.resolvePickedWindow(
            pickedSelection,
            among: liveWindows.map(\.candidate)
        ), let liveWindow = liveWindows.first(where: { $0.window.windowID == liveCandidate.windowID })?.window else {
            throw CompanionScreenCaptureError.pickedWindowUnavailable
        }

        let captureDecision = TradingWindowCapturePolicy.decision(
            forLiveWindow: liveCandidate,
            pickedSelection: pickedSelection
        )
        if case .denied(let reason) = captureDecision {
            throw CompanionScreenCaptureError.captureDenied(reason: reason)
        }

        let filter = SCContentFilter(desktopIndependentWindow: liveWindow)

        let configuration = SCStreamConfiguration()
        let windowWidth = max(liveWindow.frame.width, 1)
        let windowHeight = max(liveWindow.frame.height, 1)
        let aspectRatio = windowWidth / windowHeight
        if windowWidth >= windowHeight {
            configuration.width = maxDimension
            configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
        } else {
            configuration.height = maxDimension
            configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
        }
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw CompanionScreenCaptureError.pickedWindowUnavailable
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: "trading window: \(liveCandidate.menuLabel)",
            windowWidthInPoints: Int(windowWidth),
            windowHeightInPoints: Int(windowHeight),
            windowFrame: appKitFrame(fromScreenCaptureKitFrame: liveWindow.frame),
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height,
            captureDecision: captureDecision,
            grayscaleThumbnail: grayscaleThumbnail(of: cgImage),
            capturedAt: Date()
        )
    }

    /// Downscales to FrameDifference's thumbnail size in 8-bit grayscale.
    static func grayscaleThumbnail(of cgImage: CGImage) -> [UInt8] {
        let width = FrameDifference.thumbnailWidth
        let height = FrameDifference.thumbnailHeight
        var pixels = [UInt8](repeating: 0, count: width * height)
        let didDraw = pixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let context = CGContext(
                data: pixelBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? pixels : []
    }

    /// SCWindow.frame uses Core Graphics global coordinates (top-left origin
    /// of the main display). AppKit uses bottom-left origin, so flip Y
    /// against the main display's height.
    static func appKitFrame(fromScreenCaptureKitFrame screenCaptureKitFrame: CGRect) -> CGRect {
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? screenCaptureKitFrame.maxY
        return CGRect(
            x: screenCaptureKitFrame.origin.x,
            y: mainDisplayHeight - screenCaptureKitFrame.maxY,
            width: screenCaptureKitFrame.width,
            height: screenCaptureKitFrame.height
        )
    }
}
