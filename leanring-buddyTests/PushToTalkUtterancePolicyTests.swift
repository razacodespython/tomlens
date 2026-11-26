//
//  PushToTalkUtterancePolicyTests.swift
//  leanring-buddyTests
//

import Testing
@testable import TomLens

struct PushToTalkUtterancePolicyTests {

    @Test func shortTapsAreAccidentalAndRealHoldsAreNot() {
        #expect(PushToTalkUtterancePolicy.isAccidentalTap(holdDurationSeconds: 0.1))
        #expect(!PushToTalkUtterancePolicy.isAccidentalTap(holdDurationSeconds: 1.2))
    }

    @Test func micHoldIsCappedBelowSpeechRecognizerLimit() {
        #expect(PushToTalkUtterancePolicy.maximumHoldDurationSeconds <= 55)
    }

    @Test func emptyOrNoiseTranscriptsAreNotSubmitted() {
        #expect(!PushToTalkUtterancePolicy.shouldSubmit(transcript: ""))
        #expect(!PushToTalkUtterancePolicy.shouldSubmit(transcript: "  . "))
        #expect(!PushToTalkUtterancePolicy.shouldSubmit(transcript: "a"))
        #expect(PushToTalkUtterancePolicy.shouldSubmit(transcript: "is this a fork?"))
    }

    @Test func speechTextDropsMarkupAndTags() {
        let cleaned = PushToTalkUtterancePolicy.cleanedTextForSpeech("**Wait** for the close. <summary>x</summary> ```json\n{}\n```")
        #expect(cleaned == "Wait for the close. x")
    }

    @Test func longSpeechIsCutAtASentenceBoundary() {
        let longReply = String(repeating: "This bar has not closed yet. ", count: 30)
        let cleaned = PushToTalkUtterancePolicy.cleanedTextForSpeech(longReply)
        #expect(cleaned.count <= PushToTalkUtterancePolicy.maximumSpokenCharacterCount)
        #expect(cleaned.hasSuffix("."))
    }
}
