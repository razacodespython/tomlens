//
//  TomLensStatusPresentationTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import TomLens

struct TomLensStatusPresentationTests {

    @Test func switchedOffHidesAnyVoicePhase() {
        for voicePhase in [TomLensVoicePhase.idle, .listening, .processing, .responding] {
            #expect(TomLensActivity.resolve(isSwitchedOn: false, voicePhase: voicePhase) == .off)
        }
        #expect(TomLensActivity.off.label == "Off")
    }

    @Test func switchedOnMapsTheVoicePipeline() {
        #expect(TomLensActivity.resolve(isSwitchedOn: true, voicePhase: .idle) == .idle)
        #expect(TomLensActivity.resolve(isSwitchedOn: true, voicePhase: .listening) == .listening)
        #expect(TomLensActivity.resolve(isSwitchedOn: true, voicePhase: .processing) == .thinking)
        #expect(TomLensActivity.resolve(isSwitchedOn: true, voicePhase: .responding) == .speaking)
        #expect(TomLensActivity.listening.label == "Listening")
        #expect(TomLensActivity.thinking.label == "Thinking")
        #expect(TomLensActivity.speaking.label == "Speaking")
    }

    @Test func watchingLabelNamesThePickedWindowOrSaysNone() {
        #expect(TomLensStatusPresentation.watchingLabel(applicationName: nil, windowTitle: nil) == "No window picked")
        #expect(TomLensStatusPresentation.watchingLabel(applicationName: "", windowTitle: "Chart") == "No window picked")
        #expect(TomLensStatusPresentation.watchingLabel(applicationName: "Tradovate Trader", windowTitle: nil) == "Watching: Tradovate Trader")
        #expect(TomLensStatusPresentation.watchingLabel(applicationName: "Tradovate Trader", windowTitle: "") == "Watching: Tradovate Trader")
        #expect(TomLensStatusPresentation.watchingLabel(applicationName: "Tradovate Trader", windowTitle: "MNQ") == "Watching: Tradovate Trader – MNQ")
    }

    @Test func hotkeyStatusPrefersARegistrationFailure() {
        #expect(TomLensStatusPresentation.hotkeyStatus(registrationFailureMessage: nil) == "Hold Control+Option+Z")
        #expect(TomLensStatusPresentation.hotkeyStatus(registrationFailureMessage: "") == "Hold Control+Option+Z")
        #expect(TomLensStatusPresentation.switchedOffHint == "Switch on, then hold Control+Option+Z")
        #expect(TomLensStatusPresentation.hotkeyStatus(registrationFailureMessage: "taken") == "taken")
    }

    @Test func callsUsedLabelIncludesTheHourlyCap() {
        #expect(TomLensStatusPresentation.callsUsedLabel(callsUsed: 0, hourlyCap: 40) == "0 of 40 calls used this hour")
        #expect(TomLensStatusPresentation.callsUsedLabel(callsUsed: 3, hourlyCap: 40) == "3 of 40 calls used this hour")
    }

    @Test func chatGPTStatusNamesTheAccountOrSaysSignedOut() {
        #expect(TomLensStatusPresentation.chatGPTStatusLabel(isSignedIn: false, email: nil) == "Not signed in")
        #expect(TomLensStatusPresentation.chatGPTStatusLabel(isSignedIn: true, email: "") == "Not signed in")
        #expect(TomLensStatusPresentation.chatGPTStatusLabel(isSignedIn: true, email: "raza@example.com") == "Signed in as raza@example.com")
    }

    @Test func permissionButtonAsksBeforeItOpensSettings() {
        #expect(TomLensPermissionPresentation.action(for: .notDetermined) == .allow)
        #expect(TomLensPermissionPresentation.buttonTitle(for: .notDetermined) == "Allow")
        #expect(TomLensPermissionPresentation.action(for: .denied) == .openSettings)
        #expect(TomLensPermissionPresentation.buttonTitle(for: .denied) == "Open Settings")
        #expect(TomLensPermissionPresentation.action(for: .granted) == .none)
        #expect(TomLensPermissionPresentation.buttonTitle(for: .granted) == nil)
    }

    @Test func screenRecordingTreatsTheFirstRefusalAsTheSystemPrompt() {
        #expect(TomLensPermissionPresentation.screenRecordingStatus(preflightGranted: true, hasAttemptedSystemPrompt: false) == .granted)
        #expect(TomLensPermissionPresentation.screenRecordingStatus(preflightGranted: false, hasAttemptedSystemPrompt: false) == .notDetermined)
        #expect(TomLensPermissionPresentation.screenRecordingStatus(preflightGranted: false, hasAttemptedSystemPrompt: true) == .denied)
    }

    @Test func microphoneAndSpeechMapTheSystemAuthorization() {
        #expect(TomLensPermissionPresentation.authorizationStatus(isAuthorized: true, isNotDetermined: false) == .granted)
        #expect(TomLensPermissionPresentation.authorizationStatus(isAuthorized: false, isNotDetermined: true) == .notDetermined)
        #expect(TomLensPermissionPresentation.authorizationStatus(isAuthorized: false, isNotDetermined: false) == .denied)
    }

    @Test func testLookPromptIsTheFixedQuestion() {
        #expect(TomLensStatusPresentation.testLookPrompt == "What do you see?")
    }

    @Test func rateLimiterCountsCallsStillInsideTheHour() {
        let limiter = ModelCallRateLimiter(maximumCallsPerWindow: 40)
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(limiter.reserveCall(now: now) == nil)
        #expect(limiter.reserveCall(now: now.addingTimeInterval(1)) == nil)
        #expect(limiter.callsUsed(now: now.addingTimeInterval(2)) == 2)
        #expect(limiter.callsUsed(now: now.addingTimeInterval(ModelCallRateLimiter.windowSeconds + 10)) == 0)
    }
}
