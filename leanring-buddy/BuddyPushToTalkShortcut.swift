//
//  BuddyPushToTalkShortcut.swift
//  leanring-buddy
//
//  The push-to-talk hotkey definition and its press/release state logic.
//  Pure Swift (no Carbon import) so the logic is unit-testable anywhere;
//  GlobalPushToTalkShortcutMonitor registers it with RegisterEventHotKey.
//

import Foundation

nonisolated enum BuddyPushToTalkShortcut {
    enum ShortcutTransition: Equatable {
        case none
        case pressed
        case released
    }

    enum HotKeyEventKind: Equatable {
        case pressed
        case released
    }

    /// Control + Option + Space. Carbon hot keys need a real key:
    /// modifier-only shortcuts need a CGEvent tap and Input Monitoring,
    /// which TomLens forbids. Raw values mirror Carbon's kVK_Space (0x31)
    /// and controlKey | optionKey (checked against the Carbon constants
    /// in the macOS unit tests).
    static let carbonVirtualKeyCode: UInt32 = 0x31
    static let carbonModifierFlags: UInt32 = 0x1000 | 0x0800

    static let pushToTalkDisplayText = "ctrl + option + space"
    static let pushToTalkSpokenText = "control + option + space"
    static let keyCapsuleLabels = ["ctrl", "option", "space"]
    static let pushToTalkTooltipText = "push to talk (\(pushToTalkDisplayText))"

    /// Converts a hot key press/release into a transition, ignoring repeats
    /// so the mic starts once per hold and always stops on release.
    static func shortcutTransition(
        for hotKeyEventKind: HotKeyEventKind,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        switch hotKeyEventKind {
        case .pressed:
            return wasShortcutPreviouslyPressed ? .none : .pressed
        case .released:
            return wasShortcutPreviouslyPressed ? .released : .none
        }
    }
}
