//
//  PushToTalkUtterancePolicy.swift
//  leanring-buddy
//
//  Pure rules for the push-to-talk loop: how long the mic may stay open,
//  which taps are accidental, which transcripts are worth an AI call, and
//  how replies are cleaned up before Apple text-to-speech reads them.
//

import Foundation

nonisolated enum PushToTalkUtterancePolicy {
    /// Hard cap on one hold. SFSpeechRecognizer stops around one minute, and
    /// a missed key-up must never leave the mic open.
    static let maximumHoldDurationSeconds: TimeInterval = 50
    /// Shorter holds are treated as accidental taps: discarded, no AI call.
    static let minimumHoldDurationSeconds: TimeInterval = 0.3
    /// Spoken replies longer than this are cut at a sentence boundary.
    static let maximumSpokenCharacterCount = 420

    static func isAccidentalTap(holdDurationSeconds: TimeInterval) -> Bool {
        holdDurationSeconds < minimumHoldDurationSeconds
    }

    /// True when the transcript has at least two letters/digits. Filters
    /// empty results and stray noise like "uh" punctuation-only output.
    static func shouldSubmit(transcript: String) -> Bool {
        let meaningfulCharacterCount = transcript.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .count
        return meaningfulCharacterCount >= 2
    }

    /// Strips markup a model may leak (markdown, code fences, leftover tags)
    /// and caps the length so speech stays short.
    static func cleanedTextForSpeech(_ responseText: String) -> String {
        var cleanedText = responseText
        cleanedText = cleanedText.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        cleanedText = cleanedText.replacingOccurrences(of: #"<[^>]{1,40}>"#, with: " ", options: .regularExpression)
        cleanedText = cleanedText.replacingOccurrences(of: #"[*_#`>|]"#, with: "", options: .regularExpression)
        cleanedText = cleanedText.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        cleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleanedText.count > maximumSpokenCharacterCount else { return cleanedText }
        let truncatedText = String(cleanedText.prefix(maximumSpokenCharacterCount))
        if let lastSentenceEnd = truncatedText.lastIndex(where: { ".!?".contains($0) }) {
            return String(truncatedText[...lastSentenceEnd])
        }
        return truncatedText
    }
}
