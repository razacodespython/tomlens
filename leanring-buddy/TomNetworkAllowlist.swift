//
//  TomNetworkAllowlist.swift
//  leanring-buddy
//
//  Outbound hosts TomLens may contact. ChatGPT sign-in and the Responses
//  API, the one webhook host Raza configured, and ntfy.sh. Nothing else.
//  The webhook sender key is not a host and never belongs in a URL.
//

import Foundation

nonisolated enum TomNetworkAllowlistError: Error, Equatable {
    case urlNotAllowed
}

nonisolated enum TomNetworkAllowlist {
    /// Sign in with ChatGPT, the Responses API, and the usage page.
    static let chatGPTAndOpenAIHosts: Set<String> = [
        "api.openai.com",
        "auth.openai.com",
        "chatgpt.com",
    ]
    static let ntfyHost = "ntfy.sh"

    /// https only. A configured webhook contributes its host and no other.
    static func isAllowed(_ url: URL, configuredWebhookURL: URL?) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if url.user != nil || url.password != nil { return false }
        if chatGPTAndOpenAIHosts.contains(host) || host == ntfyHost { return true }
        guard let configuredWebhookURL,
              configuredWebhookURL.scheme?.lowercased() == "https",
              configuredWebhookURL.user == nil,
              let webhookHost = configuredWebhookURL.host?.lowercased(),
              !webhookHost.isEmpty,
              host == webhookHost else {
            return false
        }
        return true
    }

    static func validate(_ url: URL, configuredWebhookURL: URL?) throws {
        guard isAllowed(url, configuredWebhookURL: configuredWebhookURL) else {
            throw TomNetworkAllowlistError.urlNotAllowed
        }
    }

    /// https URL with a host and no userinfo. Empty or http is not a webhook.
    static func normalizedWebhookURL(_ rawURL: String) -> URL? {
        let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else { return nil }
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// One path segment. Slashes and dots cannot point the stream at another host.
    static func isAcceptableNtfyTopic(_ topic: String) -> Bool {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...128).contains(trimmedTopic.count) else { return false }
        return trimmedTopic.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
        }
    }

    /// Outbound JSON stream. `since=10m` matches the reply nonce lifetime.
    static func ntfyJSONStreamURL(topic: String) -> URL? {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAcceptableNtfyTopic(trimmedTopic) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = ntfyHost
        components.path = "/\(trimmedTopic)/json"
        components.queryItems = [URLQueryItem(name: "since", value: "10m")]
        guard let url = components.url, isAllowed(url, configuredWebhookURL: nil) else { return nil }
        return url
    }
}
