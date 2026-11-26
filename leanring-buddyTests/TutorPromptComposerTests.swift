//
//  TutorPromptComposerTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import TomLens

struct TutorPromptComposerTests {

    @Test func instructionsCombineRulesetSafetyFormatAndSummary() {
        let instructions = TutorPromptComposer.instructions(ruleset: "You are Tom.", rollingSummary: "Marked 80 at 21050.")
        #expect(instructions.hasPrefix("You are Tom."))
        #expect(instructions.contains("must never claim you did"))
        #expect(instructions.contains("<draw>"))
        #expect(instructions.contains("<summary>"))
        #expect(instructions.hasSuffix("Marked 80 at 21050."))
        #expect(TutorPromptComposer.instructions(ruleset: "  ", rollingSummary: "").hasPrefix(TutorPromptComposer.fallbackRuleset))
    }

    @Test func replyParsingExtractsSummaryAndSilence() {
        let spoken = TutorPromptComposer.parseReply("Wait for the close. <summary>Fork forming at the 20.</summary>")
        #expect(spoken == .init(spokenText: "Wait for the close.", updatedSummary: "Fork forming at the 20.", isSilent: false))
        let silent = TutorPromptComposer.parseReply("<silent/> <summary>Nothing new.</summary>")
        #expect(silent.isSilent && silent.spokenText.isEmpty && silent.updatedSummary == "Nothing new.")
        #expect(TutorPromptComposer.parseReply("   ").isSilent)
        let longSummary = TutorPromptComposer.parseReply("<summary>\(String(repeating: "x", count: 900))</summary>ok")
        #expect(longSummary.updatedSummary?.count == TutorPromptComposer.maximumSummaryCharacters)
    }

    @Test func frameLabelsCarrySizeAndAge() {
        let frame = TutorFrame(jpegData: Data(), widthInPixels: 1024, heightInPixels: 640, capturedAt: Date(timeIntervalSince1970: 100))
        #expect(TutorPromptComposer.frameLabel(index: 2, frame: frame, now: Date(timeIntervalSince1970: 103)) == "frame 3 (1024x640 pixels, 3s ago)")
    }

    @Test func safetyFilterReplacesClaimsOfActingOnThePlatform() {
        #expect(TutorResponseSafetyFilter.filtered("I placed a buy limit order at 21050.") == TutorResponseSafetyFilter.replacementText)
        #expect(TutorResponseSafetyFilter.filtered("I've moved your stop to breakeven.") == TutorResponseSafetyFilter.replacementText)
        #expect(TutorResponseSafetyFilter.filtered("I'll click the buy button for you.") == TutorResponseSafetyFilter.replacementText)
        let advice = "That's a fork; a buy limit above the low with a ten point stop fits the rules, your call."
        #expect(TutorResponseSafetyFilter.filtered(advice) == advice)
    }
}
