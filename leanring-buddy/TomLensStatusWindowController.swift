//
//  TomLensStatusWindowController.swift
//  leanring-buddy
//
//  A normal macOS window (not a click-through overlay) so Raza can see
//  whether TomLens is off, listening, or stuck. It does not capture the
//  screen and it does not click or type into other apps.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let tomLensShowStatusWindow = Notification.Name("tomLensShowStatusWindow")
}

@MainActor
final class TomLensStatusWindowController {
    private var statusWindow: NSWindow?
    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func show() {
        if statusWindow == nil {
            statusWindow = makeStatusWindow()
        }
        statusWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeStatusWindow() -> NSWindow {
        let hostingView = NSHostingView(rootView: TomLensStatusView(companionManager: companionManager))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TomLens"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.center()
        return window
    }
}

struct TomLensStatusView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var chatGPTSignInService = ChatGPTSignInService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switchRow
                chatGPTRow
                windowRow
                permissionsSection
                hotkeyRow
                activityRow
                transcriptSection
                actionRow
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 560)
        .onAppear {
            companionManager.refreshPickableTradingWindows()
        }
    }

    private var activity: TomLensActivity {
        TomLensActivity.resolve(isSwitchedOn: companionManager.isTomLensSwitchedOn, voicePhase: voicePhase)
    }

    private var voicePhase: TomLensVoicePhase {
        switch companionManager.voiceState {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .processing
        case .responding: return .responding
        }
    }

    private var switchRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(companionManager.isTomLensSwitchedOn ? "TomLens is on" : "TomLens is off")
                    .font(.headline)
                Spacer()
                Toggle("TomLens on", isOn: Binding(
                    get: { companionManager.isTomLensSwitchedOn },
                    set: { companionManager.setTomLensSwitchedOn($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .pointerCursor()
            }
            Text(TomLensStatusPresentation.switchedOffHint)
                .font(.callout)
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chatGPTRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ChatGPT")
                .font(.headline)
            Text(TomLensStatusPresentation.chatGPTStatusLabel(
                isSignedIn: chatGPTSignInService.isSignedIn,
                email: chatGPTSignInService.signedInEmail
            ))
            .font(.body)
            if let lastErrorMessage = chatGPTSignInService.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.callout)
                    .foregroundStyle(Color.orange)
            }
            HStack {
                if chatGPTSignInService.isSignedIn {
                    Button("Sign out") { chatGPTSignInService.signOut() }
                        .pointerCursor()
                } else {
                    Button(chatGPTSignInService.isSigningIn ? "Waiting for browser…" : "Sign in") {
                        if chatGPTSignInService.isSigningIn {
                            chatGPTSignInService.cancelSignIn()
                        } else {
                            chatGPTSignInService.signIn()
                        }
                    }
                    .pointerCursor()
                }
            }
        }
    }

    private var windowRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Window")
                .font(.headline)
            Picker("Picked window", selection: pickedWindowSelection) {
                Text("Pick a window").tag(Optional<UInt32>.none)
                ForEach(companionManager.pickableTradingWindows) { candidate in
                    Text(candidate.menuLabel).tag(Optional(candidate.windowID))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Text(TomLensStatusPresentation.watchingLabel(
                applicationName: companionManager.pickedTradingWindow?.applicationName,
                windowTitle: companionManager.pickedTradingWindow?.windowTitle
            ))
            .font(.callout)
            if let pickedTradingWindowWarning = companionManager.pickedTradingWindowWarning {
                Text(pickedTradingWindowWarning)
                    .font(.callout)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pickedWindowSelection: Binding<UInt32?> {
        Binding(
            get: { companionManager.pickedTradingWindow?.windowID },
            set: { selectedWindowID in
                guard let selectedWindowID,
                      let candidate = companionManager.pickableTradingWindows.first(where: { $0.windowID == selectedWindowID }) else {
                    return
                }
                companionManager.pickTradingWindow(candidate)
            }
        )
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions")
                .font(.headline)
            permissionRow(name: "Screen Recording", status: companionManager.screenRecordingStatus) {
                companionManager.allowScreenRecording()
            } openSettings: {
                companionManager.openPermissionSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
            permissionRow(name: "Microphone", status: companionManager.microphoneStatus) {
                companionManager.allowMicrophone()
            } openSettings: {
                companionManager.openPermissionSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
            permissionRow(name: "Speech Recognition", status: companionManager.speechRecognitionStatus) {
                companionManager.allowSpeechRecognition()
            } openSettings: {
                companionManager.openPermissionSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            }
            Text(TomLensStatusPresentation.permissionRevokedAfterUpdateNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset") {
                companionManager.openPermissionSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
            .pointerCursor()
        }
    }

    private func permissionRow(
        name: String,
        status: TomLensPermissionStatus,
        allow: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status == .granted ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(name)
            Spacer()
            if let title = TomLensPermissionPresentation.buttonTitle(for: status) {
                Button(title) {
                    switch TomLensPermissionPresentation.action(for: status) {
                    case .allow:
                        allow()
                    case .openSettings:
                        openSettings()
                    case .none:
                        break
                    }
                }
                .pointerCursor()
            }
        }
    }

    private var hotkeyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hotkey")
                .font(.headline)
            Text(TomLensStatusPresentation.hotkeyStatus(
                registrationFailureMessage: companionManager.pushToTalkRegistrationFailureMessage
            ))
            .font(.body)
            .foregroundStyle(companionManager.pushToTalkRegistrationFailureMessage == nil ? Color.primary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Now")
                .font(.headline)
            Text(activity.label)
                .font(.title3)
            if activity == .listening {
                ProgressView(value: min(max(Double(companionManager.currentAudioPowerLevel), 0), 1))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Microphone level")
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last thing you said")
                .font(.headline)
            Text(companionManager.lastTranscript ?? "Nothing yet")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("Last reply")
                .font(.headline)
            Text(companionManager.lastModelReply ?? "Nothing yet")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(TomLensStatusPresentation.callsUsedLabel(
                callsUsed: CompanionBrain.callRateLimiter.callsUsed(now: Date()),
                hourlyCap: CompanionBrain.callRateLimiter.maximumCallsPerWindow
            ))
            .font(.callout)
            .foregroundStyle(Color.secondary)
        }
    }

    private var actionRow: some View {
        HStack {
            Button("Test") {
                companionManager.sendTestLookRequest()
            }
            .disabled(companionManager.pickedTradingWindow == nil)
            .pointerCursor(isEnabled: companionManager.pickedTradingWindow != nil)
            .help("Sends “What do you see?” using the picked window. Counts toward the hourly cap.")

            Button("Open journal folder") {
                companionManager.openJournalFolder()
            }
            .pointerCursor()
        }
    }
}
