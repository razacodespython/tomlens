//
//  TutorDrawing.swift
//  leanring-buddy
//
//  Pure parsing of the model's optional draw instructions. The model may end
//  a reply with  <draw>[ ...shapes... ]</draw>  using coordinates in the
//  captured window screenshot's pixel space (top-left origin):
//    {"type":"point","x":640,"y":300,"label":"entry"}
//    {"type":"arrow","from":[600,420],"to":[640,300],"label":"breakout"}
//    {"type":"circle","x":640,"y":300,"r":40,"label":"fork"}
//    {"type":"level","y":312,"label":"VWAP"}   (full-width horizontal line)
//  No tag or an empty array means "no draw". Shapes are clamped to the
//  screenshot, malformed shapes are dropped, and at most 8 are kept.
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated enum TutorDrawShape: Equatable {
    case point(CGPoint, label: String?)
    case arrow(from: CGPoint, to: CGPoint, label: String?)
    case circle(center: CGPoint, radius: CGFloat, label: String?)
    case level(y: CGFloat, label: String?)
}

/// Shapes plus the screenshot size their coordinates refer to.
nonisolated struct TutorDrawing: Equatable {
    let shapes: [TutorDrawShape]
    let screenshotSizeInPixels: CGSize

    var isEmpty: Bool { shapes.isEmpty }

    /// The first point (or arrow head / circle center) drives the cursor flight.
    var primaryPoint: CGPoint? {
        for shape in shapes {
            switch shape {
            case .point(let point, _): return point
            case .arrow(_, let headPoint, _): return headPoint
            case .circle(let center, _, _): return center
            case .level: continue
            }
        }
        return nil
    }
}

nonisolated enum TutorDrawingParser {
    static let maximumShapeCount = 8
    static let drawTagPattern = #"<draw>([\s\S]*?)</draw>"#

    /// Splits a reply into the text to speak and the (possibly empty) drawing.
    static func parse(responseText: String, screenshotSizeInPixels: CGSize) -> (spokenText: String, drawing: TutorDrawing) {
        let emptyDrawing = TutorDrawing(shapes: [], screenshotSizeInPixels: screenshotSizeInPixels)
        guard let tagRegex = try? NSRegularExpression(pattern: drawTagPattern) else {
            return (responseText, emptyDrawing)
        }
        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = tagRegex.matches(in: responseText, range: fullRange)
        let spokenText = tagRegex
            .stringByReplacingMatches(in: responseText, range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let firstMatch = matches.first,
              let payloadRange = Range(firstMatch.range(at: 1), in: responseText) else {
            return (spokenText, emptyDrawing)
        }
        let shapes = parseShapes(json: String(responseText[payloadRange]), screenshotSizeInPixels: screenshotSizeInPixels)
        return (spokenText, TutorDrawing(shapes: shapes, screenshotSizeInPixels: screenshotSizeInPixels))
    }

    static func parseShapes(json: String, screenshotSizeInPixels size: CGSize) -> [TutorDrawShape] {
        guard let parsedJSON = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return [] }
        let rawShapes = (parsedJSON as? [[String: Any]])
            ?? ((parsedJSON as? [String: Any])?["shapes"] as? [[String: Any]])
            ?? []
        return Array(rawShapes.compactMap { shape(from: $0, size: size) }.prefix(maximumShapeCount))
    }

    private static func number(_ value: Any?) -> CGFloat? {
        (value as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    private static func clampedPoint(x: CGFloat, y: CGFloat, size: CGSize) -> CGPoint {
        CGPoint(x: max(0, min(x, size.width)), y: max(0, min(y, size.height)))
    }

    private static func pointPair(_ value: Any?, size: CGSize) -> CGPoint? {
        guard let pair = value as? [Any], pair.count == 2,
              let x = number(pair[0]), let y = number(pair[1]) else { return nil }
        return clampedPoint(x: x, y: y, size: size)
    }

    private static func shape(from rawShape: [String: Any], size: CGSize) -> TutorDrawShape? {
        let label = (rawShape["label"] as? String).map { String($0.prefix(40)) }
        switch (rawShape["type"] as? String)?.lowercased() {
        case "point":
            guard let x = number(rawShape["x"]), let y = number(rawShape["y"]) else { return nil }
            return .point(clampedPoint(x: x, y: y, size: size), label: label)
        case "arrow":
            guard let fromPoint = pointPair(rawShape["from"], size: size),
                  let toPoint = pointPair(rawShape["to"], size: size),
                  fromPoint != toPoint else { return nil }
            return .arrow(from: fromPoint, to: toPoint, label: label)
        case "circle":
            guard let x = number(rawShape["x"]), let y = number(rawShape["y"]) else { return nil }
            let maximumRadius = max(size.width, size.height) / 2
            let radius = max(6, min(number(rawShape["r"]) ?? 30, maximumRadius))
            return .circle(center: clampedPoint(x: x, y: y, size: size), radius: radius, label: label)
        case "level":
            guard let y = number(rawShape["y"]) else { return nil }
            return .level(y: max(0, min(y, size.height)), label: label)
        default:
            return nil
        }
    }
}
