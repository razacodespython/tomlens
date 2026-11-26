//
//  TomRelaySettings.swift
//  leanring-buddy
//
//  Webhook URL and reply-topic settings, plus the words the status window
//  shows. The sender key is not here: it lives in the Keychain. The topic
//  is masked in the window and must never be written to the journal or a log.
//

import Foundation

nonisolated enum TomRelaySettingsStore {
    static let webhookURLDefaultsKey = "TomLensWebhookURL"
    static let ntfyTopicDefaultsKey = "TomLensNtfyTopic"
    static let webhookKeyAccount = "tom-webhook-sender-key"

    /// Prefill for the masked topic field. Raza already gave this to Tom.
    /// After Rotate, he tells Tom the new one himself.
    static let prefilledReplyTopic = "tomlens-x1yZWm8FiyydyCkXxhUMqMPL"

    static func topic(stored: String?) -> String {
        let trimmedTopic = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard TomNetworkAllowlist.isAcceptableNtfyTopic(trimmedTopic) else { return prefilledReplyTopic }
        return trimmedTopic
    }

    /// 16 random bytes become a new topic. The caller supplies the bytes.
    static func rotatedTopic(randomBytes: [UInt8]) -> String {
        let prefixBytes = Array(randomBytes.prefix(16))
        let paddedBytes = prefixBytes.count == 16 ? prefixBytes : prefixBytes + Array(repeating: 0, count: 16 - prefixBytes.count)
        let encoded = Data(paddedBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "tomlens-\(encoded)"
    }
}

nonisolated enum TomRelayStatusPresentation {
    static let tomIsThinkingLabel = "Tom is thinking…"
    static let tomReviewLabel = "Tom (review)"
    static let askButtonTitle = "Ask Tom"
    static let resendButtonTitle = "Resend to Tom"
    static let maskedSecret = "••••••••"
    static let rotateTopicHelp = "After you rotate the reply topic, tell Tom the new topic. TomLens does not write it to the log or the journal."
    static let advisoryNote = "Tom is advisory and has no in-trade role. ChatGPT still answers while you hold the hotkey."
    static let emptyWebhookNote = "Leave the webhook URL empty and TomLens will not post. The app keeps running."
    static let webhookKeyCaptionStored = "Key is in the Keychain."
    static let webhookKeyCaptionEmpty = "Paste the sender key from Tom's Routines panel. It stays in the Keychain."

    static func asksRemainingLabel(asksUsed: Int) -> String {
        let asksRemaining = max(0, TomRelayCaps.maximumAsksPerSession - asksUsed)
        return "\(asksRemaining) of \(TomRelayCaps.maximumAsksPerSession) asks left this session"
    }

    static func ignoredRepliesLabel(count: Int) -> String {
        "Ignored replies: \(count)"
    }

    static func askBlockedMessage(_ block: TomAskBlock) -> String {
        switch block {
        case .switchedOff:
            return "Switch TomLens on before asking Tom."
        case .missingWebhookURL:
            return "No webhook URL, so nothing was sent."
        case .missingWebhookKey:
            return "No webhook key in the Keychain, so nothing was sent."
        case .askCapReached:
            return "6 asks already used this session."
        case .tooSoon(let secondsRemaining):
            return "Wait \(secondsRemaining)s before the next ask."
        case .emptyQuestion:
            return "Type a question for Tom."
        }
    }

    static func isTomThinking(pendingAskIssuedAt: [Date], now: Date) -> Bool {
        pendingAskIssuedAt.contains { now.timeIntervalSince($0) < TomRelayCaps.replyNonceLifetimeSeconds }
    }
}
