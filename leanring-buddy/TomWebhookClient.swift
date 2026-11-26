//
//  TomWebhookClient.swift
//  leanring-buddy
//
//  POSTs one JSON body to the single configured webhook. Retries with
//  backoff. The sender key is placed on the request and is not logged.
//  Callers schedule this off the ChatGPT turn so a slow Tom post cannot
//  stall the live answer.
//

import Foundation

nonisolated enum TomWebhookPostOutcome: Equatable {
    case posted
    case failed
    case refusedByAllowlist

    var statusMessage: String {
        switch self {
        case .posted:
            return "Sent to Tom."
        case .failed:
            return "Saved the payload. The post failed after retries."
        case .refusedByAllowlist:
            return "Saved the payload. That webhook host is not allowed."
        }
    }
}

nonisolated enum TomWebhookClient {
    static func post(body: Data, webhookURL: URL, senderKey: String) async -> TomWebhookPostOutcome {
        let trimmedKey = senderKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return .failed }
        guard TomNetworkAllowlist.isAllowed(webhookURL, configuredWebhookURL: webhookURL) else {
            return .refusedByAllowlist
        }

        let maximumAttemptIndex = TomRelayCaps.retryBackoffSeconds.count
        for attemptIndex in 0...maximumAttemptIndex {
            if Task.isCancelled { return .failed }
            do {
                try TomNetworkAllowlist.validate(webhookURL, configuredWebhookURL: webhookURL)
                var request = URLRequest(url: webhookURL)
                request.httpMethod = "POST"
                request.timeoutInterval = 30
                request.httpBody = body
                let headers = TomRelayPayloadBuilder.authorizedHeaders(body: body, senderKey: trimmedKey)
                for (headerName, headerValue) in headers {
                    request.setValue(headerValue, forHTTPHeaderField: headerName)
                }
                let (_, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(statusCode) { return .posted }
                if !TomRelayCaps.shouldRetry(httpStatus: statusCode) { return .failed }
            } catch is TomNetworkAllowlistError {
                return .refusedByAllowlist
            } catch is CancellationError {
                return .failed
            } catch {
                if Task.isCancelled { return .failed }
            }
            guard let delaySeconds = TomRelayCaps.retryDelaySeconds(afterFailedAttempt: attemptIndex) else {
                return .failed
            }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        return .failed
    }
}
