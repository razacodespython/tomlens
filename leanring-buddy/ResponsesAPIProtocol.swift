//
//  ResponsesAPIProtocol.swift
//  leanring-buddy
//
//  Pure helpers for OpenAI's Responses API as used with ChatGPT plan usage:
//  request bodies (always store:false, stream:true; instructions, no system
//  items, no unsupported fields), the server-sent-event stream parser, error
//  classification, and the model catalog. CompanionBrain does the I/O.
//

import Foundation

nonisolated struct ResponsesInputImage: Equatable {
    let jpegData: Data
    let label: String
}

nonisolated struct ResponsesConversationTurn: Equatable {
    let userText: String
    let assistantText: String
}

nonisolated enum ResponsesRequestBuilder {
    /// Fields the plan-usage route rejects; never sent.
    static let unsupportedTopLevelFields: Set<String> = [
        "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata",
        "moderation", "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier",
        "temperature", "top_logprobs", "top_p", "truncation", "user", "previous_response_id",
    ]

    static func requestBody(
        model: String,
        instructions: String,
        conversationHistory: [ResponsesConversationTurn],
        images: [ResponsesInputImage],
        userPrompt: String
    ) -> [String: Any] {
        var inputItems: [[String: Any]] = []
        for turn in conversationHistory {
            inputItems.append(["role": "user", "content": [["type": "input_text", "text": turn.userText]]])
            inputItems.append(["role": "assistant", "content": [["type": "output_text", "text": turn.assistantText]]])
        }
        var currentContent: [[String: Any]] = []
        for image in images {
            currentContent.append(["type": "input_text", "text": image.label])
            currentContent.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(image.jpegData.base64EncodedString())",
            ])
        }
        currentContent.append(["type": "input_text", "text": userPrompt])
        inputItems.append(["role": "user", "content": currentContent])

        return [
            "model": model,
            "instructions": instructions,
            "input": inputItems,
            "store": false,
            "stream": true,
        ]
    }

    static func requestBodyData(_ requestBody: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: requestBody, options: [.sortedKeys])
    }
}

/// Incremental parser for the Responses API SSE stream.
nonisolated struct ResponsesStreamParser {
    enum StreamEvent: Equatable {
        case textDelta(String)
        case completed(fullText: String?)
        case failed(code: String?, message: String?)
        case incomplete(reason: String?)
        case ignored
    }

    private var pendingDataLines: [String] = []

    /// Feed one line (without trailing newline). Returns an event when a
    /// blank line terminates an SSE event.
    mutating func consume(line rawLine: String) -> StreamEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            return flushPendingEvent()
        }
        if line.hasPrefix("data:") {
            var dataPayload = String(line.dropFirst(5))
            if dataPayload.hasPrefix(" ") { dataPayload.removeFirst() }
            pendingDataLines.append(dataPayload)
        }
        // event:, id:, retry: and comments are not needed: every data payload carries its type.
        return nil
    }

    /// Call when the byte stream ends, to flush a final unterminated event.
    mutating func finish() -> StreamEvent? {
        flushPendingEvent()
    }

    private mutating func flushPendingEvent() -> StreamEvent? {
        guard !pendingDataLines.isEmpty else { return nil }
        let payload = pendingDataLines.joined(separator: "\n")
        pendingDataLines.removeAll()
        return Self.event(fromDataPayload: payload)
    }

    static func event(fromDataPayload payload: String) -> StreamEvent {
        guard payload != "[DONE]",
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let eventType = json["type"] as? String else {
            return .ignored
        }
        let response = json["response"] as? [String: Any]
        switch eventType {
        case "response.output_text.delta":
            return .textDelta(json["delta"] as? String ?? "")
        case "response.completed":
            return .completed(fullText: response.flatMap(outputText(fromResponse:)))
        case "response.failed":
            let error = response?["error"] as? [String: Any]
            return .failed(code: error?["code"] as? String, message: error?["message"] as? String)
        case "response.incomplete":
            let details = response?["incomplete_details"] as? [String: Any]
            return .incomplete(reason: details?["reason"] as? String)
        case "error":
            let nestedError = json["error"] as? [String: Any]
            return .failed(
                code: (json["code"] as? String) ?? (nestedError?["code"] as? String),
                message: (json["message"] as? String) ?? (nestedError?["message"] as? String)
            )
        default:
            return .ignored
        }
    }

    private static func outputText(fromResponse response: [String: Any]) -> String? {
        guard let outputItems = response["output"] as? [[String: Any]] else { return nil }
        let texts = outputItems
            .compactMap { $0["content"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { ($0["type"] as? String) == "output_text" }
            .compactMap { $0["text"] as? String }
        return texts.isEmpty ? nil : texts.joined()
    }
}

nonisolated enum ResponsesAPIError: LocalizedError, Equatable {
    /// 429 usage limit: pause plan usage; never fall back to paid credits.
    case usageLimitReached
    case notEligible
    case temporarilyUnavailable
    case unsupportedCapability(String?)
    case signInRejected
    case streamFailed(String)
    case streamEndedWithoutCompletion
    case callCapReached(retryAfterSeconds: Int)
    case requestFailed(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .usageLimitReached:
            return "You've hit your ChatGPT usage limit, so I'm pausing. Check usage in ChatGPT settings."
        case .notEligible:
            return "ChatGPT plan usage isn't available for this account."
        case .temporarilyUnavailable:
            return "ChatGPT is temporarily unavailable. Try again in a minute."
        case .unsupportedCapability:
            return "ChatGPT rejected part of my request."
        case .signInRejected:
            return "ChatGPT didn't accept the sign-in. Please sign in again."
        case .streamFailed:
            return "ChatGPT's reply failed partway through."
        case .streamEndedWithoutCompletion:
            return "ChatGPT's reply was cut off."
        case .callCapReached(let retryAfterSeconds):
            return "I've hit my hourly call cap. I'll be back in about \(max(1, retryAfterSeconds / 60)) minutes."
        case .requestFailed(let status, _):
            return "ChatGPT request failed with status \(status)."
        }
    }

    /// True for errors that should pause automatic (event-triggered) calls.
    var pausesAutomaticCalls: Bool {
        switch self {
        case .usageLimitReached, .notEligible, .signInRejected, .callCapReached: return true
        default: return false
        }
    }
}

nonisolated enum ResponsesErrorClassifier {
    static func error(forCode code: String?, httpStatus: Int, detail: String) -> ResponsesAPIError {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return .usageLimitReached
        case "subscription_sharing_user_not_eligible", "subscription_sharing_route_not_supported",
             "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context":
            return .notEligible
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            return .temporarilyUnavailable
        case "subscription_sharing_unsupported_capability": return .unsupportedCapability(detail)
        case "subscription_sharing_invalid_user": return .signInRejected
        default: break
        }
        switch httpStatus {
        case 401: return .signInRejected
        case 403: return .notEligible
        case 429: return .usageLimitReached
        case 503: return .temporarilyUnavailable
        default: return .requestFailed(status: httpStatus, detail: detail)
        }
    }

    /// Classifies a non-2xx HTTP response body ({"error":{...}} or {"detail":"..."}).
    static func error(httpStatus: Int, responseBody: Data) -> ResponsesAPIError {
        let json = (try? JSONSerialization.jsonObject(with: responseBody)) as? [String: Any]
        let errorObject = json?["error"] as? [String: Any]
        let code = errorObject?["code"] as? String
        let detail = (errorObject?["param"] as? String)
            ?? (errorObject?["message"] as? String)
            ?? (json?["detail"] as? String)
            ?? ""
        return error(forCode: code, httpStatus: httpStatus, detail: detail)
    }
}

nonisolated struct ChatGPTModelChoice: Equatable, Codable {
    let slug: String
    let displayName: String
}

nonisolated enum ChatGPTModelCatalog {
    static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!

    /// Keeps `visibility == "list"` models in server order.
    static func listedModels(fromResponseBody responseBody: Data) -> [ChatGPTModelChoice] {
        guard let json = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard (model["visibility"] as? String) == "list", let slug = model["slug"] as? String else { return nil }
            return ChatGPTModelChoice(slug: slug, displayName: (model["display_name"] as? String) ?? slug)
        }
    }
}

/// Hard cap on model calls in a sliding one-hour window (default 40/hour).
nonisolated final class ModelCallRateLimiter {
    static let defaultMaximumCallsPerHour = 40
    static let windowSeconds: TimeInterval = 3600

    let maximumCallsPerWindow: Int
    private(set) var callTimestamps: [Date] = []

    init(maximumCallsPerWindow: Int = ModelCallRateLimiter.defaultMaximumCallsPerHour) {
        self.maximumCallsPerWindow = max(1, maximumCallsPerWindow)
    }

    /// Records a call and returns nil when allowed; otherwise returns the
    /// seconds until the oldest call leaves the window.
    func reserveCall(now: Date) -> Int? {
        callTimestamps.removeAll { now.timeIntervalSince($0) >= Self.windowSeconds }
        guard callTimestamps.count < maximumCallsPerWindow else {
            let oldestCall = callTimestamps.min() ?? now
            return Int((Self.windowSeconds - now.timeIntervalSince(oldestCall)).rounded(.up))
        }
        callTimestamps.append(now)
        return nil
    }

    func remainingCalls(now: Date) -> Int {
        maximumCallsPerWindow - callTimestamps.filter { now.timeIntervalSince($0) < Self.windowSeconds }.count
    }
}
