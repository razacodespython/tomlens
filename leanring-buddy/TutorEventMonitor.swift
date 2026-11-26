//
//  TutorEventMonitor.swift
//  leanring-buddy
//
//  Runs only while TomLens is switched on: samples the picked window at
//  ~1 fps (1024 px JPEG) and keeps the last three frames so a push-to-talk
//  turn has recent chart context. Sampling does not call the model and does
//  not speak. Bar-close and sharp-change automatic turns are not raised.
//  Captures only the picked window, through CompanionScreenCaptureUtility's
//  policy checks.
//

import Foundation

@MainActor
final class TutorEventMonitor {
    let frameBuffer = RecentFrameBuffer()
    /// The newest successful capture (for mapping drawings onto the window).
    private(set) var latestCapture: CompanionScreenCapture?
    /// Kept so any future automatic trigger still has to pass
    /// TutorTriggerPolicy.shouldSendAutomaticTrigger. This monitor does not call it.
    var onAutomaticTrigger: ((TutorTrigger) -> Void)?

    private var frameSamplingTask: Task<Void, Never>?

    var isRunning: Bool { frameSamplingTask != nil }

    func start(pickedSelection: @escaping () -> PickedTradingWindowSelection?) {
        stop()
        frameSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleFrame(pickedSelection: pickedSelection())
                try? await Task.sleep(nanoseconds: UInt64(TutorTriggerPolicy.frameSampleIntervalSeconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        frameSamplingTask?.cancel()
        frameSamplingTask = nil
        frameBuffer.removeAll()
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
        } catch {
            // Window hidden, closed or denied: drop history so the next
            // push-to-talk turn does not send frames from a different window.
            frameBuffer.removeAll()
            latestCapture = nil
        }
    }
}
