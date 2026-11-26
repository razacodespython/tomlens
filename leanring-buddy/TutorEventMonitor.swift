//
//  TutorEventMonitor.swift
//  leanring-buddy
//
//  Runs only while TomLens is switched on: samples the picked window at
//  ~1 fps (1024 px JPEG + a tiny grayscale thumbnail), keeps the last three
//  frames, and raises automatic triggers on clock-aligned 3-minute bar
//  closes and on sharp frame-to-frame changes. Captures only the picked
//  window, through CompanionScreenCaptureUtility's policy checks.
//

import Foundation

@MainActor
final class TutorEventMonitor {
    let frameBuffer = RecentFrameBuffer()
    /// The newest successful capture (for mapping drawings onto the window).
    private(set) var latestCapture: CompanionScreenCapture?
    var onAutomaticTrigger: ((TutorTrigger) -> Void)?

    private let sharpChangeDetector = SharpChangeDetector()
    private var frameSamplingTask: Task<Void, Never>?
    private var barCloseTask: Task<Void, Never>?

    var isRunning: Bool { frameSamplingTask != nil }

    func start(pickedSelection: @escaping () -> PickedTradingWindowSelection?) {
        stop()
        frameSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleFrame(pickedSelection: pickedSelection())
                try? await Task.sleep(nanoseconds: UInt64(TutorTriggerPolicy.frameSampleIntervalSeconds * 1_000_000_000))
            }
        }
        barCloseTask = Task { [weak self] in
            while !Task.isCancelled {
                let nextBarClose = TutorTriggerPolicy.nextBarCloseDate(after: Date())
                let fireDate = nextBarClose.addingTimeInterval(TutorTriggerPolicy.barCloseSettleSeconds)
                try? await Task.sleep(nanoseconds: UInt64(max(0, fireDate.timeIntervalSinceNow) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.onAutomaticTrigger?(.barClose(closedAt: nextBarClose))
            }
        }
    }

    func stop() {
        frameSamplingTask?.cancel()
        frameSamplingTask = nil
        barCloseTask?.cancel()
        barCloseTask = nil
        frameBuffer.removeAll()
        sharpChangeDetector.reset()
        latestCapture = nil
    }

    /// Adds a fresh capture (e.g. taken for push-to-talk) to the buffer.
    func record(_ capture: CompanionScreenCapture) {
        latestCapture = capture
        frameBuffer.append(capture.tutorFrame)
    }

    private func sampleFrame(pickedSelection: PickedTradingWindowSelection?) async {
        guard pickedSelection != nil else { return }
        do {
            let capture = try await CompanionScreenCaptureUtility.capturePickedWindowAsJPEG(pickedSelection: pickedSelection)
            guard !Task.isCancelled else { return }
            record(capture)
            if let changeScore = sharpChangeDetector.consume(thumbnail: capture.grayscaleThumbnail, at: capture.capturedAt) {
                onAutomaticTrigger?(.sharpChange(score: changeScore))
            }
        } catch {
            // Window hidden, closed or denied: drop history so a reappearing
            // window isn't treated as a sharp change.
            sharpChangeDetector.reset()
            frameBuffer.removeAll()
            latestCapture = nil
        }
    }
}
