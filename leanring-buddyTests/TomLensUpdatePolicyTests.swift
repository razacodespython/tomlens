//
//  TomLensUpdatePolicyTests.swift
//  leanring-buddyTests
//
//  Version compare, prerelease picking, Downloads zip names, bundle id,
//  downgrade, same-version no-op, and sha256 checks. No network.
//

import Foundation
import Testing
@testable import TomLens

struct TomLensUpdatePolicyTests {
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test func marketingVersionOrdersNumericallyAndStripsPrereleaseTags() throws {
        let older = try #require(TomLensMarketingVersion(parsing: "0.1.9"))
        let newer = try #require(TomLensMarketingVersion(parsing: "0.1.10"))
        let tagged = try #require(TomLensMarketingVersion(parsing: "v0.1.6-alpha"))
        let plain = try #require(TomLensMarketingVersion(parsing: "0.1.6"))
        let short = try #require(TomLensMarketingVersion(parsing: "0.1"))
        let padded = try #require(TomLensMarketingVersion(parsing: "0.1.0"))
        #expect(newer > older)
        #expect(tagged == plain)
        #expect(tagged.canonical == "0.1.6")
        #expect(short == padded)
        #expect(TomLensMarketingVersion(parsing: "v0.1.7-alpha")! > TomLensMarketingVersion(parsing: "0.1.6")!)
        #expect(TomLensMarketingVersion(parsing: "alpha") == nil)
        #expect(TomLensMarketingVersion(parsing: "") == nil)
        #expect(TomLensUpdatePolicy.versionOrder(candidate: "v0.1.8-alpha", installed: "0.1.7") == .newer)
        #expect(TomLensUpdatePolicy.versionOrder(candidate: "0.1.7", installed: "0.1.7") == .same)
        #expect(TomLensUpdatePolicy.versionOrder(candidate: "0.1.6", installed: "0.1.10") == .older)
        #expect(TomLensUpdatePolicy.versionOrder(candidate: "0.1.8", installed: nil) == .newer)
    }

    @Test func sha256MatchesKnownVectorsAndRejectsAMismatch() {
        #expect(TomLensSHA256.hexDigest(of: Data()) == emptyDigest)
        #expect(TomLensSHA256.hexDigest(of: Data("abc".utf8)) == abcDigest)
        #expect(TomLensSHA256.digestsMatch(actualHex: abcDigest.uppercased(), expectedHex: "  \(abcDigest)  "))
        #expect(!TomLensSHA256.digestsMatch(actualHex: emptyDigest, expectedHex: abcDigest))
        #expect(TomLensSHA256.normalizedHex(String(repeating: "a", count: 63)) == nil)
        #expect(TomLensSHA256.normalizedHex(String(repeating: "a", count: 65)) == nil)
    }

    @Test func releaseListSkipsLatestAndPicksTheNewestPrereleaseWithTheZip() throws {
        let listURL = try #require(TomLensUpdatePolicy.releasesListURL(page: 1))
        #expect(listURL.host == "api.github.com")
        #expect(listURL.path == "/repos/razacodespython/tomlens/releases")
        #expect(!listURL.path.contains("latest"))
        #expect(listURL.absoluteString.contains("per_page=100"))
        #expect(TomLensUpdatePolicy.githubListFailure(httpStatus: 200) == nil)
        #expect(TomLensUpdatePolicy.githubListFailure(httpStatus: 403) == .rateLimited)
        #expect(TomLensUpdatePolicy.githubListFailure(httpStatus: 404) == .unreachable)
        #expect(TomLensUpdatePolicy.githubListFailure(httpStatus: 500) == .unreachable)

        let releases = try #require(TomLensUpdatePolicy.parseReleaseList(Data(releaseListJSON.utf8)))
        let picked = try #require(TomLensUpdatePolicy.pickRelease(from: releases))
        #expect(picked.tagName == "v0.1.10-alpha")
        #expect(picked.isPrerelease)
        #expect(picked.marketingVersion?.canonical == "0.1.10")
        let downloadURL = try #require(picked.unsignedZipAsset?.downloadURL)
        #expect(downloadURL.path == "/razacodespython/tomlens/releases/download/v0.1.10-alpha/TomLens-unsigned.zip")
        let checksumAsset = try #require(TomLensUpdatePolicy.checksumAsset(in: picked))
        #expect(checksumAsset.name == "SHA256SUMS")
    }

    @Test func checksumComesFromTheBodyOrASumsFileAndConflictsWhenTheyDisagree() {
        let body = "SHA256 (TomLens-unsigned.zip) = \(abcDigest)"
        #expect(TomLensUpdatePolicy.publishedChecksum(releaseBody: body, checksumFileName: nil, checksumFileText: nil) == .digest(abcDigest))

        let sums = """
        \(String(repeating: "a", count: 64))  README.txt
        \(abcDigest)  TomLens-unsigned.zip
        """
        #expect(TomLensUpdatePolicy.publishedChecksum(releaseBody: "", checksumFileName: "SHA256SUMS", checksumFileText: sums) == .digest(abcDigest))
        #expect(TomLensUpdatePolicy.publishedChecksum(
            releaseBody: "",
            checksumFileName: "TomLens-unsigned.zip.sha256",
            checksumFileText: abcDigest + "\n"
        ) == .digest(abcDigest))
        #expect(TomLensUpdatePolicy.publishedChecksum(releaseBody: "", checksumFileName: nil, checksumFileText: nil) == .absent)
        let conflict = TomLensUpdatePolicy.publishedChecksum(
            releaseBody: body,
            checksumFileName: "SHA256SUMS",
            checksumFileText: "\(emptyDigest)  TomLens-unsigned.zip\n"
        )
        #expect(conflict == .conflict)
    }

    @Test func zipSelectionUnderstandsFinderDuplicatesAndSkipsTheWrongBundle() {
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let middleDate = olderDate.addingTimeInterval(10)
        let newerDate = olderDate.addingTimeInterval(20)
        #expect(TomLensUpdatePolicy.isUnsignedReleaseZipFileName("TomLens-unsigned.zip"))
        #expect(TomLensUpdatePolicy.isUnsignedReleaseZipFileName("TomLens-unsigned (1).zip"))
        #expect(TomLensUpdatePolicy.isUnsignedReleaseZipFileName("/Users/raza/Downloads/TomLens-unsigned (2).zip"))
        #expect(!TomLensUpdatePolicy.isUnsignedReleaseZipFileName("TomLens.zip"))
        #expect(!TomLensUpdatePolicy.isUnsignedReleaseZipFileName("Notes-TomLens-unsigned.zip"))
        #expect(!TomLensUpdatePolicy.isUnsignedReleaseZipFileName("TomLens-unsigned.txt"))

        let picked = TomLensUpdatePolicy.pickZip(from: [
            zip(name: "TomLens-unsigned.zip", version: "0.1.6", bundle: TomLensUpdatePolicy.bundleIdentifier, modifiedAt: olderDate),
            zip(name: "TomLens-unsigned (1).zip", version: "0.1.8", bundle: TomLensUpdatePolicy.bundleIdentifier, modifiedAt: middleDate),
            zip(name: "TomLens-unsigned (2).zip", version: "0.1.8", bundle: TomLensUpdatePolicy.bundleIdentifier, modifiedAt: newerDate),
            zip(name: "TomLens-unsigned (3).zip", version: "9.0.0", bundle: "com.example.other", modifiedAt: newerDate.addingTimeInterval(5)),
            zip(name: "TomLens.zip", version: "9.0.0", bundle: TomLensUpdatePolicy.bundleIdentifier, modifiedAt: newerDate),
        ])
        #expect(picked?.fileName == "TomLens-unsigned (2).zip")
        #expect(TomLensUpdatePolicy.pickZip(from: [
            zip(name: "TomLens-unsigned.zip", version: "9.0.0", bundle: "com.example.other", modifiedAt: newerDate),
        ]) == nil)
    }

    @Test func installDecisionRefusesDowngradeSameVersionAndBadChecksum() {
        let newerInstall = TomLensUpdatePolicy.installDecision(
            bundleIdentifier: TomLensUpdatePolicy.bundleIdentifier,
            candidateVersion: "0.1.8",
            installedVersion: "0.1.7",
            expectedSHA256Hex: nil,
            actualSHA256Hex: nil
        )
        #expect(newerInstall == .install(version: "0.1.8"))

        let sameVersion = TomLensUpdatePolicy.installDecision(
            bundleIdentifier: TomLensUpdatePolicy.bundleIdentifier,
            candidateVersion: "v0.1.7-alpha",
            installedVersion: "0.1.7",
            expectedSHA256Hex: nil,
            actualSHA256Hex: nil
        )
        #expect(sameVersion == .alreadyUpToDate(version: "0.1.7"))

        let downgrade = TomLensUpdatePolicy.installDecision(
            bundleIdentifier: TomLensUpdatePolicy.bundleIdentifier,
            candidateVersion: "0.1.6",
            installedVersion: "0.1.10",
            expectedSHA256Hex: abcDigest,
            actualSHA256Hex: abcDigest
        )
        #expect(downgrade == .refuseDowngrade(candidateVersion: "0.1.6", installedVersion: "0.1.10"))

        let wrongBundle = TomLensUpdatePolicy.installDecision(
            bundleIdentifier: "com.example.other",
            candidateVersion: "9.0.0",
            installedVersion: "0.1.7",
            expectedSHA256Hex: nil,
            actualSHA256Hex: nil
        )
        #expect(wrongBundle == .rejectBundleIdentifier)

        let mismatched = TomLensUpdatePolicy.installDecision(
            bundleIdentifier: TomLensUpdatePolicy.bundleIdentifier,
            candidateVersion: "0.1.8",
            installedVersion: "0.1.7",
            expectedSHA256Hex: abcDigest,
            actualSHA256Hex: emptyDigest
        )
        #expect(mismatched == .checksumMismatch)

        let matched = TomLensUpdatePolicy.installDecision(
            bundleIdentifier: TomLensUpdatePolicy.bundleIdentifier,
            candidateVersion: "0.1.8",
            installedVersion: "0.1.7",
            expectedSHA256Hex: abcDigest.uppercased(),
            actualSHA256Hex: abcDigest
        )
        #expect(matched == .install(version: "0.1.8"))

        let notInstalledYet = TomLensUpdatePolicy.installDecision(
            bundleIdentifier: TomLensUpdatePolicy.bundleIdentifier,
            candidateVersion: "0.1.7",
            installedVersion: nil,
            expectedSHA256Hex: nil,
            actualSHA256Hex: nil
        )
        #expect(notInstalledYet == .install(version: "0.1.7"))
    }

    @Test func infoPlistIdentityAndNestedAppPath() throws {
        let wrongPlist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.example.other</string>
        <key>CFBundleShortVersionString</key><string>9.9.9</string>
        </dict></plist>
        """.utf8)
        let identity = TomLensUpdatePolicy.bundleIdentity(infoPlistData: wrongPlist)
        #expect(identity.bundleIdentifier == "com.example.other")
        #expect(identity.marketingVersion == "9.9.9")
        let decision = TomLensUpdatePolicy.installDecision(
            bundleIdentifier: identity.bundleIdentifier,
            candidateVersion: identity.marketingVersion,
            installedVersion: "0.1.7",
            expectedSHA256Hex: nil,
            actualSHA256Hex: nil
        )
        #expect(decision == .rejectBundleIdentifier)
        #expect(TomLensUpdatePolicy.appBundleRelativePath(extractedRelativePaths: [
            "Wrapper/TomLens.app/Contents/Info.plist",
            "TomLens.app/Contents/Info.plist",
        ]) == "TomLens.app")
        #expect(TomLensUpdatePolicy.appBundleRelativePath(extractedRelativePaths: [
            "Outer/Inner/TomLens.app/Contents/MacOS/TomLens",
        ]) == "Outer/Inner/TomLens.app")
        #expect(TomLensUpdatePolicy.appBundleRelativePath(extractedRelativePaths: ["README.txt"]) == nil)
    }

    @Test func swapScriptReplacesOnlyApplicationsAndLeavesTheZip() {
        let script = TomLensUpdatePolicy.swapScript()
        #expect(script.contains("/usr/bin/ditto"))
        #expect(script.contains("/usr/bin/xattr -cr"))
        #expect(script.contains("/Applications/TomLens.app"))
        #expect(script.contains("/usr/bin/open"))
        #expect(script.contains("TomLens 2.app"))
        #expect(!script.contains("TomLens-unsigned"))
        #expect(!script.contains("osascript"))
        let privacyReset = ["tcc", "util"].joined()
        #expect(!script.contains(privacyReset))
        let staging = "/Users/raza/Library/Caches/com.razacodespython.tomlens/update"
        let staged = staging + "/ready/TomLens.app"
        #expect(TomLensUpdatePolicy.isSafeSwap(stagingDirectoryPath: staging, stagedAppPath: staged))
        #expect(!TomLensUpdatePolicy.isSafeSwap(stagingDirectoryPath: "/Applications", stagedAppPath: "/Applications/TomLens.app"))
        #expect(!TomLensUpdatePolicy.isSafeSwap(stagingDirectoryPath: staging, stagedAppPath: "/tmp/TomLens.app"))
    }

    @Test func githubURLsStayOnThisReposReleases() throws {
        let releases = try #require(URL(string: "https://api.github.com/repos/razacodespython/tomlens/releases?per_page=100"))
        let asset = try #require(URL(string: "https://api.github.com/repos/razacodespython/tomlens/releases/assets/10"))
        let direct = try #require(URL(string: "https://github.com/razacodespython/tomlens/releases/download/v0.1.10-alpha/TomLens-unsigned.zip"))
        let otherGitHub = try #require(URL(string: "https://github.com/other/repo/releases/download/v1/file.zip"))
        let redirect = try #require(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1"))
        let otherRepo = try #require(URL(string: "https://api.github.com/repos/other/repo/releases"))
        let insecure = try #require(URL(string: "http://api.github.com/repos/razacodespython/tomlens/releases"))
        let withUser = try #require(URL(string: "https://user:secret@api.github.com/repos/razacodespython/tomlens/releases"))
        #expect(TomNetworkAllowlist.isAllowed(releases, configuredWebhookURL: nil))
        #expect(TomNetworkAllowlist.isTomLensGitHubReleaseURL(releases))
        #expect(TomNetworkAllowlist.isTomLensGitHubReleaseURL(asset))
        #expect(TomNetworkAllowlist.isTomLensGitHubAssetDownloadURL(direct))
        #expect(!TomNetworkAllowlist.isTomLensGitHubAssetDownloadURL(otherGitHub))
        #expect(!TomNetworkAllowlist.isTomLensGitHubReleaseURL(redirect))
        #expect(TomNetworkAllowlist.isTomLensGitHubDownloadURL(direct))
        #expect(TomNetworkAllowlist.isTomLensGitHubDownloadURL(redirect))
        #expect(TomNetworkAllowlist.isAllowed(redirect, configuredWebhookURL: nil))
        #expect(!TomNetworkAllowlist.isTomLensGitHubReleaseURL(otherRepo))
        #expect(!TomNetworkAllowlist.isAllowed(insecure, configuredWebhookURL: nil))
        #expect(!TomNetworkAllowlist.isTomLensGitHubReleaseURL(withUser))
        #expect(!TomNetworkAllowlist.isAllowed(try #require(URL(string: "https://example.com/tomlens")), configuredWebhookURL: nil))
    }

    @Test func messagesStayPlain() {
        let messages = [
            TomLensUpdateMessages.menuItemTitle,
            TomLensUpdateMessages.lookingUp,
            TomLensUpdateMessages.downloading,
            TomLensUpdateMessages.checkingDownload,
            TomLensUpdateMessages.installing(version: "0.1.8"),
            TomLensUpdateMessages.alreadyUpToDate(version: "0.1.7"),
            TomLensUpdateMessages.olderZip(candidateVersion: "0.1.6", installedVersion: "0.1.7"),
            TomLensUpdateMessages.olderRelease(candidateVersion: "0.1.6", installedVersion: "0.1.7"),
            TomLensUpdateMessages.checksumMismatch,
            TomLensUpdateMessages.wrongZip,
            TomLensUpdateMessages.couldNotReachGitHub,
            TomLensUpdateMessages.rateLimited,
            TomLensUpdateMessages.nothingPublished,
            TomLensUpdateMessages.couldNotDownload,
        ]
        let banned = ["401", "403", "404", "Bearer", "api.github", "prerelease", "sha256", "token"]
        for message in messages {
            for word in banned {
                #expect(!message.localizedCaseInsensitiveContains(word))
            }
        }
        #expect(TomLensUpdateMessages.menuItemTitle == "Update TomLens…")
        #expect(TomLensUpdateMessages.rateLimited.contains("GitHub is busy"))
        #expect(TomLensUpdateMessages.couldNotReachGitHub.contains("Downloads"))
        #expect(TomLensUpdateMessages.alreadyUpToDate(version: "0.1.7").contains("Nothing was changed"))
    }

    private func zip(name: String, version: String, bundle: String, modifiedAt: Date) -> TomLensZipCandidate {
        TomLensZipCandidate(
            fileName: name,
            bundleIdentifier: bundle,
            marketingVersion: version,
            modifiedAt: modifiedAt,
            location: "/Users/raza/Downloads/\(name)"
        )
    }

    private var releaseListJSON: String {
        """
        [
          {
            "tag_name": "v0.1.6-alpha",
            "name": "v0.1.6-alpha",
            "body": "older prerelease",
            "draft": false,
            "prerelease": true,
            "published_at": "2026-06-01T00:00:00Z",
            "assets": [
              {"name": "TomLens-unsigned.zip", "browser_download_url": "https://github.com/razacodespython/tomlens/releases/download/v0.1.6-alpha/TomLens-unsigned.zip"}
            ]
          },
          {
            "tag_name": "v0.1.9",
            "name": "v0.1.9",
            "body": "",
            "draft": false,
            "prerelease": false,
            "published_at": "2026-03-01T00:00:00Z",
            "assets": [
              {"name": "TomLens-unsigned.zip", "browser_download_url": "https://github.com/razacodespython/tomlens/releases/download/v0.1.9/TomLens-unsigned.zip"}
            ]
          },
          {
            "tag_name": "v0.1.11",
            "name": "v0.1.11",
            "body": "",
            "draft": false,
            "prerelease": false,
            "published_at": "2026-07-01T00:00:00Z",
            "assets": [
              {"name": "README.txt", "browser_download_url": "https://github.com/razacodespython/tomlens/releases/download/v0.1.11/README.txt"}
            ]
          },
          {
            "tag_name": "v0.1.12-alpha",
            "name": "v0.1.12-alpha",
            "body": "",
            "draft": true,
            "prerelease": true,
            "published_at": "2026-08-01T00:00:00Z",
            "assets": [
              {"name": "TomLens-unsigned.zip", "browser_download_url": "https://github.com/razacodespython/tomlens/releases/download/v0.1.12-alpha/TomLens-unsigned.zip"}
            ]
          },
          {
            "tag_name": "v0.1.10-alpha",
            "name": "v0.1.10-alpha",
            "body": "SHA256 (TomLens-unsigned.zip) = \(abcDigest)",
            "draft": false,
            "prerelease": true,
            "published_at": "2026-01-01T00:00:00Z",
            "assets": [
              {"name": "TomLens-unsigned.zip", "url": "https://api.github.com/repos/razacodespython/tomlens/releases/assets/10", "browser_download_url": "https://github.com/razacodespython/tomlens/releases/download/v0.1.10-alpha/TomLens-unsigned.zip"},
              {"name": "SHA256SUMS", "browser_download_url": "https://github.com/razacodespython/tomlens/releases/download/v0.1.10-alpha/SHA256SUMS"},
              {"name": "not-ours.zip", "browser_download_url": "https://evil.example/zip"}
            ]
          }
        ]
        """
    }
}
