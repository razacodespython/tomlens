//
//  BuddyPushToTalkShortcutTests.swift
//  leanring-buddyTests
//

import Testing
@testable import TomLens

struct BuddyPushToTalkShortcutTests {

    @Test func pressStartsOnceAndRepeatsAreIgnored() {
        #expect(BuddyPushToTalkShortcut.shortcutTransition(for: .pressed, wasShortcutPreviouslyPressed: false) == .pressed)
        #expect(BuddyPushToTalkShortcut.shortcutTransition(for: .pressed, wasShortcutPreviouslyPressed: true) == .none)
    }

    @Test func releaseStopsOnlyAfterAPress() {
        #expect(BuddyPushToTalkShortcut.shortcutTransition(for: .released, wasShortcutPreviouslyPressed: true) == .released)
        #expect(BuddyPushToTalkShortcut.shortcutTransition(for: .released, wasShortcutPreviouslyPressed: false) == .none)
    }

    @Test func hotKeyIsControlOptionT() {
        #expect(BuddyPushToTalkShortcut.carbonVirtualKeyCode == 0x11)
        #expect(BuddyPushToTalkShortcut.carbonModifierFlags == 0x1800)
        #expect(BuddyPushToTalkShortcut.keyCapsuleLabels == ["ctrl", "option", "T"])
    }
}
