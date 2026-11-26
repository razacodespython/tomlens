//
//  AppleSpeechSynthesizerClient.swift
//  leanring-buddy
//
//  On-device text-to-speech via AVSpeechSynthesizer. Replaces the paid cloud
//  TTS client and keeps its call surface (speakText / stopPlayback /
//  isPlaying) so CompanionManager's pipeline is unchanged.
//

import AVFoundation

@MainActor
final class AppleSpeechSynthesizerClient {
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// True while an utterance is being spoken. Used to delay the transient
    /// overlay hide until speech finishes.
    var isPlaying: Bool {
        speechSynthesizer.isSpeaking
    }

    /// Starts speaking immediately and returns; playback continues in the background.
    func speakText(_ text: String) throws {
        stopPlayback()
        let cleanedText = PushToTalkUtterancePolicy.cleanedTextForSpeech(text)
        guard !cleanedText.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: cleanedText)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        speechSynthesizer.speak(utterance)
    }

    func stopPlayback() {
        guard speechSynthesizer.isSpeaking else { return }
        speechSynthesizer.stopSpeaking(at: .immediate)
    }
}
