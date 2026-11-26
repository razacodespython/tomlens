//
//  TomRelayTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import TomLens

struct TomRelayTests {

    private func ntfyLine(message: String) -> String {
        let envelope: [String: Any] = ["event": "message", "topic": "topic-fixture", "message": message]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        return String(decoding: data, as: UTF8.self)
    }

    private func snapshot(frames: [TomRelayFrame] = [], transcript: [TomRelayTranscriptLine] = []) -> TomRelaySessionSnapshot {
        TomRelaySessionSnapshot(
            sessionIdentifier: "20261126-224005",
            startedAt: Date(timeIntervalSince1970: 1_795_704_005),
            endedAt: Date(timeIntervalSince1970: 1_795_705_205),
            appVersion: "0.1.6",
            pickedWindowApplicationName: "Tradovate",
            pickedWindowTitle: "MNQ",
            transcript: transcript,
            modelReplies: [],
            ruleFlags: [],
            callsUsed: 2,
            trades: [],
            account: TomStatedAccount(),
            frames: frames,
            summary: "No trade was read."
        )
    }

    @Test func hongKongTimestampsUseTheSessionOffset() {
        let stamp = TomRelayClock.hongKongTimestamp(for: Date(timeIntervalSince1970: 1_795_704_005))
        #expect(stamp == "2026-11-26T22:40:05+08:00")
    }

    @Test func allowlistKeepsChatGPTNtfyAndOneWebhookHost() {
        let responses = URL(string: "https://api.openai.com/v1/responses")!
        let auth = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
        let usage = URL(string: "https://chatgpt.com/settings/usage")!
        let ntfy = URL(string: "https://ntfy.sh/example-topic/json?since=10m")!
        let webhook = URL(string: "https://hooks.example.com/tom")!
        let otherPathOnWebhook = URL(string: "https://hooks.example.com/elsewhere")!
        let stranger = URL(string: "https://evil.example/hook")!
        let insecure = URL(string: "http://hooks.example.com/tom")!
        #expect(TomNetworkAllowlist.isAllowed(responses, configuredWebhookURL: nil))
        #expect(TomNetworkAllowlist.isAllowed(auth, configuredWebhookURL: nil))
        #expect(TomNetworkAllowlist.isAllowed(usage, configuredWebhookURL: nil))
        #expect(TomNetworkAllowlist.isAllowed(ntfy, configuredWebhookURL: nil))
        #expect(!TomNetworkAllowlist.isAllowed(webhook, configuredWebhookURL: nil))
        #expect(TomNetworkAllowlist.isAllowed(webhook, configuredWebhookURL: webhook))
        #expect(TomNetworkAllowlist.isAllowed(otherPathOnWebhook, configuredWebhookURL: webhook))
        #expect(!TomNetworkAllowlist.isAllowed(stranger, configuredWebhookURL: webhook))
        #expect(!TomNetworkAllowlist.isAllowed(insecure, configuredWebhookURL: webhook))
        #expect(TomNetworkAllowlist.normalizedWebhookURL("") == nil)
        #expect(TomNetworkAllowlist.normalizedWebhookURL("http://hooks.example.com/tom") == nil)
        #expect(TomNetworkAllowlist.normalizedWebhookURL("https://user:secret@hooks.example.com/tom") == nil)
        #expect(TomNetworkAllowlist.normalizedWebhookURL("https://hooks.example.com/tom") != nil)
    }

    @Test func ntfyStreamURLIsOneTopicOnNtfy() {
        #expect(TomNetworkAllowlist.ntfyJSONStreamURL(topic: "bad/topic") == nil)
        #expect(TomNetworkAllowlist.ntfyJSONStreamURL(topic: "short") == nil)
        #expect(TomNetworkAllowlist.ntfyJSONStreamURL(topic: "has.dot.here") == nil)
        let url = TomNetworkAllowlist.ntfyJSONStreamURL(topic: "tomlens-exampletopic")
        #expect(url?.scheme == "https")
        #expect(url?.host == "ntfy.sh")
        #expect(url?.path == "/tomlens-exampletopic/json")
        #expect(url?.query?.contains("since=10m") == true)
    }

    @Test func capsBlockTheSeventhAskAndAQuickRepeat() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(TomRelayCapsPolicy.askBlock(
            isSwitchedOn: false, hasWebhookURL: true, hasWebhookKey: true,
            asksAlreadySent: 0, lastAskAt: nil, question: "am I tilting?", now: now
        ) == .switchedOff)
        #expect(TomRelayCapsPolicy.askBlock(
            isSwitchedOn: true, hasWebhookURL: false, hasWebhookKey: true,
            asksAlreadySent: 0, lastAskAt: nil, question: "am I tilting?", now: now
        ) == .missingWebhookURL)
        #expect(TomRelayCapsPolicy.askBlock(
            isSwitchedOn: true, hasWebhookURL: true, hasWebhookKey: false,
            asksAlreadySent: 0, lastAskAt: nil, question: "am I tilting?", now: now
        ) == .missingWebhookKey)
        #expect(TomRelayCapsPolicy.askBlock(
            isSwitchedOn: true, hasWebhookURL: true, hasWebhookKey: true,
            asksAlreadySent: 6, lastAskAt: nil, question: "am I tilting?", now: now
        ) == .askCapReached)
        #expect(TomRelayCapsPolicy.askBlock(
            isSwitchedOn: true, hasWebhookURL: true, hasWebhookKey: true,
            asksAlreadySent: 1, lastAskAt: now.addingTimeInterval(-30), question: "am I tilting?", now: now
        ) == .tooSoon(secondsRemaining: 150))
        #expect(TomRelayCapsPolicy.askBlock(
            isSwitchedOn: true, hasWebhookURL: true, hasWebhookKey: true,
            asksAlreadySent: 1, lastAskAt: now.addingTimeInterval(-180), question: "am I tilting?", now: now
        ) == nil)
        #expect(TomRelayCapsPolicy.askBlock(
            isSwitchedOn: true, hasWebhookURL: true, hasWebhookKey: true,
            asksAlreadySent: 0, lastAskAt: nil, question: "   ", now: now
        ) == .emptyQuestion)
        #expect(TomRelayCaps.shouldSendAutomaticSessionEnd(postsAlreadySent: 0))
        #expect(!TomRelayCaps.shouldSendAutomaticSessionEnd(postsAlreadySent: 1))
        #expect(TomRelayCaps.shouldRetry(httpStatus: 429))
        #expect(TomRelayCaps.shouldRetry(httpStatus: 503))
        #expect(!TomRelayCaps.shouldRetry(httpStatus: 401))
        #expect(TomRelayCaps.retryDelaySeconds(afterFailedAttempt: 0) == 2)
        #expect(TomRelayCaps.retryDelaySeconds(afterFailedAttempt: 3) == nil)
    }

    @Test func voicePrefixAsksTomAndLeavesOtherSpeechAlone() {
        #expect(TomAskPolicy.question(fromSpokenTranscript: "Ask Tom, am I tilting?") == "am I tilting?")
        #expect(TomAskPolicy.question(fromSpokenTranscript: "ask tom") == "Review this session so far.")
        #expect(TomAskPolicy.question(fromSpokenTranscript: "is this a fork?") == nil)
        #expect(TomAskPolicy.question(fromSpokenTranscript: "ask tomorrow about the open") == nil)
    }

    @Test func observationsKeepLabeledValuesAndDropTheRest() {
        let parsed = TomObservationParser.parse(jsonText: """
        {"trades":[
          {"side":{"value":"long","source":"raza_said","confidence":0.9},"contracts":{"value":1,"source":"screen_read","confidence":0.5},"entry":"21050"},
          {"side":{"value":"short","source":"guessed","confidence":1}},
          {"pnl":{"value":true,"source":"screen_read","confidence":1}}
        ],"account":{"end_balance":{"value":51000,"source":"screen_read","confidence":0.4},"start_balance":null},"rule_flags":["late entry",""]}
        """)
        #expect(parsed.trades.count == 1)
        #expect(parsed.trades[0].side == TomStatedValue(value: .text("long"), source: "raza_said", confidence: 0.9))
        #expect(parsed.trades[0].contracts == TomStatedValue(value: .number(1), source: "screen_read", confidence: 0.5))
        #expect(parsed.trades[0].entry == nil)
        #expect(parsed.account.endBalance == TomStatedValue(value: .number(51000), source: "screen_read", confidence: 0.4))
        #expect(parsed.account.startBalance == nil)
        #expect(parsed.ruleFlags == ["late entry"])

        var session = TomSessionObservations()
        session.merge(parsed)
        session.merge(TomParsedObservation(trades: [], account: TomStatedAccount(), ruleFlags: []))
        #expect(session.trades.count == 1)
        #expect(session.account.endBalance != nil)
    }

    @Test func emptyObservationsStayNullInThePayload() throws {
        let data = try #require(TomRelayPayloadBuilder.sessionEndData(from: snapshot()))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["event"] as? String == "session_end")
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["mode"] as? String == "live")
        #expect(object["app_version"] as? String == "0.1.6")
        #expect(object["calls_used"] as? Int == 2)
        #expect(object["trades"] is NSNull)
        #expect(object["account"] is NSNull)
        #expect(object["started_at"] as? String == "2026-11-26T22:40:05+08:00")
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("ntfy"))
        #expect(!text.contains("\"topic\""))
        let keys = Set(object.keys)
        #expect(!keys.contains("reply_nonce"))
    }

    @Test func askPayloadCarriesTheNonceAndNoFrames() throws {
        let data = try #require(TomRelayPayloadBuilder.askData(from: snapshot(), question: "am I tilting?", replyNonce: "nonce-1"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["event"] as? String == "ask_tom")
        #expect(object["question"] as? String == "am I tilting?")
        #expect(object["reply_nonce"] as? String == "nonce-1")
        #expect(object["frames"] == nil)
    }

    @Test func trimDropsFramesBeforeTranscript() throws {
        let huge = Data(repeating: 0xAB, count: 2_000_000)
        let frames = (0..<3).map { index in
            TomRelayFrame(
                id: UUID(),
                capturedAt: Date(timeIntervalSince1970: Double(index)),
                reason: TomRelayFrameReason.speech,
                jpegData: huge
            )
        }
        let transcript = [
            TomRelayTranscriptLine(timestamp: Date(timeIntervalSince1970: 1), text: "OLDEST"),
            TomRelayTranscriptLine(timestamp: Date(timeIntervalSince1970: 2), text: "KEEP-THIS-LINE"),
        ]
        let data = try #require(TomRelayPayloadBuilder.sessionEndData(from: snapshot(frames: frames, transcript: transcript)))
        #expect(data.count <= TomRelayCaps.maximumPayloadBytes)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keptFrames = try #require(object["frames"] as? [Any])
        #expect(keptFrames.count < 3)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("KEEP-THIS-LINE"))
    }

    @Test func trimDropsOldestTranscriptAfterFramesAreGone() throws {
        let lines = (0..<80).map { index in
            TomRelayTranscriptLine(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                text: index == 0 ? "OLDEST" : (index == 79 ? "NEWEST" : String(repeating: "x", count: 80_000))
            )
        }
        let data = try #require(TomRelayPayloadBuilder.dataFittingBudget(
            TomRelayPayloadBuilder.sessionEndObject(from: snapshot(transcript: lines)),
            maximumBytes: TomRelayCaps.maximumPayloadBytes
        ))
        #expect(data.count <= TomRelayCaps.maximumPayloadBytes)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("NEWEST"))
        #expect(!text.contains("OLDEST"))
    }

    @Test func frameSelectionKeepsNewestOfEachReasonWithinSix() {
        let frames = [
            TomRelayFrame(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, capturedAt: Date(timeIntervalSince1970: 1), reason: "bar_close", jpegData: Data([1])),
            TomRelayFrame(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, capturedAt: Date(timeIntervalSince1970: 2), reason: "speech", jpegData: Data([2])),
            TomRelayFrame(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, capturedAt: Date(timeIntervalSince1970: 3), reason: "bar_close", jpegData: Data([3])),
            TomRelayFrame(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, capturedAt: Date(timeIntervalSince1970: 4), reason: "trade", jpegData: Data([4])),
            TomRelayFrame(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, capturedAt: Date(timeIntervalSince1970: 5), reason: "nope", jpegData: Data([5])),
        ]
        let chosen = TomRelayPayloadBuilder.framesForPayload(frames)
        #expect(chosen.map { [UInt8]($0.jpegData) } == [[1], [2], [3], [4]])
        #expect(!chosen.contains { $0.reason == "nope" })

        let manySpeechFrames = (0..<8).map { index in
            TomRelayFrame(
                id: UUID(),
                capturedAt: Date(timeIntervalSince1970: Double(index)),
                reason: TomRelayFrameReason.speech,
                jpegData: Data([UInt8(index)])
            )
        }
        let capped = TomRelayPayloadBuilder.framesForPayload(manySpeechFrames)
        #expect(capped.count == 6)
        #expect(capped.map { [UInt8]($0.jpegData) } == [[2], [3], [4], [5], [6], [7]])
    }

    @Test func signatureMatchesTheKnownVectorAndSignsTheRawBody() {
        let emptyHash = TomRelaySignature.hex(TomRelaySignature.sha256(Data()))
        #expect(emptyHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let message = Data("The quick brown fox jumps over the lazy dog".utf8)
        let digest = TomRelaySignature.hex(TomRelaySignature.hmacSHA256(key: Data("key".utf8), message: message))
        #expect(digest == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        let body = Data("{\"event\":\"ask_tom\"}".utf8)
        let headers = TomRelayPayloadBuilder.authorizedHeaders(body: body, senderKey: "test-key")
        #expect(headers["Authorization"] == "Bearer test-key")
        #expect(headers["X-Hub-Signature-256"] == TomRelaySignature.hubSignature256(body: body, keyUTF8: "test-key"))
        #expect(headers["Content-Type"] == "application/json")
        let otherBody = Data("{\"event\":\"session_end\"}".utf8)
        #expect(TomRelayPayloadBuilder.authorizedHeaders(body: otherBody, senderKey: "test-key")["X-Hub-Signature-256"]
                != headers["X-Hub-Signature-256"])
    }

    @Test func nonceIsSingleUseAndEverythingElseIsCounted() {
        let ledger = TomReplyNonceLedger()
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        ledger.issue(nonce: "nonce-a", at: issuedAt)
        let keepalive = TomNtfyMessageParser.classify(#"{"id":"1","event":"keepalive","topic":"topic-fixture"}"#)
        #expect(ledger.decide(keepalive, at: issuedAt.addingTimeInterval(5)) == .ignored)
        #expect(ledger.discardedReplyCount == 0)

        let wrong = TomNtfyMessageParser.classify(ntfyLine(message: #"{"nonce":"other","text":"hi","balance":99999}"#))
        #expect(ledger.decide(wrong, at: issuedAt.addingTimeInterval(6)) == .discarded)

        let matching = TomNtfyMessageParser.classify(ntfyLine(
            message: #"{"nonce":"nonce-a","text":"Wait for the close.","rule_tag":"fork","pnl":12}"#
        ))
        #expect(ledger.decide(matching, at: issuedAt.addingTimeInterval(7)) == .accepted(text: "Wait for the close.", ruleTag: "fork"))
        #expect(ledger.decide(matching, at: issuedAt.addingTimeInterval(8)) == .discarded)

        ledger.issue(nonce: "nonce-b", at: issuedAt)
        let expired = TomNtfyMessageParser.classify(#"{"nonce":"nonce-b","text":"too late"}"#)
        let tenMinutesLater = issuedAt.addingTimeInterval(TomRelayCaps.replyNonceLifetimeSeconds)
        #expect(ledger.decide(expired, at: tenMinutesLater) == .discarded)

        let malformed = TomNtfyMessageParser.classify("not json")
        #expect(ledger.decide(malformed, at: issuedAt) == .discarded)
        #expect(ledger.discardedReplyCount == 4)

        let longText = String(repeating: "a", count: 800)
        let clipped = TomNtfyMessageParser.classify("{\"nonce\":\"n\",\"text\":\"\(longText)\"}")
        guard case .reply(_, let text, _) = clipped else {
            Issue.record("expected a reply")
            return
        }
        #expect(text.count == TomRelayCaps.maximumReplyCharacters)
    }

    @Test func payloadFileIsTheSessionCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tomlens-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try #require(TomRelayPayloadBuilder.sessionEndData(from: snapshot()))
        try TomRelayPayloadBuilder.write(data, to: root)
        let saved = try Data(contentsOf: root.appendingPathComponent("tom-payload.json"))
        #expect(saved == data)
    }

    @Test func rotatedTopicIsASinglePathSegment() {
        let topic = TomRelaySettingsStore.rotatedTopic(randomBytes: [UInt8](repeating: 7, count: 16))
        #expect(TomNetworkAllowlist.isAcceptableNtfyTopic(topic))
        #expect(topic.hasPrefix("tomlens-"))
        #expect(!topic.contains("/"))
        #expect(topic != TomRelaySettingsStore.rotatedTopic(randomBytes: [UInt8](repeating: 8, count: 16)))
        let stored = TomRelaySettingsStore.topic(stored: "tomlens-manualtopic")
        #expect(stored == "tomlens-manualtopic")
        let fallback = TomRelaySettingsStore.topic(stored: "bad topic")
        #expect(TomNetworkAllowlist.isAcceptableNtfyTopic(fallback))
        #expect(fallback != "bad topic")
    }

    @Test func statusCopyMatchesTheWindow() {
        #expect(TomRelayStatusPresentation.tomIsThinkingLabel == "Tom is thinking…")
        #expect(TomRelayStatusPresentation.tomReviewLabel == "Tom (review)")
        #expect(TomRelayStatusPresentation.resendButtonTitle == "Resend to Tom")
        #expect(TomRelayStatusPresentation.askButtonTitle == "Ask Tom")
        #expect(TomRelayStatusPresentation.maskedSecret == "••••••••")
        #expect(TomRelayStatusPresentation.rotateTopicHelp.contains("tell Tom the new topic"))
        #expect(TomRelayStatusPresentation.rotateTopicHelp.contains("journal"))
        #expect(TomRelayStatusPresentation.asksRemainingLabel(asksUsed: 2) == "4 of 6 asks left this session")
        #expect(TomRelayStatusPresentation.askBlockedMessage(.missingWebhookURL) == "No webhook URL, so nothing was sent.")
        let issued = Date(timeIntervalSince1970: 1_000)
        #expect(TomRelayStatusPresentation.isTomThinking(pendingAskIssuedAt: [issued], now: issued.addingTimeInterval(30)))
        #expect(!TomRelayStatusPresentation.isTomThinking(pendingAskIssuedAt: [issued], now: issued.addingTimeInterval(600)))
    }
}
