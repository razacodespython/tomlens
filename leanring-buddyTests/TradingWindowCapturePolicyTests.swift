//
//  TradingWindowCapturePolicyTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import TomLens

struct TradingWindowCapturePolicyTests {

    private func makeCandidate(
        windowID: UInt32 = 1,
        bundleIdentifier: String?,
        applicationName: String,
        windowTitle: String? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1400, height: 900)
    ) -> CapturableWindowCandidate {
        CapturableWindowCandidate(
            windowID: windowID,
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            windowTitle: windowTitle,
            frame: frame
        )
    }

    @Test func tradovateDesktopAppIsAllowedWithoutWarning() {
        let tradovate = makeCandidate(bundleIdentifier: "com.tradovate.trader", applicationName: "Tradovate Trader", windowTitle: "MNQZ6")
        #expect(TradingWindowCapturePolicy.isTradovateDesktopApp(tradovate))
        #expect(TradingWindowCapturePolicy.decision(for: tradovate) == .allowed)
    }

    @Test func unknownTradovateBundleStillMatchesByVendorPrefixOrName() {
        let byPrefix = makeCandidate(bundleIdentifier: "com.tradovate.something", applicationName: "Trader")
        let byName = makeCandidate(bundleIdentifier: "com.example.wrapper", applicationName: "Tradovate")
        #expect(TradingWindowCapturePolicy.isTradovateDesktopApp(byPrefix))
        #expect(TradingWindowCapturePolicy.isTradovateDesktopApp(byName))
    }

    @Test func browserTabWithTradovateIsNotTheDesktopAppAndWarns() {
        let chromeTab = makeCandidate(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "Tradovate")
        #expect(!TradingWindowCapturePolicy.isTradovateDesktopApp(chromeTab))
        #expect(TradingWindowCapturePolicy.decision(for: chromeTab) == .allowedWithBrowserWarning)
    }

    @Test func walletAppsAndWalletTitlesAreDenied() {
        let ledger = makeCandidate(bundleIdentifier: "com.ledger.live", applicationName: "Ledger Live")
        let metamaskPopup = makeCandidate(bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "MetaMask Notification")
        let hyperliquidTab = makeCandidate(bundleIdentifier: "com.brave.Browser", applicationName: "Brave Browser", windowTitle: "Hyperliquid")
        let unknownWallet = makeCandidate(bundleIdentifier: "com.example.vault", applicationName: "Cool Wallet")
        for candidate in [ledger, metamaskPopup, hyperliquidTab, unknownWallet] {
            #expect(!TradingWindowCapturePolicy.decision(for: candidate).isAllowed)
        }
    }

    @Test func pickerHidesDeniedOwnAndTinyWindowsAndPutsTradovateFirst() {
        let bigBrowser = makeCandidate(windowID: 1, bundleIdentifier: "com.apple.Safari", applicationName: "Safari", frame: CGRect(x: 0, y: 0, width: 2000, height: 1200))
        let tradovate = makeCandidate(windowID: 2, bundleIdentifier: "com.tradovate.trader", applicationName: "Tradovate Trader")
        let wallet = makeCandidate(windowID: 3, bundleIdentifier: "io.trezor.TrezorSuite", applicationName: "Trezor Suite")
        let ownPanel = makeCandidate(windowID: 4, bundleIdentifier: "com.razacodespython.tomlens", applicationName: "TomLens")
        let tinyPopup = makeCandidate(windowID: 5, bundleIdentifier: "com.example.app", applicationName: "Popup", frame: CGRect(x: 0, y: 0, width: 120, height: 80))

        let pickerCandidates = TradingWindowCapturePolicy.pickerCandidates(
            from: [bigBrowser, tradovate, wallet, ownPanel, tinyPopup],
            excludingBundleIdentifier: "com.razacodespython.tomlens"
        )
        #expect(pickerCandidates.map(\.windowID) == [2, 1])
        #expect(TradingWindowCapturePolicy.defaultPick(from: pickerCandidates)?.windowID == 2)
    }

    @Test func defaultPickNeverChoosesABrowser() {
        let safari = makeCandidate(bundleIdentifier: "com.apple.Safari", applicationName: "Safari", windowTitle: "Tradovate")
        let pickerCandidates = TradingWindowCapturePolicy.pickerCandidates(from: [safari], excludingBundleIdentifier: nil)
        #expect(TradingWindowCapturePolicy.defaultPick(from: pickerCandidates) == nil)
    }

    @Test func liveWindowFromAnotherAppOrTurnedWalletPausesCapture() {
        let tradovate = makeCandidate(windowID: 7, bundleIdentifier: "com.tradovate.trader", applicationName: "Tradovate Trader")
        let pickedSelection = PickedTradingWindowSelection(candidate: tradovate)
        let reusedWindowID = makeCandidate(windowID: 7, bundleIdentifier: "com.apple.Safari", applicationName: "Safari")
        #expect(TradingWindowCapturePolicy.decision(forLiveWindow: tradovate, pickedSelection: pickedSelection) == .allowed)
        #expect(!TradingWindowCapturePolicy.decision(forLiveWindow: reusedWindowID, pickedSelection: pickedSelection).isAllowed)

        let chrome = makeCandidate(windowID: 8, bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "Tradovate")
        let chromeSelection = PickedTradingWindowSelection(candidate: chrome)
        let chromeNowOnWallet = makeCandidate(windowID: 8, bundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome", windowTitle: "Rabby Wallet")
        #expect(!TradingWindowCapturePolicy.decision(forLiveWindow: chromeNowOnWallet, pickedSelection: chromeSelection).isAllowed)
    }

    @Test func resolvesPickedWindowByIDThenBySameApp() {
        let original = makeCandidate(windowID: 10, bundleIdentifier: "com.tradovate.trader", applicationName: "Tradovate Trader")
        let pickedSelection = PickedTradingWindowSelection(candidate: original)
        let relaunched = makeCandidate(windowID: 99, bundleIdentifier: "com.tradovate.trader", applicationName: "Tradovate Trader")
        let other = makeCandidate(windowID: 11, bundleIdentifier: "com.apple.Safari", applicationName: "Safari")
        #expect(TradingWindowCapturePolicy.resolvePickedWindow(pickedSelection, among: [other, original])?.windowID == 10)
        #expect(TradingWindowCapturePolicy.resolvePickedWindow(pickedSelection, among: [other, relaunched])?.windowID == 99)
        #expect(TradingWindowCapturePolicy.resolvePickedWindow(pickedSelection, among: [other]) == nil)
    }

    @Test func pickedSelectionRoundTripsThroughUserDefaults() throws {
        let userDefaults = try #require(UserDefaults(suiteName: "TradingWindowCapturePolicyTests"))
        defer { userDefaults.removePersistentDomain(forName: "TradingWindowCapturePolicyTests") }
        let selection = PickedTradingWindowSelection(candidate: makeCandidate(bundleIdentifier: "com.tradovate.trader", applicationName: "Tradovate Trader", windowTitle: "MNQ"))
        PickedTradingWindowStore.save(selection, to: userDefaults)
        #expect(PickedTradingWindowStore.load(from: userDefaults) == selection)
        PickedTradingWindowStore.clear(from: userDefaults)
        #expect(PickedTradingWindowStore.load(from: userDefaults) == nil)
    }
}

struct TradingWindowCoordinateMappingTests {

    @Test func mapsScreenshotPixelsOntoTheWindowWithYFlip() {
        let windowFrame = CGRect(x: 100, y: 50, width: 1400, height: 900)
        let screenshotSize = CGSize(width: 1280, height: 823)

        let topLeft = TradingWindowCoordinateMapping.appKitGlobalPoint(fromScreenshotPoint: .zero, screenshotSizeInPixels: screenshotSize, windowFrameInAppKitCoordinates: windowFrame)
        #expect(topLeft == CGPoint(x: 100, y: 950))

        let bottomRight = TradingWindowCoordinateMapping.appKitGlobalPoint(fromScreenshotPoint: CGPoint(x: 1280, y: 823), screenshotSizeInPixels: screenshotSize, windowFrameInAppKitCoordinates: windowFrame)
        #expect(abs(bottomRight.x - 1500) < 0.001)
        #expect(abs(bottomRight.y - 50) < 0.001)
    }

    @Test func clampsOutOfRangePointsInsideTheWindow() {
        let windowFrame = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let mapped = TradingWindowCoordinateMapping.appKitGlobalPoint(fromScreenshotPoint: CGPoint(x: -50, y: 9_999), screenshotSizeInPixels: CGSize(width: 1000, height: 500), windowFrameInAppKitCoordinates: windowFrame)
        #expect(mapped == CGPoint(x: 0, y: 0))
    }
}
