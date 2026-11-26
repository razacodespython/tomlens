//
//  CompanionBrain.swift
//  leanring-buddy
//
//  Single entry point for AI requests. The paid upstream AI clients and the
//  Cloudflare Worker were removed in M1; ChatGPT via Sign in with ChatGPT
//  (Responses API, store:false, stream:true, credits overflow off) lands in M5.
//  Until then every request fails loudly instead of calling a paid API.
//

import Foundation

enum CompanionBrainError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "My AI brain isn't connected yet."
        }
    }
}

enum CompanionBrain {
    static func requestResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> String {
        throw CompanionBrainError.notConfigured
    }
}
