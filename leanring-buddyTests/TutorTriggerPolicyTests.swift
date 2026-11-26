//
//  TutorTriggerPolicyTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import TomLens

struct TutorTriggerPolicyTests {

    @Test func barClosesAlignToThreeMinuteClockMultiples() {
        // 2026-11-26 22:41:10 HKT == 14:41:10 UTC.
        let date = Date(timeIntervalSince1970: 1_795_704_070)
        let next = TutorTriggerPolicy.nextBarCloseDate(after: date)
        #expect(Int(next.timeIntervalSince1970) % 180 == 0)
        #expect(next.timeIntervalSince(date) > 0 && next.timeIntervalSince(date) <= 180)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(utc.component(.minute, from: next) % 3 == 0)
        #expect(utc.component(.second, from: next) == 0)
        // Exactly on a boundary: the next one is a full bar later.
        #expect(TutorTriggerPolicy.nextBarCloseDate(after: next).timeIntervalSince(next) == 180)
    }

    @Test func automaticTriggersRespectSwitchSpeechPauseAndReserve() {
        #expect(TutorTriggerPolicy.shouldSendAutomaticTrigger(isSwitchedOn: true, isUserSpeakingOrWaiting: false, isPlanUsagePaused: false, remainingCallsThisHour: 30))
        #expect(!TutorTriggerPolicy.shouldSendAutomaticTrigger(isSwitchedOn: false, isUserSpeakingOrWaiting: false, isPlanUsagePaused: false, remainingCallsThisHour: 30))
        #expect(!TutorTriggerPolicy.shouldSendAutomaticTrigger(isSwitchedOn: true, isUserSpeakingOrWaiting: true, isPlanUsagePaused: false, remainingCallsThisHour: 30))
        #expect(!TutorTriggerPolicy.shouldSendAutomaticTrigger(isSwitchedOn: true, isUserSpeakingOrWaiting: false, isPlanUsagePaused: true, remainingCallsThisHour: 30))
        #expect(!TutorTriggerPolicy.shouldSendAutomaticTrigger(isSwitchedOn: true, isUserSpeakingOrWaiting: false, isPlanUsagePaused: false, remainingCallsThisHour: 10))
    }

    @Test func frameDifferenceIsNormalizedAndSafe() {
        #expect(FrameDifference.score(previous: [0, 0], current: [255, 255]) == 1)
        #expect(FrameDifference.score(previous: [10, 20], current: [10, 20]) == 0)
        #expect(FrameDifference.score(previous: [1], current: [1, 2]) == 0)
        #expect(FrameDifference.score(previous: [], current: []) == 0)
    }

    @Test func sharpChangeNeedsAPreviousFrameThresholdAndCooldown() {
        let detector = SharpChangeDetector(threshold: 0.1, cooldownSeconds: 60)
        let dark = [UInt8](repeating: 0, count: 100)
        let bright = [UInt8](repeating: 200, count: 100)
        let slightlyBrighter = [UInt8](repeating: 210, count: 100)
        let start = Date(timeIntervalSince1970: 0)
        #expect(detector.consume(thumbnail: dark, at: start) == nil)
        #expect(detector.consume(thumbnail: bright, at: start.addingTimeInterval(1)) != nil)
        #expect(detector.consume(thumbnail: slightlyBrighter, at: start.addingTimeInterval(2)) == nil)
        #expect(detector.consume(thumbnail: dark, at: start.addingTimeInterval(3)) == nil) // cooldown
        #expect(detector.consume(thumbnail: bright, at: start.addingTimeInterval(70)) != nil)
        detector.reset()
        #expect(detector.consume(thumbnail: dark, at: start.addingTimeInterval(200)) == nil)
    }

    @Test func frameBufferKeepsTheLastThreeOldestFirst() {
        let buffer = RecentFrameBuffer()
        for second in 0..<5 {
            buffer.append(TutorFrame(jpegData: Data([UInt8(second)]), widthInPixels: 1024, heightInPixels: 640, capturedAt: Date(timeIntervalSince1970: Double(second))))
        }
        #expect(buffer.frames.map(\.jpegData) == [Data([2]), Data([3]), Data([4])])
        #expect(buffer.framesToSend(limit: 2).map(\.jpegData) == [Data([3]), Data([4])])
        #expect(RecentFrameBuffer.frameMaximumDimension == 1024)
    }

    @Test func automaticPromptsAllowSilence() {
        #expect(TutorTrigger.barClose(closedAt: Date()).userPromptText.contains("<silent/>"))
        #expect(TutorTrigger.pushToTalk(transcript: "is this a fork").userPromptText == "is this a fork")
        #expect(!TutorTrigger.pushToTalk(transcript: "x").isAutomatic)
        #expect(TutorTrigger.sharpChange(score: 0.2).isAutomatic)
    }
}
