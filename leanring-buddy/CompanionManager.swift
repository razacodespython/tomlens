//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
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
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

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
            globalPushToTalkShortcutMonitor.start()
            refreshPickableTradingWindows()
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            globalPushToTalkShortcutMonitor.stop()
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
        // TomLens launches switched off: the hot key is registered and the
        // overlay shown only after the user flips the menu-bar switch on.
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
        globalPushToTalkShortcutMonitor.start()
        refreshPickableTradingWindows()
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        drawingOverlayController.hide()
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
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

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

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

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're tomlens, a view-only trading tutor that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see the one trading window they picked, nothing else. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.

    drawing on the chart:
    you can briefly draw on the trading window to show what you mean. coordinates are pixels in the screenshot (the image is labeled with its dimensions), origin top-left, x rightward, y downward. when a drawing helps, append it at the very end, after your spoken text, as:
    <draw>[{"type":"level","y":312,"label":"vwap"},{"type":"circle","x":640,"y":300,"r":40,"label":"fork"},{"type":"arrow","from":[600,420],"to":[640,300]},{"type":"point","x":700,"y":280,"label":"entry"}]</draw>
    shapes: point, arrow, circle, level (a full-width horizontal price line). at most three shapes. if nothing needs drawing, append <draw>[]</draw>. never draw on order buttons or suggest clicking anything.
    """

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to the AI brain,
    /// and plays the response aloud via Apple text-to-speech. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// the AI's response may end with a <draw>[...]</draw> tag: shapes are
    /// drawn on a click-through overlay over the window and the first point
    /// also drives the buddy cursor flight.
    private func sendTranscriptToBrainWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        speechSynthesizerClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                guard isTomLensSwitchedOn else { return }

                // Capture only the picked trading window (never the full screen)
                let windowCapture = try await CompanionScreenCaptureUtility.capturePickedWindowAsJPEG(
                    pickedSelection: pickedTradingWindow
                )

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so the AI's coordinate space matches the image it sees. We
                // scale from screenshot pixels to window points ourselves.
                let dimensionInfo = " (image dimensions: \(windowCapture.screenshotWidthInPixels)x\(windowCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: windowCapture.imageData, label: windowCapture.label + dimensionInfo)]

                // Pass conversation history so the AI remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let fullResponseText = try await CompanionBrain.requestResponse(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript
                )

                guard !Task.isCancelled else { return }

                // Split off the optional <draw> tag (screenshot pixel space)
                let screenshotSize = CGSize(
                    width: windowCapture.screenshotWidthInPixels,
                    height: windowCapture.screenshotHeightInPixels
                )
                let (spokenText, drawing) = TutorDrawingParser.parse(
                    responseText: fullResponseText,
                    screenshotSizeInPixels: screenshotSize
                )
                drawingOverlayController.show(
                    drawing,
                    windowFrameInAppKitCoordinates: windowCapture.windowFrame,
                    pickedSelection: pickedTradingWindow
                )

                // Handle element pointing if the AI returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                if drawing.primaryPoint != nil {
                    voiceState = .idle
                }

                if let pointCoordinate = drawing.primaryPoint {
                    // The AI's coordinates are in the window screenshot's pixel
                    // space (top-left origin). Map them onto the picked window.
                    let globalLocation = TradingWindowCoordinateMapping.appKitGlobalPoint(
                        fromScreenshotPoint: pointCoordinate,
                        screenshotSizeInPixels: screenshotSize,
                        windowFrameInAppKitCoordinates: windowCapture.windowFrame
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = windowCapture.windowFrame
                    print("🎯 Drawing \(drawing.shapes.count) shape(s), pointing at (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y)))")
                } else {
                    print("🎯 Drawing \(drawing.shapes.count) shape(s), no point")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try speechSynthesizerClient.speakText(spokenText)
                        // speakText returns once AVSpeechSynthesizer has started speaking
                        voiceState = .responding
                    } catch {
                        print("⚠️ Text-to-speech error: \(error)")
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                print("⚠️ Companion response error: \(error)")
                speakResponseErrorFallback(error)
            }

            if !Task.isCancelled {
                voiceState = .idle
            }
        }
    }

    /// Speaks a short error so a failed AI request is never silent.
    private func speakResponseErrorFallback(_ error: Error) {
        let utterance = (error as? LocalizedError)?.errorDescription ?? "Something went wrong reaching the AI."
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
