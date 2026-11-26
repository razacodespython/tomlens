//
//  TradingWindowDrawingOverlay.swift
//  leanring-buddy
//
//  Short-lived, click-through drawing layer over the picked trading window.
//  The panel ignores all mouse events, never becomes key or main, is
//  excluded from screen sharing/capture, follows the window's live
//  SCWindow.frame and clears itself after a few seconds. It only draws;
//  it never clicks, types or touches the trading app.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class TradingWindowDrawingOverlayController {
    static let displayDurationSeconds: TimeInterval = 8
    static let frameFollowIntervalSeconds: TimeInterval = 0.5

    private var overlayPanel: NSPanel?
    private let drawingModel = TradingWindowDrawingModel()
    private var hideTask: Task<Void, Never>?
    private var frameFollowTask: Task<Void, Never>?

    /// Shows the drawing over the window. An empty drawing just clears.
    func show(_ drawing: TutorDrawing, windowFrameInAppKitCoordinates windowFrame: CGRect, pickedSelection: PickedTradingWindowSelection?) {
        guard !drawing.isEmpty else {
            hide()
            return
        }
        let panel = overlayPanel ?? makeOverlayPanel()
        overlayPanel = panel
        drawingModel.drawing = drawing
        panel.setFrame(windowFrame, display: true)
        panel.orderFrontRegardless()

        frameFollowTask?.cancel()
        frameFollowTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.frameFollowIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let liveFrame = await Self.liveFrame(of: pickedSelection) else {
                    // Window closed, minimized or no longer allowed: stop drawing.
                    self?.hide()
                    return
                }
                if self?.overlayPanel?.frame != liveFrame {
                    self?.overlayPanel?.setFrame(liveFrame, display: true)
                }
            }
        }

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.displayDurationSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        frameFollowTask?.cancel()
        frameFollowTask = nil
        drawingModel.drawing = nil
        overlayPanel?.orderOut(nil)
    }

    private static func liveFrame(of pickedSelection: PickedTradingWindowSelection?) async -> CGRect? {
        guard let pickedSelection,
              let liveWindows = try? await CompanionScreenCaptureUtility.shareableWindows(),
              let liveCandidate = TradingWindowCapturePolicy.resolvePickedWindow(pickedSelection, among: liveWindows.map(\.candidate)),
              let liveWindow = liveWindows.first(where: { $0.window.windowID == liveCandidate.windowID })?.window else {
            return nil
        }
        return CompanionScreenCaptureUtility.appKitFrame(fromScreenCaptureKitFrame: liveWindow.frame)
    }

    private func makeOverlayPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: TradingWindowDrawingView(drawingModel: drawingModel))
        return panel
    }
}

@MainActor
final class TradingWindowDrawingModel: ObservableObject {
    @Published var drawing: TutorDrawing?
}

struct TradingWindowDrawingView: View {
    @ObservedObject var drawingModel: TradingWindowDrawingModel

    private let strokeColor = Color(red: 1.0, green: 0.78, blue: 0.14)

    var body: some View {
        GeometryReader { geometry in
            if let drawing = drawingModel.drawing {
                ZStack(alignment: .topLeading) {
                    Canvas { context, canvasSize in
                        for shape in drawing.shapes {
                            context.stroke(path(for: shape, drawing: drawing, size: canvasSize), with: .color(strokeColor), lineWidth: 2.5)
                        }
                    }
                    ForEach(Array(drawing.shapes.enumerated()), id: \.offset) { _, shape in
                        if let placement = labelPlacement(for: shape, drawing: drawing, size: geometry.size) {
                            Text(placement.text)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(strokeColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
                                .position(x: placement.anchor.x, y: max(10, placement.anchor.y - 12))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func mapped(_ point: CGPoint, _ drawing: TutorDrawing, _ size: CGSize) -> CGPoint {
        TradingWindowCoordinateMapping.windowLocalPoint(
            fromScreenshotPoint: point,
            screenshotSizeInPixels: drawing.screenshotSizeInPixels,
            windowSizeInPoints: size
        )
    }

    private func path(for shape: TutorDrawShape, drawing: TutorDrawing, size: CGSize) -> Path {
        var path = Path()
        switch shape {
        case .point(let point, _):
            let center = mapped(point, drawing, size)
            path.addEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
        case .arrow(let fromPoint, let toPoint, _):
            let start = mapped(fromPoint, drawing, size)
            let end = mapped(toPoint, drawing, size)
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            for wingAngle in [angle + .pi * 0.85, angle - .pi * 0.85] {
                path.move(to: end)
                path.addLine(to: CGPoint(x: end.x + 12 * cos(wingAngle), y: end.y + 12 * sin(wingAngle)))
            }
        case .circle(let centerPoint, let radius, _):
            let center = mapped(centerPoint, drawing, size)
            let mappedRadius = TradingWindowCoordinateMapping.windowLocalLength(
                fromScreenshotLength: radius,
                screenshotSizeInPixels: drawing.screenshotSizeInPixels,
                windowSizeInPoints: size
            )
            path.addEllipse(in: CGRect(x: center.x - mappedRadius, y: center.y - mappedRadius, width: mappedRadius * 2, height: mappedRadius * 2))
        case .level(let levelY, _):
            let y = mapped(CGPoint(x: 0, y: levelY), drawing, size).y
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        return path
    }

    private func labelPlacement(for shape: TutorDrawShape, drawing: TutorDrawing, size: CGSize) -> (text: String, anchor: CGPoint)? {
        switch shape {
        case .point(let point, let label):
            return label.map { ($0, mapped(point, drawing, size)) }
        case .arrow(let fromPoint, _, let label):
            return label.map { ($0, mapped(fromPoint, drawing, size)) }
        case .circle(let center, let radius, let label):
            return label.map { ($0, mapped(CGPoint(x: center.x, y: max(0, center.y - radius)), drawing, size)) }
        case .level(let levelY, let label):
            return label.map { ($0, CGPoint(x: size.width - 60, y: mapped(CGPoint(x: 0, y: levelY), drawing, size).y)) }
        }
    }
}
