//
//  TomLensStatusPresentation.swift
//  leanring-buddy
//
//  Pure text and state mapping for the TomLens status window. No AppKit,
//  so the Linux tests can check what the window says without a Mac.
//

import Foundation

/// The phase of the voice pipeline, without the menu-bar on/off switch.
nonisolated enum TomLensVoicePhase: Equatable {
    case idle
    case listening
    case processing
    case responding
}

/// What the status window should say TomLens is doing right now.
nonisolated enum TomLensActivity: Equatable {
    case off
    case idle
    case listening
    case thinking
    case speaking

    var label: String {
        switch self {
        case .off: return "Off"
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    /// Off wins over the voice pipeline: the hot key is unregistered until
    /// the switch is on, so a stale listening phase must not look active.
    static func resolve(isSwitchedOn: Bool, voicePhase: TomLensVoicePhase) -> TomLensActivity {
        guard isSwitchedOn else { return .off }
        switch voicePhase {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .thinking
        case .responding: return .speaking
        }
    }
}

nonisolated enum TomLensStatusPresentation {
    static let testLookPrompt = "What do you see?"
    static let switchedOffHint = "Switch on, then hold Control+Option+Space"
    static let readyHotkeyStatus = "Hold Control+Option+Space"
    static let noWindowPickedLabel = "No window picked"

    static func watchingLabel(applicationName: String?, windowTitle: String?) -> String {
        guard let applicationName, !applicationName.isEmpty else { return noWindowPickedLabel }
        guard let windowTitle, !windowTitle.isEmpty else { return "Watching: \(applicationName)" }
        return "Watching: \(applicationName) – \(windowTitle)"
    }

    /// The registration error replaces the hold instruction so a taken
    /// shortcut is visible instead of looking like a silent success.
    static func hotkeyStatus(registrationFailureMessage: String?) -> String {
        guard let registrationFailureMessage, !registrationFailureMessage.isEmpty else {
            return readyHotkeyStatus
        }
        return registrationFailureMessage
    }

    static func callsUsedLabel(callsUsed: Int, hourlyCap: Int) -> String {
        "\(callsUsed) of \(hourlyCap) calls used this hour"
    }

    static func chatGPTStatusLabel(isSignedIn: Bool, email: String?) -> String {
        if isSignedIn, let email, !email.isEmpty {
            return "Signed in as \(email)"
        }
        return "Not signed in"
    }
}
