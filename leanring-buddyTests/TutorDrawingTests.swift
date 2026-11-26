//
//  TutorDrawingTests.swift
//  leanring-buddyTests
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import TomLens

struct TutorDrawingTests {
    private let screenshotSize = CGSize(width: 1280, height: 800)

    @Test func parsesAllFourShapesAndStripsTheTag() {
        let reply = """
        Wait for the three minute close above vwap. <draw>[{"type":"level","y":312,"label":"vwap"},{"type":"circle","x":640,"y":300,"r":40},{"type":"arrow","from":[600,420],"to":[640,300]},{"type":"point","x":700,"y":280,"label":"entry"}]</draw>
        """
        let (spoken, drawing) = TutorDrawingParser.parse(responseText: reply, screenshotSizeInPixels: screenshotSize)
        #expect(spoken == "Wait for the three minute close above vwap.")
        #expect(drawing.shapes == [
            .level(y: 312, label: "vwap"),
            .circle(center: CGPoint(x: 640, y: 300), radius: 40, label: nil),
            .arrow(from: CGPoint(x: 600, y: 420), to: CGPoint(x: 640, y: 300), label: nil),
            .point(CGPoint(x: 700, y: 280), label: "entry"),
        ])
        #expect(drawing.primaryPoint == CGPoint(x: 640, y: 300))
    }

    @Test func noTagOrEmptyArrayMeansNoDraw() {
        let plain = TutorDrawingParser.parse(responseText: "No setup yet.", screenshotSizeInPixels: screenshotSize)
        #expect(plain.spokenText == "No setup yet." && plain.drawing.isEmpty)
        let empty = TutorDrawingParser.parse(responseText: "No setup yet. <draw>[]</draw>", screenshotSizeInPixels: screenshotSize)
        #expect(empty.spokenText == "No setup yet." && empty.drawing.isEmpty && empty.drawing.primaryPoint == nil)
        let garbage = TutorDrawingParser.parse(responseText: "Hmm <draw>not json</draw>", screenshotSizeInPixels: screenshotSize)
        #expect(garbage.spokenText == "Hmm" && garbage.drawing.isEmpty)
    }

    @Test func clampsOutOfBoundsAndDropsMalformedShapes() {
        let shapes = TutorDrawingParser.parseShapes(json: """
        {"shapes":[{"type":"point","x":-50,"y":9999},{"type":"arrow","from":[1,1],"to":[1,1]},{"type":"star","x":1,"y":1},{"type":"level"},{"type":"circle","x":10,"y":10,"r":5000}]}
        """, screenshotSizeInPixels: screenshotSize)
        #expect(shapes == [
            .point(CGPoint(x: 0, y: 800), label: nil),
            .circle(center: CGPoint(x: 10, y: 10), radius: 640, label: nil),
        ])
    }

    @Test func keepsAtMostEightShapes() {
        let many = "[" + Array(repeating: #"{"type":"point","x":1,"y":1}"#, count: 20).joined(separator: ",") + "]"
        #expect(TutorDrawingParser.parseShapes(json: many, screenshotSizeInPixels: screenshotSize).count == 8)
    }

    @Test func windowLocalMappingScalesPixelsToWindowPointsTopLeft() {
        // 1280x800 screenshot of a 1600x1000 pt window: scale 1.25.
        let windowSize = CGSize(width: 1600, height: 1000)
        let mapped = TradingWindowCoordinateMapping.windowLocalPoint(
            fromScreenshotPoint: CGPoint(x: 640, y: 200), screenshotSizeInPixels: screenshotSize, windowSizeInPoints: windowSize)
        #expect(abs(mapped.x - 800) < 0.001 && abs(mapped.y - 250) < 0.001)
        let corner = TradingWindowCoordinateMapping.windowLocalPoint(
            fromScreenshotPoint: CGPoint(x: 5000, y: -10), screenshotSizeInPixels: screenshotSize, windowSizeInPoints: windowSize)
        #expect(corner == CGPoint(x: 1600, y: 0))
        let radius = TradingWindowCoordinateMapping.windowLocalLength(
            fromScreenshotLength: 40, screenshotSizeInPixels: screenshotSize, windowSizeInPoints: windowSize)
        #expect(abs(radius - 50) < 0.001)
    }

    @Test func windowLocalAndGlobalMappingsAgree() {
        // A window at AppKit origin (100, 50), 1600x1000 pt. A point's global
        // position equals origin + local x, and origin.y + height - local y.
        let frame = CGRect(x: 100, y: 50, width: 1600, height: 1000)
        let screenshotPoint = CGPoint(x: 320, y: 600)
        let local = TradingWindowCoordinateMapping.windowLocalPoint(
            fromScreenshotPoint: screenshotPoint, screenshotSizeInPixels: screenshotSize, windowSizeInPoints: frame.size)
        let global = TradingWindowCoordinateMapping.appKitGlobalPoint(
            fromScreenshotPoint: screenshotPoint, screenshotSizeInPixels: screenshotSize, windowFrameInAppKitCoordinates: frame)
        #expect(abs(global.x - (frame.minX + local.x)) < 0.001)
        #expect(abs(global.y - (frame.minY + frame.height - local.y)) < 0.001)
    }

    @Test func degenerateScreenshotSizeMapsToZero() {
        #expect(TradingWindowCoordinateMapping.windowLocalPoint(
            fromScreenshotPoint: CGPoint(x: 5, y: 5), screenshotSizeInPixels: .zero, windowSizeInPoints: CGSize(width: 10, height: 10)) == .zero)
    }
}
