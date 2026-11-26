//
//  CompanionBrain.swift
//  leanring-buddy
//
//  Single entry point for AI requests: OpenAI's Responses API, paid for by
//  the user's ChatGPT plan via Sign in with ChatGPT. Every request is
//  store:false + stream:true, passes the hard hourly call cap first, and
//  never falls back to paid API credits on its own: a usage-limit error
//  pauses TomLens and links to ChatGPT usage settings instead. The optional
//  API-key path (TomLensAPIKeyFallback) is off by default and is only used
//  when explicitly enabled and no ChatGPT account is signed in.
//

import Foundation

enum CompanionBrainError: LocalizedError {
    case notConfigured
    case noModelSelected

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sign in with ChatGPT in the TomLens menu first."
        case .noModelSelected:
            return "I couldn't load your ChatGPT models yet. Open the TomLens menu and try again."
        }
    }
}

enum CompanionBrain {
    static let responsesEndpoint = URL(string: "https://api.openai.com/v1/responses")!
    /// Model used only with the explicitly enabled API-key fallback.
    static let apiKeyFallbackModel = "gpt-5-mini"

    /// Hard cap shared by push-to-talk and automatic triggers.
    static let callRateLimiter = ModelCallRateLimiter(maximumCallsPerWindow: ModelCallRateLimiter.defaultMaximumCallsPerHour)

    /// Set after a usage-limit error; automatic calls stay paused until the
    /// user asks again (push-to-talk) after the given date.
    private(set) static var planUsagePausedUntil: Date?

    @MainActor
    static func requestResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onRequestBody: (([String: Any]) -> Void)? = nil
    ) async throws -> String {
        let signInService = ChatGPTSignInService.shared
        guard !isPlanUsagePaused(now: Date()) else { throw ResponsesAPIError.usageLimitReached }

        let bearerToken: String
        let model: String
        if signInService.isSignedIn {
            bearerToken = try await signInService.validPlanUsageAccessToken()
            if signInService.selectedModelSlug == nil { await signInService.refreshModelCatalog() }
            guard let selectedModelSlug = signInService.selectedModelSlug else { throw CompanionBrainError.noModelSelected }
            model = selectedModelSlug
        } else if let fallbackAPIKey = TomLensAPIKeyFallback.storedAPIKey {
            bearerToken = fallbackAPIKey
            model = apiKeyFallbackModel
        } else {
            throw CompanionBrainError.notConfigured
        }

        if let retryAfterSeconds = callRateLimiter.reserveCall(now: Date()) {
            throw ResponsesAPIError.callCapReached(retryAfterSeconds: retryAfterSeconds)
        }

        let requestBody = ResponsesRequestBuilder.requestBody(
            model: model,
            instructions: systemPrompt,
            conversationHistory: conversationHistory.map {
                ResponsesConversationTurn(userText: $0.userPlaceholder, assistantText: $0.assistantResponse)
            },
            images: images.map { ResponsesInputImage(jpegData: $0.data, label: $0.label) },
            userPrompt: userPrompt
        )
        onRequestBody?(requestBody)

        var request = URLRequest(url: responsesEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try ResponsesRequestBuilder.requestBodyData(requestBody)

        do {
            let responseText = try await streamResponseText(for: request)
            planUsagePausedUntil = nil
            return responseText
        } catch let apiError as ResponsesAPIError {
            if apiError == .usageLimitReached {
                planUsagePausedUntil = Date().addingTimeInterval(15 * 60)
            }
            if apiError == .signInRejected { signInService.markSignInRejected() }
            throw apiError
        }
    }

    static func isPlanUsagePaused(now: Date) -> Bool {
        planUsagePausedUntil.map { now < $0 } ?? false
    }

    private static func streamResponseText(for request: URLRequest) async throws -> String {
        guard let url = request.url else { throw TomNetworkAllowlistError.urlNotAllowed }
        try TomNetworkAllowlist.validate(url, configuredWebhookURL: nil)
        let (byteStream, response) = try await URLSession.shared.bytes(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            var errorBody = Data()
            for try await byte in byteStream {
                errorBody.append(byte)
                if errorBody.count > 65_536 { break }
            }
            throw ResponsesErrorClassifier.error(httpStatus: statusCode, responseBody: errorBody)
        }

        var streamParser = ResponsesStreamParser()
        var accumulatedText = ""
        func apply(_ event: ResponsesStreamParser.StreamEvent?) throws -> String? {
            switch event {
            case .textDelta(let delta):
                accumulatedText += delta
            case .completed(let fullText):
                return fullText ?? accumulatedText
            case .failed(let code, let message):
                if code != nil { throw ResponsesErrorClassifier.error(forCode: code, httpStatus: 200, detail: message ?? "") }
                throw ResponsesAPIError.streamFailed(message ?? "unknown")
            case .incomplete(let reason):
                throw ResponsesAPIError.streamFailed(reason ?? "incomplete")
            case .ignored, .none:
                break
            }
            return nil
        }

        for try await line in byteStream.lines {
            try Task.checkCancellation()
            // AsyncLineSequence drops blank lines, so each data line is
            // flushed as its own event (Responses events are single-line).
            _ = streamParser.consume(line: line)
            if let completedText = try apply(streamParser.consume(line: "")) {
                return completedText
            }
        }
        if let completedText = try apply(streamParser.finish()) { return completedText }
        throw ResponsesAPIError.streamEndedWithoutCompletion
    }
}
