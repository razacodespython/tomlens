//
//  TomRelayProtocol.swift
//  leanring-buddy
//
//  Pure Ask Tom / session_end rules: caps, nonce checks, the webhook JSON,
//  body trimming, and observed trades. No URLSession and no Keychain, so
//  the Linux tests can run it. Values Raza did not say and the model did
//  not read off the picked window stay null. Nothing here is a secret.
//

import Foundation

nonisolated enum TomRelayCaps {
    static let maximumAsksPerSession = 6
    static let minimumSecondsBetweenAsks: TimeInterval = 180
    static let maximumSessionEndPosts = 1
    static let replyNonceLifetimeSeconds: TimeInterval = 600
    static let maximumReplyCharacters = 600
    static let maximumPayloadBytes = 4_800_000
    static let maximumFrames = 6
    static let retryBackoffSeconds: [TimeInterval] = [2, 6, 18]
    static let schemaVersion = 1
    static let liveMode = "live"
    static let payloadFileName = "tom-payload.json"

    static func shouldRetry(httpStatus: Int) -> Bool {
        httpStatus == 408 || httpStatus == 429 || (500...599).contains(httpStatus)
    }

    /// Delay before the next try, or nil when the attempts are used up.
    /// `failedAttemptIndex` 0 is the first failure.
    static func retryDelaySeconds(afterFailedAttempt failedAttemptIndex: Int) -> TimeInterval? {
        guard failedAttemptIndex >= 0, failedAttemptIndex < retryBackoffSeconds.count else { return nil }
        return retryBackoffSeconds[failedAttemptIndex]
    }

    static func shouldSendAutomaticSessionEnd(postsAlreadySent: Int) -> Bool {
        postsAlreadySent < maximumSessionEndPosts
    }
}

nonisolated enum TomAskBlock: Equatable {
    case switchedOff
    case missingWebhookURL
    case missingWebhookKey
    case askCapReached
    case tooSoon(secondsRemaining: Int)
    case emptyQuestion
}

nonisolated enum TomRelayCapsPolicy {
    static func askBlock(
        isSwitchedOn: Bool,
        hasWebhookURL: Bool,
        hasWebhookKey: Bool,
        asksAlreadySent: Int,
        lastAskAt: Date?,
        question: String,
        now: Date
    ) -> TomAskBlock? {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuestion.isEmpty { return .emptyQuestion }
        if !isSwitchedOn { return .switchedOff }
        if !hasWebhookURL { return .missingWebhookURL }
        if !hasWebhookKey { return .missingWebhookKey }
        if asksAlreadySent >= TomRelayCaps.maximumAsksPerSession { return .askCapReached }
        if let lastAskAt {
            let elapsedSeconds = now.timeIntervalSince(lastAskAt)
            if elapsedSeconds < TomRelayCaps.minimumSecondsBetweenAsks {
                let secondsRemaining = Int(ceil(TomRelayCaps.minimumSecondsBetweenAsks - elapsedSeconds))
                return .tooSoon(secondsRemaining: max(1, secondsRemaining))
            }
        }
        return nil
    }
}

/// "ask tom …" at the start of a push-to-talk utterance. The rest is the question.
nonisolated enum TomAskPolicy {
    static func question(fromSpokenTranscript transcript: String) -> String? {
        let pattern = #"(?i)^\s*(?:hey\s+)?ask\s+tom\b[\s,:\-]*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let fullRange = NSRange(transcript.startIndex..., in: transcript)
        guard let match = regex.firstMatch(in: transcript, range: fullRange),
              let remainderRange = Range(match.range(at: 1), in: transcript) else { return nil }
        let remainder = transcript[remainderRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? "Review this session so far." : remainder
    }
}

// MARK: - Observed values

nonisolated struct TomStatedValue: Equatable {
    enum Value: Equatable {
        case text(String)
        case number(Double)
    }

    let value: Value
    /// "screen_read" or "raza_said". Anything else is dropped before this exists.
    let source: String
    let confidence: Double

    func jsonObject() -> [String: Any] {
        let jsonValue: Any
        switch value {
        case .text(let text):
            jsonValue = text
        case .number(let number):
            jsonValue = number
        }
        return ["value": jsonValue, "source": source, "confidence": confidence]
    }
}

nonisolated struct TomStatedTrade: Equatable {
    var side: TomStatedValue?
    var contracts: TomStatedValue?
    var entry: TomStatedValue?
    var exit: TomStatedValue?
    var pnl: TomStatedValue?
    var enteredAt: TomStatedValue?
    var exitedAt: TomStatedValue?
    var setupBarClose: TomStatedValue?
    var setupNamedByRaza: TomStatedValue?
    var setupFlaggedByModel: TomStatedValue?

    var hasAnyValue: Bool {
        side != nil || contracts != nil || entry != nil || exit != nil || pnl != nil
            || enteredAt != nil || exitedAt != nil || setupBarClose != nil
            || setupNamedByRaza != nil || setupFlaggedByModel != nil
    }

    func jsonObject() -> [String: Any] {
        [
            "side": TomRelayJSON.stated(side),
            "contracts": TomRelayJSON.stated(contracts),
            "entry": TomRelayJSON.stated(entry),
            "exit": TomRelayJSON.stated(exit),
            "pnl": TomRelayJSON.stated(pnl),
            "entered_at": TomRelayJSON.stated(enteredAt),
            "exited_at": TomRelayJSON.stated(exitedAt),
            "setup_bar_close": TomRelayJSON.stated(setupBarClose),
            "setup_named_by_raza": TomRelayJSON.stated(setupNamedByRaza),
            "setup_flagged_by_model": TomRelayJSON.stated(setupFlaggedByModel),
        ]
    }
}

nonisolated struct TomStatedAccount: Equatable {
    var startBalance: TomStatedValue?
    var endBalance: TomStatedValue?
    var realizedPnlDay: TomStatedValue?

    var hasAnyValue: Bool {
        startBalance != nil || endBalance != nil || realizedPnlDay != nil
    }

    func jsonObject() -> [String: Any] {
        [
            "start_balance": TomRelayJSON.stated(startBalance),
            "end_balance": TomRelayJSON.stated(endBalance),
            "realized_pnl_day": TomRelayJSON.stated(realizedPnlDay),
        ]
    }

    /// A later observation fills or replaces a field only when it actually has a value.
    mutating func merge(from newer: TomStatedAccount) {
        if let startBalance = newer.startBalance { self.startBalance = startBalance }
        if let endBalance = newer.endBalance { self.endBalance = endBalance }
        if let realizedPnlDay = newer.realizedPnlDay { self.realizedPnlDay = realizedPnlDay }
    }
}

nonisolated struct TomParsedObservation: Equatable {
    var trades: [TomStatedTrade]
    var account: TomStatedAccount
    var ruleFlags: [String]
}

nonisolated struct TomSessionObservations: Equatable {
    var trades: [TomStatedTrade] = []
    var account = TomStatedAccount()
    var ruleFlags: [String] = []

    mutating func merge(_ observation: TomParsedObservation) {
        for trade in observation.trades where trade.hasAnyValue && trades.count < 20 {
            trades.append(trade)
        }
        account.merge(from: observation.account)
        for ruleFlag in observation.ruleFlags where !ruleFlags.contains(ruleFlag) && ruleFlags.count < 20 {
            ruleFlags.append(ruleFlag)
        }
    }
}

nonisolated enum TomObservationParser {
    static let allowedSources: Set<String> = ["screen_read", "raza_said"]

    static func parse(jsonText: String) -> TomParsedObservation {
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return TomParsedObservation(trades: [], account: TomStatedAccount(), ruleFlags: [])
        }
        let trades = (object["trades"] as? [Any] ?? []).compactMap(trade(from:))
        let account = account(from: object["account"])
        let ruleFlags = (object["rule_flags"] as? [Any] ?? []).compactMap { rawFlag -> String? in
            guard let flag = rawFlag as? String else { return nil }
            let trimmedFlag = flag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedFlag.isEmpty else { return nil }
            return String(trimmedFlag.prefix(120))
        }
        return TomParsedObservation(trades: trades, account: account, ruleFlags: ruleFlags)
    }

    private static func trade(from rawTrade: Any) -> TomStatedTrade? {
        guard let object = rawTrade as? [String: Any] else { return nil }
        let trade = TomStatedTrade(
            side: statedValue(object["side"]),
            contracts: statedValue(object["contracts"]),
            entry: statedValue(object["entry"]),
            exit: statedValue(object["exit"]),
            pnl: statedValue(object["pnl"]),
            enteredAt: statedValue(object["entered_at"]),
            exitedAt: statedValue(object["exited_at"]),
            setupBarClose: statedValue(object["setup_bar_close"]),
            setupNamedByRaza: statedValue(object["setup_named_by_raza"]),
            setupFlaggedByModel: statedValue(object["setup_flagged_by_model"])
        )
        return trade.hasAnyValue ? trade : nil
    }

    private static func account(from rawAccount: Any?) -> TomStatedAccount {
        guard let object = rawAccount as? [String: Any] else { return TomStatedAccount() }
        return TomStatedAccount(
            startBalance: statedValue(object["start_balance"]),
            endBalance: statedValue(object["end_balance"]),
            realizedPnlDay: statedValue(object["realized_pnl_day"])
        )
    }

    /// A number without a source, or a source we do not recognize, becomes nil.
    static func statedValue(_ rawValue: Any?) -> TomStatedValue? {
        guard let object = rawValue as? [String: Any] else { return nil }
        guard let source = object["source"] as? String, allowedSources.contains(source) else { return nil }
        guard let confidence = jsonNumber(object["confidence"]), confidence >= 0, confidence <= 1 else { return nil }
        if let text = object["value"] as? String {
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return nil }
            return TomStatedValue(value: .text(trimmedText), source: source, confidence: confidence)
        }
        if let number = jsonNumber(object["value"]) {
            return TomStatedValue(value: .number(number), source: source, confidence: confidence)
        }
        return nil
    }

    /// JSON booleans are not measurements. `objCType` distinguishes a real
    /// number from a boolean, including when 0 or 1 bridges as Bool.
    private static func jsonNumber(_ rawValue: Any?) -> Double? {
        guard let number = rawValue as? NSNumber else { return nil }
        let typeCode = String(cString: number.objCType)
        if typeCode == "c" || typeCode == "B" { return nil }
        return number.doubleValue
    }
}

// MARK: - Clock, frames, session snapshot

nonisolated enum TomRelayClock {
    static let hongKongTimeZone = TimeZone(identifier: "Asia/Hong_Kong")!

    static func hongKongTimestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = hongKongTimeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

nonisolated struct TomRelayFrame: Equatable, Identifiable {
    let id: UUID
    let capturedAt: Date
    let reason: String
    let jpegData: Data

    init(id: UUID = UUID(), capturedAt: Date, reason: String, jpegData: Data) {
        self.id = id
        self.capturedAt = capturedAt
        self.reason = reason
        self.jpegData = jpegData
    }
}

nonisolated struct TomRelayTranscriptLine {
    let timestamp: Date
    let text: String
}

nonisolated struct TomRelayModelReply {
    let timestamp: Date
    let text: String
    let drawObjects: [[String: Any]]
}

nonisolated struct TomRelaySessionSnapshot {
    var sessionIdentifier: String
    var startedAt: Date
    var endedAt: Date
    var appVersion: String
    var pickedWindowApplicationName: String?
    var pickedWindowTitle: String?
    var transcript: [TomRelayTranscriptLine]
    var modelReplies: [TomRelayModelReply]
    var ruleFlags: [String]
    var callsUsed: Int
    var trades: [TomStatedTrade]
    var account: TomStatedAccount
    var frames: [TomRelayFrame]
    var summary: String
}

nonisolated enum TomRelayFrameReason {
    static let barClose = "bar_close"
    static let speech = "speech"
    static let trade = "trade"
    static let allowed: Set<String> = [barClose, speech, trade]
}

// MARK: - Nonce ledger

nonisolated enum TomNtfyLineKind: Equatable {
    case ignore
    case malformed
    case reply(nonce: String, text: String, ruleTag: String?)
}

nonisolated enum TomReplyAcceptance: Equatable {
    case ignored
    case discarded
    case accepted(text: String, ruleTag: String?)
}

nonisolated enum TomNtfyMessageParser {
    /// ntfy wraps Tom's JSON in `message`. Keepalive lines are not replies.
    /// Extra fields (balances, P&L, the topic) are dropped.
    static func classify(_ line: String) -> TomNtfyLineKind {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLine.isEmpty { return .ignore }
        guard let data = trimmedLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        if let event = object["event"] as? String {
            if event != "message" { return .ignore }
            if let messageText = object["message"] as? String {
                return replyKind(parsing: messageText)
            }
            if let messageObject = object["message"] as? [String: Any] {
                return replyKind(from: messageObject)
            }
            return .malformed
        }
        return replyKind(from: object)
    }

    private static func replyKind(parsing messageText: String) -> TomNtfyLineKind {
        guard let data = messageText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }
        return replyKind(from: object)
    }

    private static func replyKind(from object: [String: Any]) -> TomNtfyLineKind {
        guard let nonce = object["nonce"] as? String else { return .malformed }
        let trimmedNonce = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNonce.isEmpty, let text = object["text"] as? String else { return .malformed }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return .malformed }
        let clippedText = String(trimmedText.prefix(TomRelayCaps.maximumReplyCharacters))
        let ruleTag = cleanRuleTag(object["rule_tag"] as? String)
        return .reply(nonce: trimmedNonce, text: clippedText, ruleTag: ruleTag)
    }

    private static func cleanRuleTag(_ rawRuleTag: String?) -> String? {
        guard let rawRuleTag else { return nil }
        let trimmedRuleTag = rawRuleTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRuleTag.isEmpty else { return nil }
        return String(trimmedRuleTag.prefix(80))
    }
}

nonisolated final class TomReplyNonceLedger {
    struct PendingAsk: Equatable {
        let nonce: String
        let issuedAt: Date
    }

    private(set) var pendingAsks: [PendingAsk] = []
    private(set) var discardedReplyCount = 0
    private var usedNonces: Set<String> = []

    func issue(nonce: String, at issuedAt: Date) {
        let trimmedNonce = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNonce.isEmpty else { return }
        pendingAsks.append(PendingAsk(nonce: trimmedNonce, issuedAt: issuedAt))
    }

    func decide(_ kind: TomNtfyLineKind, at date: Date) -> TomReplyAcceptance {
        switch kind {
        case .ignore:
            return .ignored
        case .malformed:
            discardedReplyCount += 1
            return .discarded
        case .reply(let nonce, let text, let ruleTag):
            pendingAsks.removeAll { date.timeIntervalSince($0.issuedAt) >= TomRelayCaps.replyNonceLifetimeSeconds }
            guard let pendingIndex = pendingAsks.firstIndex(where: { $0.nonce == nonce }) else {
                discardedReplyCount += 1
                return .discarded
            }
            pendingAsks.remove(at: pendingIndex)
            if usedNonces.contains(nonce) {
                discardedReplyCount += 1
                return .discarded
            }
            usedNonces.insert(nonce)
            return .accepted(text: text, ruleTag: ruleTag)
        }
    }

    func reset() {
        pendingAsks.removeAll()
        discardedReplyCount = 0
        usedNonces.removeAll()
    }
}

// MARK: - Payload

nonisolated enum TomRelayJSON {
    static func stated(_ value: TomStatedValue?) -> Any {
        value?.jsonObject() ?? NSNull()
    }

    static func stringOrNull(_ value: String?) -> Any {
        guard let value, !value.isEmpty else { return NSNull() }
        return value
    }
}

nonisolated enum TomRelayPayloadBuilder {
    static func framesForPayload(_ frames: [TomRelayFrame], maximumCount: Int = TomRelayCaps.maximumFrames) -> [TomRelayFrame] {
        let allowedFrames = frames.filter { TomRelayFrameReason.allowed.contains($0.reason) }
        let chronologicalFrames = allowedFrames.sorted { $0.capturedAt < $1.capturedAt }
        var chosenFrames: [TomRelayFrame] = []
        var chosenIDs: Set<UUID> = []
        for reason in [TomRelayFrameReason.trade, TomRelayFrameReason.speech, TomRelayFrameReason.barClose] {
            guard let newestFrame = chronologicalFrames.last(where: { $0.reason == reason }) else { continue }
            chosenFrames.append(newestFrame)
            chosenIDs.insert(newestFrame.id)
        }
        for frame in chronologicalFrames.reversed() where !chosenIDs.contains(frame.id) {
            if chosenFrames.count >= maximumCount { break }
            chosenFrames.append(frame)
            chosenIDs.insert(frame.id)
        }
        return chosenFrames.sorted { $0.capturedAt < $1.capturedAt }
    }

    static func drawObjects(in responseText: String) -> [[String: Any]] {
        guard let regex = try? NSRegularExpression(pattern: #"<draw>([\s\S]*?)</draw>"#) else { return [] }
        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        guard let match = regex.firstMatch(in: responseText, range: fullRange),
              let payloadRange = Range(match.range(at: 1), in: responseText) else { return [] }
        let payloadText = String(responseText[payloadRange])
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(payloadText.utf8)) else { return [] }
        let rawShapes = (parsed as? [[String: Any]]) ?? ((parsed as? [String: Any])?["shapes"] as? [[String: Any]]) ?? []
        return Array(rawShapes.prefix(8))
    }

    static func sessionEndObject(from snapshot: TomRelaySessionSnapshot) -> [String: Any] {
        var object = sharedObject(from: snapshot, event: "session_end")
        object["frames"] = frameObjects(framesForPayload(snapshot.frames))
        return object
    }

    static func askObject(from snapshot: TomRelaySessionSnapshot, question: String, replyNonce: String) -> [String: Any] {
        var object = sharedObject(from: snapshot, event: "ask_tom")
        object["question"] = question.trimmingCharacters(in: .whitespacesAndNewlines)
        object["reply_nonce"] = replyNonce
        return object
    }

    static func sessionEndData(from snapshot: TomRelaySessionSnapshot) -> Data? {
        dataFittingBudget(sessionEndObject(from: snapshot))
    }

    static func askData(from snapshot: TomRelaySessionSnapshot, question: String, replyNonce: String) -> Data? {
        dataFittingBudget(askObject(from: snapshot, question: question, replyNonce: replyNonce))
    }

    static func write(_ data: Data, to sessionDirectory: URL) throws {
        let payloadURL = sessionDirectory.appendingPathComponent(TomRelayCaps.payloadFileName)
        try data.write(to: payloadURL, options: .atomic)
    }

    static func authorizedHeaders(body: Data, senderKey: String) -> [String: String] {
        [
            "Authorization": "Bearer \(senderKey)",
            "X-Hub-Signature-256": TomRelaySignature.hubSignature256(body: body, keyUTF8: senderKey),
            "Content-Type": "application/json",
        ]
    }

    private static func sharedObject(from snapshot: TomRelaySessionSnapshot, event: String) -> [String: Any] {
        let tradesObject: Any = snapshot.trades.isEmpty
            ? NSNull()
            : snapshot.trades.map { $0.jsonObject() }
        let accountObject: Any = snapshot.account.hasAnyValue ? snapshot.account.jsonObject() : NSNull()
        return [
            "schema_version": TomRelayCaps.schemaVersion,
            "event": event,
            "app_version": snapshot.appVersion,
            "mode": TomRelayCaps.liveMode,
            "session_id": snapshot.sessionIdentifier,
            "started_at": TomRelayClock.hongKongTimestamp(for: snapshot.startedAt),
            "ended_at": TomRelayClock.hongKongTimestamp(for: snapshot.endedAt),
            "picked_window": [
                "app": TomRelayJSON.stringOrNull(snapshot.pickedWindowApplicationName),
                "title": TomRelayJSON.stringOrNull(snapshot.pickedWindowTitle),
            ],
            "transcript": snapshot.transcript.map { line in
                ["ts": TomRelayClock.hongKongTimestamp(for: line.timestamp), "text": line.text]
            },
            "model_replies": snapshot.modelReplies.map { reply in
                [
                    "ts": TomRelayClock.hongKongTimestamp(for: reply.timestamp),
                    "text": reply.text,
                    "draws": reply.drawObjects,
                ]
            },
            "rule_flags": snapshot.ruleFlags,
            "calls_used": snapshot.callsUsed,
            "trades": tradesObject,
            "account": accountObject,
            "summary": snapshot.summary,
        ]
    }

    private static func frameObjects(_ frames: [TomRelayFrame]) -> [[String: Any]] {
        frames.map { frame in
            [
                "ts": TomRelayClock.hongKongTimestamp(for: frame.capturedAt),
                "reason": frame.reason,
                "base64": frame.jpegData.base64EncodedString(),
            ]
        }
    }

    /// Drop oldest frames, then oldest transcript lines, then oldest model replies.
    static func dataFittingBudget(_ object: [String: Any], maximumBytes: Int = TomRelayCaps.maximumPayloadBytes) -> Data? {
        var payload = object
        func encoded() -> Data? {
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                return nil
            }
            return data
        }
        guard var data = encoded() else { return nil }
        func dropOldest(from key: String) -> Bool {
            guard var array = payload[key] as? [Any], !array.isEmpty else { return false }
            array.removeFirst()
            payload[key] = array
            return true
        }
        while data.count > maximumBytes {
            let didShrink = dropOldest(from: "frames") || dropOldest(from: "transcript") || dropOldest(from: "model_replies")
            guard didShrink, let smaller = encoded() else { break }
            data = smaller
        }
        return data.count <= maximumBytes ? data : nil
    }
}
