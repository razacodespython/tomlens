//
//  TutorPromptComposer.swift
//  leanring-buddy
//
//  Pure prompt assembly for Tom: the bundled ruleset (TutorRulesetPrompt.md),
//  TomLens's fixed safety rules (view-only, never place orders), the draw
//  and summary formats, and the rolling session summary. Also parses the
//  model's <summary> and <silent/> tags and filters any reply that claims
//  TomLens acted on the platform.
//

import Foundation

nonisolated enum TutorPromptComposer {
    static let rulesetResourceName = "TutorRulesetPrompt"
    static let maximumSummaryCharacters = 600

    /// Used only if the bundled ruleset is missing.
    static let fallbackRuleset = "You are Tom, a calm trading coach for Master Raza, who trades MNQ in Tradovate. You never place, modify or suggest clicking orders. Keep answers to 1-2 spoken sentences."

    static let viewOnlySafetyRules = """
    Hard rules from the TomLens app (these override everything else):
    - You can only see screenshots of the one Tradovate window. You cannot click, type, move the mouse, or place, modify, cancel or flatten orders, and you must never claim you did. Raza places every order himself.
    - Never tell him to click a specific button; describe the setup and let him decide.
    - Your reply is spoken aloud: plain sentences, no markdown, no lists.
    - Frames are labeled with their pixel size and capture time, oldest first; the last frame is the current chart.
    """

    static let outputFormatRules = """
    Output format:
    - Optionally end with <draw>[...]</draw>: shapes in the LAST frame's pixel space, origin top-left: {"type":"level","y":312,"label":"80"}, {"type":"circle","x":640,"y":300,"r":40,"label":"fork"}, {"type":"arrow","from":[600,420],"to":[640,300]}, {"type":"point","x":700,"y":280,"label":"entry"}. At most three shapes; <draw>[]</draw> or no tag means no drawing.
    - Always end with <summary>...</summary>: an updated running session summary under 400 characters (levels marked, setups seen, trades and results Raza mentioned, rule warnings). It is not spoken.
    - Only when a trade or an account number is actually visible in the picked window, or Raza just said it, append <observe>{"trades":[{"side":{"value":"long","source":"raza_said","confidence":0.9}}],"account":{},"rule_flags":["late entry"]}</observe>. Each value is {"value":...,"source":"screen_read" or "raza_said","confidence":0 to 1}. Omit every field you did not see or hear. Never invent a fill, a price, a balance, or a P&L. The tag is not spoken.
    - For automatic checks with nothing important to say, reply with exactly <silent/> plus the summary tag.
    """

    static func instructions(ruleset: String, rollingSummary: String) -> String {
        let trimmedRuleset = ruleset.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections = [trimmedRuleset.isEmpty ? fallbackRuleset : trimmedRuleset, viewOnlySafetyRules, outputFormatRules]
        if !rollingSummary.isEmpty {
            sections.append("Session summary so far:\n\(rollingSummary)")
        }
        return sections.joined(separator: "\n\n")
    }

    static func frameLabel(index: Int, frame: TutorFrame, now: Date) -> String {
        let secondsAgo = max(0, Int(now.timeIntervalSince(frame.capturedAt).rounded()))
        return "frame \(index + 1) (\(frame.widthInPixels)x\(frame.heightInPixels) pixels, \(secondsAgo)s ago)"
    }

    struct ParsedReply: Equatable {
        let spokenText: String
        let updatedSummary: String?
        let isSilent: Bool
        var observationJSON: String? = nil
    }

    /// Removes <observe>, <summary> and <silent/> tags (call after the draw tag is removed).
    static func parseReply(_ replyText: String) -> ParsedReply {
        var remainingText = replyText
        var observationJSON: String?
        if let observeRange = remainingText.range(of: #"<observe>([\s\S]*?)</observe>"#, options: .regularExpression) {
            let observeBody = remainingText[observeRange]
                .replacingOccurrences(of: "<observe>", with: "")
                .replacingOccurrences(of: "</observe>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            observationJSON = String(observeBody.prefix(20_000))
            remainingText.removeSubrange(observeRange)
        }
        var updatedSummary: String?
        if let summaryRange = remainingText.range(of: #"<summary>([\s\S]*?)</summary>"#, options: .regularExpression) {
            let summaryBody = remainingText[summaryRange]
                .replacingOccurrences(of: "<summary>", with: "")
                .replacingOccurrences(of: "</summary>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            updatedSummary = String(summaryBody.prefix(maximumSummaryCharacters))
            remainingText.removeSubrange(summaryRange)
        }
        let isSilent = remainingText.range(of: #"<silent\s*/?>"#, options: .regularExpression) != nil
        remainingText = remainingText.replacingOccurrences(of: #"<silent\s*/?>"#, with: "", options: .regularExpression)
        let spokenText = remainingText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedReply(
            spokenText: isSilent ? "" : spokenText,
            updatedSummary: updatedSummary,
            isSilent: isSilent || spokenText.isEmpty,
            observationJSON: observationJSON
        )
    }
}

/// Last line of defense: TomLens never acts on the platform, so a reply that
/// claims it placed, cancelled or clicked something is replaced.
nonisolated enum TutorResponseSafetyFilter {
    static let replacementText = "I can't place or change orders. I only watch your chart; you decide and click."

    private static let actionClaimPattern = #"(?i)\bI(?:'ve| have|'ll| will)?\s+(?:just\s+)?(?:placed|place|submitted|submit|entered|cancel(?:l)?ed|cancel|modified|moved|flattened|clicked|click|bought|sold)\b[^.]*\b(?:order|orders|position|trade|stop|target|button|bracket|contracts?|micros?)\b"#

    static func filtered(_ spokenText: String) -> String {
        spokenText.range(of: actionClaimPattern, options: .regularExpression) == nil ? spokenText : replacementText
    }
}
