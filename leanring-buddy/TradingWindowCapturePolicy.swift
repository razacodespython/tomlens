//
//  TradingWindowCapturePolicy.swift
//  leanring-buddy
//
//  Pure decision logic for which single window TomLens may capture. No
//  ScreenCaptureKit or AppKit here so it is unit-testable anywhere.
//  CompanionScreenCaptureUtility maps SCWindow -> CapturableWindowCandidate
//  and must ask this policy before every capture.
//

import Foundation

/// A window that ScreenCaptureKit reported as shareable, reduced to the
/// fields the policy needs.
struct CapturableWindowCandidate: Equatable, Identifiable {
    let windowID: UInt32
    let bundleIdentifier: String?
    let applicationName: String
    let windowTitle: String?
    /// Window frame in ScreenCaptureKit's global coordinates (top-left origin).
    let frame: CGRect

    var id: UInt32 { windowID }

    var menuLabel: String {
        guard let windowTitle, !windowTitle.isEmpty else { return applicationName }
        return "\(applicationName) — \(windowTitle)"
    }
}

/// The window the user picked, persisted so TomLens can find it again and
/// pause if it disappears or turns into something else.
struct PickedTradingWindowSelection: Codable, Equatable {
    let windowID: UInt32
    let bundleIdentifier: String?
    let applicationName: String
    let windowTitle: String?

    init(candidate: CapturableWindowCandidate) {
        windowID = candidate.windowID
        bundleIdentifier = candidate.bundleIdentifier
        applicationName = candidate.applicationName
        windowTitle = candidate.windowTitle
    }

    var menuLabel: String {
        guard let windowTitle, !windowTitle.isEmpty else { return applicationName }
        return "\(applicationName) — \(windowTitle)"
    }
}

enum WindowCaptureDecision: Equatable {
    case allowed
    /// Allowed, but the user must see a warning: a browser window can show
    /// other tabs and extensions, not just Tradovate.
    case allowedWithBrowserWarning
    case denied(reason: String)

    var isAllowed: Bool {
        if case .denied = self { return false }
        return true
    }
}

enum TradingWindowCapturePolicy {

    // MARK: - Tradovate desktop app

    /// Known/likely bundle IDs of the Tradovate desktop app ("Tradovate Trader").
    /// TODO(Raza's Mac): confirm with
    /// `mdls -name kMDItemCFBundleIdentifier /Applications/Tradovate*.app`
    /// and put the exact value first. Public listings only show the
    /// `com.tradovate` vendor prefix.
    static let tradovateDesktopBundleIdentifiers: [String] = [
        "com.tradovate.trader",
        "com.tradovate.desktop",
        "com.tradovate",
    ]
    static let tradovateBundleIdentifierPrefix = "com.tradovate"
    static let tradovateApplicationNameKeyword = "tradovate"

    static func isTradovateDesktopApp(_ candidate: CapturableWindowCandidate) -> Bool {
        if let bundleIdentifier = candidate.bundleIdentifier?.lowercased() {
            if tradovateDesktopBundleIdentifiers.contains(bundleIdentifier) { return true }
            if bundleIdentifier.hasPrefix(tradovateBundleIdentifierPrefix + ".") { return true }
            if isBrowser(bundleIdentifier: bundleIdentifier) { return false }
        }
        return candidate.applicationName.lowercased().contains(tradovateApplicationNameKeyword)
    }

    // MARK: - Browsers (allowed with a warning)

    static let browserBundleIdentifiers: Set<String> = [
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
        "com.google.chrome",
        "com.google.chrome.canary",
        "org.chromium.chromium",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.browser",
        "com.brave.browser",
        "com.microsoft.edgemac",
        "com.operasoftware.opera",
        "com.vivaldi.vivaldi",
        "com.kagi.kagimacos",
        "app.zen-browser.zen",
    ]

    static func isBrowser(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return browserBundleIdentifiers.contains(bundleIdentifier.lowercased())
    }

    // MARK: - Denylist (never capturable)

    /// Wallet apps. There are no wallets on Raza's MacBook; this is a safety net.
    static let deniedBundleIdentifiers: Set<String> = [
        "com.ledger.live",
        "io.trezor.trezorsuite",
        "com.electron.exodus",
        "exodusmovement.exodus",
        "org.electrum.electrum",
        "com.sparrowwallet.sparrow",
        "com.wasabiwallet.wasabi",
        "com.bluewallet.bluewallet",
        "app.phantom",
        "io.metamask",
        "io.rabby.desktop",
        "com.coinbase.wallet",
        "com.keplr.wallet",
        "xyz.hyperliquid",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    /// Lower-cased keywords that deny a window when found in its app name or
    /// title. Titles matter for browsers: a wallet extension popup or a
    /// Hyperliquid tab shows up in the browser window's title.
    static let deniedKeywords: [String] = [
        "wallet",
        "metamask",
        "phantom",
        "rabby",
        "hyperliquid",
        "ledger live",
        "trezor",
        "exodus",
        "electrum",
        "keplr",
        "seed phrase",
        "recovery phrase",
        "private key",
        "1password",
        "bitwarden",
        "keychain access",
    ]

    static func deniedReason(for candidate: CapturableWindowCandidate) -> String? {
        if let bundleIdentifier = candidate.bundleIdentifier?.lowercased() {
            if deniedBundleIdentifiers.contains(bundleIdentifier) {
                return "\(candidate.applicationName) is on the wallet/secrets denylist"
            }
            if deniedBundleIdentifiers.contains(where: { bundleIdentifier.hasPrefix($0 + ".") }) {
                return "\(candidate.applicationName) is on the wallet/secrets denylist"
            }
        }
        let searchableText = [candidate.applicationName, candidate.windowTitle ?? ""]
            .joined(separator: " ")
            .lowercased()
        if let matchedKeyword = deniedKeywords.first(where: { searchableText.contains($0) }) {
            return "window mentions \"\(matchedKeyword)\""
        }
        return nil
    }

    // MARK: - Decisions

    static func decision(for candidate: CapturableWindowCandidate) -> WindowCaptureDecision {
        if let reason = deniedReason(for: candidate) {
            return .denied(reason: reason)
        }
        if isBrowser(bundleIdentifier: candidate.bundleIdentifier) {
            return .allowedWithBrowserWarning
        }
        return .allowed
    }

    /// Checks the live window right before a capture. Pauses (denies) if it
    /// is no longer the app the user picked, or if it became denylisted.
    static func decision(
        forLiveWindow candidate: CapturableWindowCandidate,
        pickedSelection: PickedTradingWindowSelection
    ) -> WindowCaptureDecision {
        guard candidate.bundleIdentifier?.lowercased() == pickedSelection.bundleIdentifier?.lowercased() else {
            return .denied(reason: "the picked window now belongs to a different app")
        }
        return decision(for: candidate)
    }

    /// Windows shown in the picker: everything not denylisted and big enough
    /// to be a real window, Tradovate desktop first, then by size.
    static func pickerCandidates(
        from candidates: [CapturableWindowCandidate],
        excludingBundleIdentifier ownBundleIdentifier: String?
    ) -> [CapturableWindowCandidate] {
        let minimumUsefulWindowSide: CGFloat = 200
        return candidates
            .filter { $0.bundleIdentifier == nil || $0.bundleIdentifier != ownBundleIdentifier }
            .filter { $0.frame.width >= minimumUsefulWindowSide && $0.frame.height >= minimumUsefulWindowSide }
            .filter { decision(for: $0).isAllowed }
            .sorted { first, second in
                let firstIsTradovate = isTradovateDesktopApp(first)
                let secondIsTradovate = isTradovateDesktopApp(second)
                if firstIsTradovate != secondIsTradovate { return firstIsTradovate }
                return first.frame.width * first.frame.height > second.frame.width * second.frame.height
            }
    }

    /// The window to pre-select when nothing is picked yet: the largest
    /// Tradovate desktop window. Never auto-picks a browser or anything else.
    static func defaultPick(from pickerCandidates: [CapturableWindowCandidate]) -> CapturableWindowCandidate? {
        pickerCandidates.first(where: { isTradovateDesktopApp($0) && decision(for: $0) == .allowed })
    }

    /// Finds the picked window among the live candidates: same window ID
    /// first, otherwise the largest window of the same app (window IDs
    /// change when an app relaunches).
    static func resolvePickedWindow(
        _ pickedSelection: PickedTradingWindowSelection,
        among liveCandidates: [CapturableWindowCandidate]
    ) -> CapturableWindowCandidate? {
        if let sameWindow = liveCandidates.first(where: { $0.windowID == pickedSelection.windowID }) {
            return sameWindow
        }
        guard let pickedBundleIdentifier = pickedSelection.bundleIdentifier else { return nil }
        return liveCandidates
            .filter { $0.bundleIdentifier == pickedBundleIdentifier }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

/// Persists the picked window in UserDefaults.
enum PickedTradingWindowStore {
    private static let userDefaultsKey = "pickedTradingWindowSelection"

    static func load(from userDefaults: UserDefaults = .standard) -> PickedTradingWindowSelection? {
        guard let data = userDefaults.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(PickedTradingWindowSelection.self, from: data)
    }

    static func save(_ selection: PickedTradingWindowSelection, to userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        userDefaults.set(data, forKey: userDefaultsKey)
    }

    static func clear(from userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: userDefaultsKey)
    }
}
