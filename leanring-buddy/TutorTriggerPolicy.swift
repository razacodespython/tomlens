//
//  TutorTriggerPolicy.swift
//  leanring-buddy
//
//  Pure rules for when Tom speaks up. Speech is a push-to-talk utterance.
//  Clock-aligned 3-minute bar closes and sharp chart changes are still
//  described here, but automatic model calls for them are off, so they never
//  speak. Also holds the last few frames to send with a push-to-talk call.
//

import Foundation

nonisolated enum TutorTrigger: Equatable {
    case pushToTalk(transcript: String)
    case barClose(closedAt: Date)
    case sharpChange(score: Double)

    var isAutomatic: Bool {
        if case .pushToTalk = self { return false }
        return true
    }

    var journalName: String {
        switch self {
        case .pushToTalk: return "push_to_talk"
        case .barClose: return "bar_close"
        case .sharpChange: return "sharp_change"
        }
    }

    /// The user-turn text sent with the frames.
    var userPromptText: String {
        switch self {
        case .pushToTalk(let transcript):
            return transcript
        case .barClose:
            return "[automatic check: a 3-minute bar just closed. If a setup just confirmed or a rule is about to be broken, say so in one sentence. Otherwise reply with exactly <silent/>.]"
        case .sharpChange:
            return "[automatic check: the chart changed sharply. If it matters for a setup or risk, say so in one sentence. Otherwise reply with exactly <silent/>.]"
        }
    }
}

nonisolated enum TutorTriggerPolicy {
    static let barDurationSeconds: TimeInterval = 180
    /// Wait a moment after the close so the platform has painted the new bar.
    static let barCloseSettleSeconds: TimeInterval = 2
    static let frameSampleIntervalSeconds: TimeInterval = 1
    /// Automatic calls leave this many calls in the hourly cap for push-to-talk.
    static let callsReservedForPushToTalk = 10

    /// Next 3-minute boundary strictly after `date`. Unix time is aligned to
    /// UTC hours and HKT is a whole-hour offset, so these are :00, :03, ...
    /// on the wall clock.
    static func nextBarCloseDate(after date: Date, barDurationSeconds: TimeInterval = barDurationSeconds) -> Date {
        let seconds = date.timeIntervalSince1970
        let nextBoundary = (floor(seconds / barDurationSeconds) + 1) * barDurationSeconds
        return Date(timeIntervalSince1970: nextBoundary)
    }

    /// Whether an automatic (non push-to-talk) call may go out now.
    ///
    /// Always false. Bar-close and sharp-change turns must not call the model
    /// or speak. Push-to-talk and Ask Tom / session-end reviews do not use
    /// this gate. The arguments stay so CompanionManager still asks the policy
    /// before any automatic turn.
    static func shouldSendAutomaticTrigger(
        isSwitchedOn: Bool,
        isUserSpeakingOrWaiting: Bool,
        isPlanUsagePaused: Bool,
        remainingCallsThisHour: Int
    ) -> Bool {
        false
    }
}

/// Mean absolute difference between two equally sized 8-bit grayscale
/// thumbnails, normalized to 0...1.
nonisolated enum FrameDifference {
    static let thumbnailWidth = 64
    static let thumbnailHeight = 40

    static func score(previous: [UInt8], current: [UInt8]) -> Double {
        guard !previous.isEmpty, previous.count == current.count else { return 0 }
        var totalDifference = 0
        for index in previous.indices {
            totalDifference += abs(Int(previous[index]) - Int(current[index]))
        }
        return Double(totalDifference) / Double(previous.count * 255)
    }
}

/// Flags a sharp change between consecutive ~1 fps thumbnails, with a
/// cooldown so a fast market doesn't trigger a call every second.
nonisolated final class SharpChangeDetector {
    static let defaultThreshold = 0.06
    static let defaultCooldownSeconds: TimeInterval = 60

    let threshold: Double
    let cooldownSeconds: TimeInterval
    private var previousThumbnail: [UInt8]?
    private var lastTriggerDate: Date?

    init(threshold: Double = SharpChangeDetector.defaultThreshold, cooldownSeconds: TimeInterval = SharpChangeDetector.defaultCooldownSeconds) {
        self.threshold = threshold
        self.cooldownSeconds = cooldownSeconds
    }

    /// Returns the score when this frame is a sharp change worth a call.
    func consume(thumbnail: [UInt8], at date: Date) -> Double? {
        defer { previousThumbnail = thumbnail }
        guard let previousThumbnail else { return nil }
        let changeScore = FrameDifference.score(previous: previousThumbnail, current: thumbnail)
        guard changeScore >= threshold else { return nil }
        if let lastTriggerDate, date.timeIntervalSince(lastTriggerDate) < cooldownSeconds { return nil }
        lastTriggerDate = date
        return changeScore
    }

    func reset() {
        previousThumbnail = nil
        lastTriggerDate = nil
    }
}

nonisolated struct TutorFrame: Equatable {
    let jpegData: Data
    let widthInPixels: Int
    let heightInPixels: Int
    let capturedAt: Date
}

/// The last few sampled frames (oldest first).
nonisolated final class RecentFrameBuffer {
    static let defaultCapacity = 3
    static let frameMaximumDimension = 1024

    let capacity: Int
    private(set) var frames: [TutorFrame] = []

    init(capacity: Int = RecentFrameBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    func append(_ frame: TutorFrame) {
        frames.append(frame)
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
    }

    func removeAll() {
        frames.removeAll()
    }

    /// Frames to send: up to `limit` most recent, oldest first.
    func framesToSend(limit: Int = RecentFrameBuffer.defaultCapacity) -> [TutorFrame] {
        Array(frames.suffix(limit))
    }
}
