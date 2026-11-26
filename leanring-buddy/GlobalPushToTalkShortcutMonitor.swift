//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  System-wide push-to-talk via Carbon RegisterEventHotKey. Hot keys need
//  no Input Monitoring or Accessibility permission: the app is told only
//  when its own registered combo is pressed or released and never sees any
//  other keystroke. Upstream's CGEvent tap was deleted.
//

import Carbon.HIToolbox
import Combine
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up. Carbon
    /// delivers hot key events on the main run loop.
    @Published private(set) var isShortcutCurrentlyPressed = false

    /// Set when Carbon refuses the hot key, usually because another app
    /// already owns Control+Option+Space. Nil when the hot key is registered
    /// or TomLens is switched off. The menu-bar panel shows this text.
    @Published private(set) var registrationFailureMessage: String?

    private var registeredHotKeyReference: EventHotKeyRef?
    private var installedEventHandlerReference: EventHandlerRef?

    /// Four-char code 'TLNS' identifying TomLens's hot key.
    private static let hotKeySignature: OSType = 0x544C_4E53
    private static let hotKeyIdentifier: UInt32 = 1

    var isRegistered: Bool {
        registeredHotKeyReference != nil
    }

    deinit {
        stop()
    }

    func start() {
        // Already registered: restarting would reset isShortcutCurrentlyPressed mid-press.
        guard registeredHotKeyReference == nil else { return }

        var hotKeyEventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userData)
                .takeUnretainedValue()
            return globalPushToTalkShortcutMonitor.handleHotKeyEvent(event)
        }

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            hotKeyEventTypes.count,
            &hotKeyEventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedEventHandlerReference
        )
        guard installStatus == noErr else {
            let failureMessage = "TomLens couldn't install the Control+Option+Space hotkey (status \(installStatus))."
            registrationFailureMessage = failureMessage
            print("⚠️ Push-to-talk: \(failureMessage)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyIdentifier)
        let registerStatus = RegisterEventHotKey(
            BuddyPushToTalkShortcut.carbonVirtualKeyCode,
            BuddyPushToTalkShortcut.carbonModifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKeyReference
        )
        guard registerStatus == noErr else {
            let failureMessage = "Control+Option+Space is already used by another app, so the hotkey didn't register (status \(registerStatus))."
            registrationFailureMessage = failureMessage
            print("⚠️ Push-to-talk: RegisterEventHotKey failed for \(BuddyPushToTalkShortcut.pushToTalkDisplayText). \(failureMessage)")
            registeredHotKeyReference = nil
            removeInstalledEventHandler()
            return
        }
        registrationFailureMessage = nil
    }

    func stop() {
        // If the key is held while TomLens is switched off, publish a release
        // so the mic stops instead of staying open.
        if isShortcutCurrentlyPressed {
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        if let registeredHotKeyReference {
            UnregisterEventHotKey(registeredHotKeyReference)
            self.registeredHotKeyReference = nil
        }
        removeInstalledEventHandler()
        registrationFailureMessage = nil
    }

    private func removeInstalledEventHandler() {
        if let installedEventHandlerReference {
            RemoveEventHandler(installedEventHandlerReference)
            self.installedEventHandlerReference = nil
        }
    }

    private func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard parameterStatus == noErr,
              hotKeyID.signature == Self.hotKeySignature,
              hotKeyID.id == Self.hotKeyIdentifier else {
            return OSStatus(eventNotHandledErr)
        }

        let hotKeyEventKind: BuddyPushToTalkShortcut.HotKeyEventKind
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            hotKeyEventKind = .pressed
        case UInt32(kEventHotKeyReleased):
            hotKeyEventKind = .released
        default:
            return OSStatus(eventNotHandledErr)
        }

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: hotKeyEventKind,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return noErr
    }
}
