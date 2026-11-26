//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AppKit
import AVFoundation
import Combine
import CoreGraphics
import Dispatch
import Foundation
import ScreenCaptureKit
import Speech
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastModelReply: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasSpeechRecognitionPermission = false
    @Published private(set) var screenRecordingStatus = TomLensPermissionStatus.notDetermined
    @Published private(set) var microphoneStatus = TomLensPermissionStatus.notDetermined
    @Published private(set) var speechRecognitionStatus = TomLensPermissionStatus.notDetermined
    @Published private(set) var hasScreenContentPermission = false
    /// Shown when Carbon refuses Control+Option+Z, usually because another app owns it.
    @Published private(set) var pushToTalkRegistrationFailureMessage: String?

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the AI's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Apple on-device text-to-speech. Replaces the upstream paid cloud TTS client.
    private let speechSynthesizerClient = AppleSpeechSynthesizerClient()

    /// Conversation history so the AI remembers prior exchanges within a session.
    /// Each entry is the user's transcript and the AI's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var permissionCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Short-lived click-through drawings over the picked window.
    private let drawingOverlayController = TradingWindowDrawingOverlayController()
    /// ~1 fps sampling, bar-close and sharp-change triggers while switched on.
    private let tutorEventMonitor = TutorEventMonitor()
    /// Local journal (~/TomLens/journal/<session>/), one per switch-on.
    private var sessionJournal: SessionJournal?
    /// When the current push-to-talk hold began, for the accidental-tap check.
    private var pushToTalkPressedAt: Date?
    /// Force-stops the mic if a hold exceeds the maximum (e.g. a missed key-up).
    private var pushToTalkMaximumHoldTask: Task<Void, Never>?

    /// True when the required permissions (screen recording, screen content,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    // MARK: - Picked Trading Window

    /// The one window TomLens may capture. Persisted; nil until picked.
    @Published private(set) var pickedTradingWindow: PickedTradingWindowSelection? = PickedTradingWindowStore.load()
    /// Windows the user can pick from. Denylisted windows never appear.
    @Published private(set) var pickableTradingWindows: [CapturableWindowCandidate] = []

    /// Shown in the panel when the picked window is a browser window.
    var pickedTradingWindowWarning: String? {
        guard let pickedTradingWindow,
              TradingWindowCapturePolicy.isBrowser(bundleIdentifier: pickedTradingWindow.bundleIdentifier) else {
            return nil
        }
        return "This is a browser window: TomLens would see every tab and extension in it. Use the Tradovate desktop app instead."
    }

    /// Re-lists shareable windows and pre-picks the Tradovate desktop app
    /// when nothing has been picked yet.
    func refreshPickableTradingWindows() {
        guard hasScreenRecordingPermission else { return }
        Task {
            do {
                let pickerCandidates = try await CompanionScreenCaptureUtility.pickerCandidates()
                pickableTradingWindows = pickerCandidates
                if pickedTradingWindow == nil,
                   let defaultPick = TradingWindowCapturePolicy.defaultPick(from: pickerCandidates) {
                    pickTradingWindow(defaultPick)
                }
            } catch {
                print("⚠️ Couldn't list shareable windows: \(error)")
            }
        }
    }

    func pickTradingWindow(_ candidate: CapturableWindowCandidate) {
        guard TradingWindowCapturePolicy.decision(for: candidate).isAllowed else { return }
        let selection = PickedTradingWindowSelection(candidate: candidate)
        PickedTradingWindowStore.save(selection)
        pickedTradingWindow = selection
    }

    /// The visible menu-bar on/off switch. Off means: hot key unregistered
    /// (so the mic can't start), no capture, no AI calls, overlay hidden.
    /// Deliberately not persisted: TomLens always launches switched off.
    @Published private(set) var isTomLensSwitchedOn: Bool = false

    func setTomLensSwitchedOn(_ switchedOn: Bool) {
        isTomLensSwitchedOn = switchedOn

        if switchedOn {
            registerPushToTalkHotKey()
            refreshPickableTradingWindows()
            startTutorEventMonitor()
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            unregisterPushToTalkHotKey()
            tutorEventMonitor.stop()
            sessionJournal = nil
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            pushToTalkMaximumHoldTask?.cancel()
            pushToTalkMaximumHoldTask = nil
            buddyDictationManager.cancelCurrentDictation()
            currentResponseTask?.cancel()
            currentResponseTask = nil
            speechSynthesizerClient.stopPlayback()
            clearDetectedElementLocation()
            voiceState = .idle
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 TomLens start — screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        refreshPickableTradingWindows()
        // TomLens launches switched off: the hot key is registered and the
        // overlay shown only after the user flips the menu-bar switch on.
    }

    /// Carbon RegisterEventHotKey. A non-nil failure means the combo is taken
    /// or the handler could not be installed; the status window shows it.
    private func registerPushToTalkHotKey() {
        globalPushToTalkShortcutMonitor.start()
        pushToTalkRegistrationFailureMessage = globalPushToTalkShortcutMonitor.registrationFailureMessage
    }

    private func unregisterPushToTalkHotKey() {
        globalPushToTalkShortcutMonitor.stop()
        pushToTalkRegistrationFailureMessage = nil
    }

    /// One "What do you see?" turn against the picked window. Counts toward
    /// the hourly cap because it goes through the same tutor path as speech.
    /// Turns the switch on first when it was off, so the capture is allowed.
    func sendTestLookRequest() {
        guard pickedTradingWindow != nil else { return }
        if !isTomLensSwitchedOn {
            setTomLensSwitchedOn(true)
        }
        runTutorTurn(.pushToTalk(transcript: TomLensStatusPresentation.testLookPrompt))
    }

    func openJournalFolder() {
        let journalFolder = SessionJournal.defaultRootDirectory
        try? FileManager.default.createDirectory(at: journalFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(journalFolder)
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        // Switch TomLens on and show the overlay for the first time —
        // isFirstAppearance triggers the welcome animation
        isTomLensSwitchedOn = true
        registerPushToTalkHotKey()
        refreshPickableTradingWindows()
        startTutorEventMonitor()
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Starts ~1 fps sampling of the picked window and the automatic triggers.
    private func startTutorEventMonitor() {
        do {
            sessionJournal = try SessionJournal()
        } catch {
            sessionJournal = nil
            print("⚠️ Couldn't create the session journal: \(error.localizedDescription)")
        }
        tutorEventMonitor.onAutomaticTrigger = { [weak self] trigger in
            self?.handleAutomaticTrigger(trigger)
        }
        tutorEventMonitor.start(pickedSelection: { [weak self] in self?.pickedTradingWindow })
    }

    func clearDetectedElementLocation() {
        drawingOverlayController.hide()
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        unregisterPushToTalkHotKey()
        tutorEventMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission

        let screenRecordingGranted = WindowPositionManager.hasScreenRecordingPermission()
        hasScreenRecordingPermission = screenRecordingGranted
        screenRecordingStatus = TomLensPermissionPresentation.screenRecordingStatus(
            preflightGranted: screenRecordingGranted,
            hasAttemptedSystemPrompt: WindowPositionManager.hasAttemptedScreenRecordingSystemPrompt
        )

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized
        microphoneStatus = TomLensPermissionPresentation.authorizationStatus(
            isAuthorized: micAuthStatus == .authorized,
            isNotDetermined: micAuthStatus == .notDetermined
        )
        let speechAuthStatus = SFSpeechRecognizer.authorizationStatus()
        hasSpeechRecognitionPermission = speechAuthStatus == .authorized
        speechRecognitionStatus = TomLensPermissionPresentation.authorizationStatus(
            isAuthorized: speechAuthStatus == .authorized,
            isNotDetermined: speechAuthStatus == .notDetermined
        )

        // Debug: log permission state on changes
        if previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }
    }

    /// Shows the real system prompt. Settings opens only after a denial.
    func allowScreenRecording() {
        _ = WindowPositionManager.requestScreenRecordingPermission()
        refreshAllPermissions()
    }

    func allowMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    func allowSpeechRecognition() {
        SFSpeechRecognizer.requestAuthorization { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    func openPermissionSettings(_ settingsURL: String) {
        guard let url = URL(string: settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                // Probe with a single allowed window (never a display-wide
                // filter) so the grant is verified without seeing the screen.
                let shareableWindows = try await CompanionScreenCaptureUtility.shareableWindows()
                let pickerCandidates = TradingWindowCapturePolicy.pickerCandidates(
                    from: shareableWindows.map(\.candidate),
                    excludingBundleIdentifier: Bundle.main.bundleIdentifier
                )
                guard let probeCandidate = pickerCandidates.first,
                      let probeWindow = shareableWindows.first(where: { $0.window.windowID == probeCandidate.windowID })?.window else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(desktopIndependentWindow: probeWindow)
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    refreshPickableTradingWindows()
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // Defense in depth: the hot key is unregistered while switched off.
            guard isTomLensSwitchedOn else { return }
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            speechSynthesizerClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            pushToTalkPressedAt = Date()
            pushToTalkMaximumHoldTask?.cancel()
            pushToTalkMaximumHoldTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(PushToTalkUtterancePolicy.maximumHoldDurationSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                print("🎙️ Push-to-talk: maximum hold reached, closing the mic")
                self?.buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            }

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        guard PushToTalkUtterancePolicy.shouldSubmit(transcript: finalTranscript) else {
                            print("🗣️ Ignoring empty or noise-only transcript")
                            return
                        }
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.sendTranscriptToBrainWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            pushToTalkMaximumHoldTask?.cancel()
            pushToTalkMaximumHoldTask = nil
            let holdDurationSeconds = pushToTalkPressedAt.map { Date().timeIntervalSince($0) } ?? 0
            pushToTalkPressedAt = nil
            if PushToTalkUtterancePolicy.isAccidentalTap(holdDurationSeconds: holdDurationSeconds) {
                // Accidental tap: close the mic and discard, no AI call.
                buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
            } else {
                buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            }
        case .none:
            break
        }
    }

    // MARK: - Tutor Prompt

    /// The bundled ruleset (TutorRulesetPrompt.md), loaded once.
    private static let tutorRuleset: String = {
        guard let rulesetURL = Bundle.main.url(forResource: TutorPromptComposer.rulesetResourceName, withExtension: "md"),
              let ruleset = try? String(contentsOf: rulesetURL, encoding: .utf8) else {
            print("⚠️ TutorRulesetPrompt.md missing from the bundle; using the fallback ruleset")
            return TutorPromptComposer.fallbackRuleset
        }
        return ruleset
    }()

    /// Running session summary maintained by the model via <summary> tags.
    private var rollingSessionSummary = ""

    // MARK: - Tutor Turns

    /// Push-to-talk: always answered (subject to the hourly cap).
    private func sendTranscriptToBrainWithScreenshot(transcript: String) {
        runTutorTurn(.pushToTalk(transcript: transcript))
    }

    /// Bar-close and sharp-change triggers: skipped while the user is talking
    /// or waiting on a reply, while plan usage is paused, or when only the
    /// calls reserved for push-to-talk are left this hour.
    private func handleAutomaticTrigger(_ trigger: TutorTrigger) {
        let isUserSpeakingOrWaiting = buddyDictationManager.isDictationInProgress
            || currentResponseTask != nil
            || speechSynthesizerClient.isPlaying
        guard TutorTriggerPolicy.shouldSendAutomaticTrigger(
            isSwitchedOn: isTomLensSwitchedOn,
            isUserSpeakingOrWaiting: isUserSpeakingOrWaiting,
            isPlanUsagePaused: CompanionBrain.isPlanUsagePaused(now: Date()),
            remainingCallsThisHour: CompanionBrain.callRateLimiter.remainingCalls(now: Date())
        ), !tutorEventMonitor.frameBuffer.frames.isEmpty else { return }
        runTutorTurn(trigger)
    }

    /// One model call: the last 2-3 frames of the picked window (1024 px),
    /// the ruleset + safety instructions, recent exchanges and the trigger.
    /// The reply may carry <draw> (shown on the overlay), <summary> (kept as
    /// the rolling summary) and <silent/> (nothing spoken).
    private func runTutorTurn(_ trigger: TutorTrigger) {
        if !trigger.isAutomatic {
            currentResponseTask?.cancel()
            speechSynthesizerClient.stopPlayback()
        }

        currentResponseTask = Task {
            if !trigger.isAutomatic { voiceState = .processing }
            defer {
                if !Task.isCancelled { currentResponseTask = nil }
            }

            do {
                guard isTomLensSwitchedOn else { return }

                // Push-to-talk gets a fresh frame of the picked window (never the full screen).
                if !trigger.isAutomatic {
                    let freshCapture = try await CompanionScreenCaptureUtility.capturePickedWindowAsJPEG(
                        pickedSelection: pickedTradingWindow
                    )
                    tutorEventMonitor.record(freshCapture)
                }
                guard !Task.isCancelled, let latestCapture = tutorEventMonitor.latestCapture else { return }

                let framesToSend = tutorEventMonitor.frameBuffer.framesToSend()
                let requestTime = Date()
                let journal = sessionJournal
                let journalTurn = journal?.beginTurn() ?? 0
                let journalFrameFiles = journal?.writeFrames(framesToSend, turn: journalTurn) ?? []
                if case .pushToTalk(let transcript) = trigger {
                    journal?.appendTranscript(speaker: "raza", text: transcript, trigger: trigger.journalName)
                }
                var journaledRequestBody: [String: Any]?
                let labeledImages = framesToSend.enumerated().map { index, frame in
                    (data: frame.jpegData, label: TutorPromptComposer.frameLabel(index: index, frame: frame, now: requestTime))
                }
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let fullResponseText: String
                do {
                    fullResponseText = try await CompanionBrain.requestResponse(
                        images: labeledImages,
                        systemPrompt: TutorPromptComposer.instructions(
                            ruleset: Self.tutorRuleset,
                            rollingSummary: rollingSessionSummary
                        ),
                        conversationHistory: historyForAPI,
                        userPrompt: trigger.userPromptText,
                        onRequestBody: { journaledRequestBody = $0 }
                    )
                    journal?.appendModelExchange(turn: journalTurn, trigger: trigger.journalName, requestBody: journaledRequestBody,
                                                 frameFiles: journalFrameFiles, responseText: fullResponseText, errorDescription: nil)
                } catch {
                    journal?.appendModelExchange(turn: journalTurn, trigger: trigger.journalName, requestBody: journaledRequestBody,
                                                 frameFiles: journalFrameFiles, responseText: nil, errorDescription: error.localizedDescription)
                    throw error
                }

                guard !Task.isCancelled, isTomLensSwitchedOn else { return }

                // Drawings use the last frame's pixel space.
                let screenshotSize = CGSize(
                    width: latestCapture.screenshotWidthInPixels,
                    height: latestCapture.screenshotHeightInPixels
                )
                let (textWithoutDrawing, drawing) = TutorDrawingParser.parse(
                    responseText: fullResponseText,
                    screenshotSizeInPixels: screenshotSize
                )
                let parsedReply = TutorPromptComposer.parseReply(textWithoutDrawing)
                if let updatedSummary = parsedReply.updatedSummary {
                    rollingSessionSummary = updatedSummary
                }
                if parsedReply.isSilent {
                    print("🤫 Tom stayed silent (\(trigger.journalName))")
                    lastModelReply = "Tom stayed quiet."
                    if !trigger.isAutomatic { voiceState = .idle }
                    return
                }
                let spokenText = TutorResponseSafetyFilter.filtered(parsedReply.spokenText)
                lastModelReply = spokenText
                journal?.appendTranscript(speaker: "tom", text: spokenText, trigger: trigger.journalName)

                drawingOverlayController.show(
                    drawing,
                    windowFrameInAppKitCoordinates: latestCapture.windowFrame,
                    pickedSelection: pickedTradingWindow
                )

                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target.
                if let pointCoordinate = drawing.primaryPoint {
                    voiceState = .idle
                    detectedElementScreenLocation = TradingWindowCoordinateMapping.appKitGlobalPoint(
                        fromScreenshotPoint: pointCoordinate,
                        screenshotSizeInPixels: screenshotSize,
                        windowFrameInAppKitCoordinates: latestCapture.windowFrame
                    )
                    detectedElementDisplayFrame = latestCapture.windowFrame
                }
                print("🎯 \(trigger.journalName): \(drawing.shapes.count) shape(s)")

                conversationHistory.append((
                    userTranscript: trigger.isAutomatic ? "[\(trigger.journalName) check]" : trigger.userPromptText,
                    assistantResponse: spokenText
                ))
                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                do {
                    try speechSynthesizerClient.speakText(spokenText)
                    voiceState = .responding
                } catch {
                    print("⚠️ Text-to-speech error: \(error)")
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                print("⚠️ Tutor response error (\(trigger.journalName)): \(error.localizedDescription)")
                // Automatic checks stay quiet on errors unless they pause TomLens.
                let pausesAutomaticCalls = (error as? ResponsesAPIError)?.pausesAutomaticCalls ?? false
                if !trigger.isAutomatic || pausesAutomaticCalls {
                    speakResponseErrorFallback(error)
                }
            }

            if !Task.isCancelled {
                voiceState = .idle
            }
        }
    }

    /// Speaks a short error so a failed AI request is never silent.
    private func speakResponseErrorFallback(_ error: Error) {
        let utterance = (error as? LocalizedError)?.errorDescription ?? "Something went wrong reaching the AI."
        lastModelReply = utterance
        try? speechSynthesizerClient.speakText(utterance)
        voiceState = .responding
    }

    func startOnboardingPromptStream() {
        let message = "hold \(BuddyPushToTalkShortcut.pushToTalkSpokenText) and ask me about your chart"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }
}
