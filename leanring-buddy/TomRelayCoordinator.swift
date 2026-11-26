//
//  TomRelayCoordinator.swift
//  leanring-buddy
//
//  Status-window state for Ask Tom. Posts are scheduled as separate tasks
//  so they never sit on the ChatGPT turn. The sender key is read from the
//  Keychain into the request and is not published, journaled, or printed.
//  The reply topic is masked in the UI and is not written to the journal.
//

import AppKit
import Combine
import Foundation

@MainActor
final class TomRelayCoordinator: ObservableObject {
    @Published var webhookURLString: String {
        didSet {
            UserDefaults.standard.set(webhookURLString, forKey: TomRelaySettingsStore.webhookURLDefaultsKey)
        }
    }
    @Published private(set) var webhookKeyIsStored: Bool
    @Published var ntfyTopic: String {
        didSet {
            guard ntfyTopic != oldValue else { return }
            guard TomNetworkAllowlist.isAcceptableNtfyTopic(ntfyTopic) else {
                ntfyTopic = oldValue
                return
            }
            UserDefaults.standard.set(ntfyTopic, forKey: TomRelaySettingsStore.ntfyTopicDefaultsKey)
            if isSwitchedOn { startListening() }
        }
    }
    @Published private(set) var asksUsedThisSession = 0
    @Published private(set) var lastAskAt: Date?
    @Published private(set) var pendingAskIssuedAt: [Date] = []
    @Published private(set) var discardedReplyCount = 0
    @Published private(set) var tomReviewText: String?
    @Published private(set) var tomReviewRuleTag: String?
    @Published private(set) var deliveryStatusMessage = ""
    @Published private(set) var canResendSessionPayload = false
    @Published private(set) var isSwitchedOn = false

    var onAcceptedReview: ((String, String?) -> Void)?

    private let replyListener = TomReplyListener()
    private let nonceLedger = TomReplyNonceLedger()
    private var lastPayloadData: Data?
    private var sessionEndPostsSent = 0

    init() {
        let storedTopic = UserDefaults.standard.string(forKey: TomRelaySettingsStore.ntfyTopicDefaultsKey)
        let resolvedTopic = TomRelaySettingsStore.topic(stored: storedTopic)
        ntfyTopic = resolvedTopic
        if storedTopic != resolvedTopic {
            UserDefaults.standard.set(resolvedTopic, forKey: TomRelaySettingsStore.ntfyTopicDefaultsKey)
        }
        webhookURLString = UserDefaults.standard.string(forKey: TomRelaySettingsStore.webhookURLDefaultsKey) ?? ""
        webhookKeyIsStored = TomLensKeychainStore.load(account: TomRelaySettingsStore.webhookKeyAccount) != nil
    }

    func setSwitchedOn(_ switchedOn: Bool) {
        isSwitchedOn = switchedOn
        if switchedOn {
            beginSession()
            startListening()
        } else {
            stopListening()
            pendingAskIssuedAt = []
        }
    }

    func beginSession() {
        asksUsedThisSession = 0
        lastAskAt = nil
        pendingAskIssuedAt = []
        discardedReplyCount = 0
        nonceLedger.reset()
        sessionEndPostsSent = 0
        tomReviewText = nil
        tomReviewRuleTag = nil
    }

    func saveWebhookKey(_ rawKey: String) {
        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        TomLensKeychainStore.save(Data(trimmedKey.utf8), account: TomRelaySettingsStore.webhookKeyAccount)
        webhookKeyIsStored = true
    }

    func removeWebhookKey() {
        TomLensKeychainStore.delete(account: TomRelaySettingsStore.webhookKeyAccount)
        webhookKeyIsStored = false
    }

    func copyReplyTopicToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ntfyTopic, forType: .string)
    }

    func rotateReplyTopic() {
        var randomBytes = [UInt8](repeating: 0, count: 16)
        for index in randomBytes.indices {
            randomBytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        ntfyTopic = TomRelaySettingsStore.rotatedTopic(randomBytes: randomBytes)
        deliveryStatusMessage = "New reply topic ready. Copy it and tell Tom."
    }

    func askTom(question: String, snapshot: TomRelaySessionSnapshot) {
        let now = Date()
        if let block = TomRelayCapsPolicy.askBlock(
            isSwitchedOn: isSwitchedOn,
            hasWebhookURL: TomNetworkAllowlist.normalizedWebhookURL(webhookURLString) != nil,
            hasWebhookKey: webhookKeyIsStored,
            asksAlreadySent: asksUsedThisSession,
            lastAskAt: lastAskAt,
            question: question,
            now: now
        ) {
            deliveryStatusMessage = TomRelayStatusPresentation.askBlockedMessage(block)
            return
        }
        guard let webhookURL = TomNetworkAllowlist.normalizedWebhookURL(webhookURLString) else {
            deliveryStatusMessage = TomRelayStatusPresentation.askBlockedMessage(.missingWebhookURL)
            return
        }
        let replyNonce = UUID().uuidString
        nonceLedger.issue(nonce: replyNonce, at: now)
        asksUsedThisSession += 1
        lastAskAt = now
        pendingAskIssuedAt = nonceLedger.pendingAsks.map(\.issuedAt)
        deliveryStatusMessage = TomRelayStatusPresentation.tomIsThinkingLabel
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            guard let body = TomRelayPayloadBuilder.askData(from: snapshot, question: trimmedQuestion, replyNonce: replyNonce) else {
                self.deliveryStatusMessage = "Couldn't build the ask."
                return
            }
            await self.post(body: body, webhookURL: webhookURL)
        }
    }

    /// One automatic session_end. The network work runs on a follow-up task.
    func deliverSessionEnd(snapshot: TomRelaySessionSnapshot, sessionDirectory: URL?) {
        guard TomRelayCaps.shouldSendAutomaticSessionEnd(postsAlreadySent: sessionEndPostsSent) else { return }
        sessionEndPostsSent += 1
        Task { @MainActor in
            guard let body = TomRelayPayloadBuilder.sessionEndData(from: snapshot) else {
                self.deliveryStatusMessage = "Couldn't build the session payload."
                return
            }
            self.remember(body, sessionDirectory: sessionDirectory)
            guard let webhookURL = TomNetworkAllowlist.normalizedWebhookURL(self.webhookURLString) else {
                self.deliveryStatusMessage = "Saved the payload. No webhook URL, so nothing was sent."
                return
            }
            guard self.webhookKeyIsStored else {
                self.deliveryStatusMessage = "Saved the payload. No webhook key in the Keychain, so nothing was sent."
                return
            }
            await self.post(body: body, webhookURL: webhookURL)
        }
    }

    func resendLastPayload() {
        guard let body = lastPayloadData else {
            deliveryStatusMessage = "No saved session payload to resend."
            return
        }
        guard let webhookURL = TomNetworkAllowlist.normalizedWebhookURL(webhookURLString) else {
            deliveryStatusMessage = "Saved the payload. No webhook URL, so nothing was sent."
            return
        }
        guard webhookKeyIsStored else {
            deliveryStatusMessage = "Saved the payload. No webhook key in the Keychain, so nothing was sent."
            return
        }
        Task { @MainActor in
            await self.post(body: body, webhookURL: webhookURL)
        }
    }

    func stopListening() {
        replyListener.stop()
    }

    private func startListening() {
        replyListener.start(topic: ntfyTopic) { [weak self] line in
            self?.receive(line)
        }
    }

    private func receive(_ line: String) {
        let kind = TomNtfyMessageParser.classify(line)
        let acceptance = nonceLedger.decide(kind, at: Date())
        pendingAskIssuedAt = nonceLedger.pendingAsks.map(\.issuedAt)
        discardedReplyCount = nonceLedger.discardedReplyCount
        guard case .accepted(let text, let ruleTag) = acceptance else { return }
        tomReviewText = text
        tomReviewRuleTag = ruleTag
        if pendingAskIssuedAt.isEmpty {
            deliveryStatusMessage = TomRelayStatusPresentation.tomReviewLabel
        }
        onAcceptedReview?(text, ruleTag)
    }

    private func remember(_ body: Data, sessionDirectory: URL?) {
        lastPayloadData = body
        canResendSessionPayload = true
        guard let sessionDirectory else { return }
        do {
            try TomRelayPayloadBuilder.write(body, to: sessionDirectory)
        } catch {
            deliveryStatusMessage = "Couldn't save the session payload on this Mac."
        }
    }

    private func post(body: Data, webhookURL: URL) async {
        guard let senderKey = loadSenderKey() else {
            deliveryStatusMessage = "Saved the payload. No webhook key in the Keychain, so nothing was sent."
            return
        }
        let outcome = await TomWebhookClient.post(body: body, webhookURL: webhookURL, senderKey: senderKey)
        if outcome == .posted && TomRelayStatusPresentation.isTomThinking(pendingAskIssuedAt: pendingAskIssuedAt, now: Date()) {
            deliveryStatusMessage = TomRelayStatusPresentation.tomIsThinkingLabel
        } else {
            deliveryStatusMessage = outcome.statusMessage
        }
    }

    private func loadSenderKey() -> String? {
        guard let keyData = TomLensKeychainStore.load(account: TomRelaySettingsStore.webhookKeyAccount) else { return nil }
        let senderKey = String(decoding: keyData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return senderKey.isEmpty ? nil : senderKey
    }
}
