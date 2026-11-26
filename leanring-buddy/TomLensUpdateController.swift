//
//  TomLensUpdateController.swift
//  leanring-buddy
//
//  Menu-bar update. Lists public GitHub releases, including prereleases,
//  with no account. If GitHub is unreachable or rate-limited, uses the
//  newest valid zip in Downloads. Replaces only /Applications/TomLens.app.
//

import AppKit
import Combine
import Foundation
import SwiftUI

enum TomLensUpdateStatusTone: Equatable {
    case idle
    case progress
    case success
    case warning
}

/// Follows a release-file redirect only to an allowed host.
nonisolated final class TomLensGitHubDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectedURL = request.url, TomNetworkAllowlist.isTomLensGitHubDownloadURL(redirectedURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor
final class TomLensUpdateController: ObservableObject {
    static let shared = TomLensUpdateController()

    @Published private(set) var statusMessage = ""
    @Published private(set) var statusTone = TomLensUpdateStatusTone.idle
    @Published private(set) var isUpdating = false

    private let downloadDelegate = TomLensGitHubDownloadDelegate()
    private let downloadSession: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        downloadSession = URLSession(configuration: configuration, delegate: downloadDelegate, delegateQueue: nil)
    }

    func startUpdate() {
        guard !isUpdating else { return }
        isUpdating = true
        statusTone = .progress
        statusMessage = TomLensUpdateMessages.lookingUp
        Task { await runUpdate() }
    }

    private func runUpdate() async {
        var handedToSwapScript = false
        var didPresent = false
        var stagingDirectory: URL?
        defer {
            if !handedToSwapScript, let stagingDirectory {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }
        do {
            let staging = try TomLensUpdateInstaller.makeStagingDirectory()
            stagingDirectory = staging
            let installedVersion = TomLensUpdateInstaller.applicationsCopyIdentity().marketingVersion
            let githubOutcome = await githubUpdate(installedVersion: installedVersion, stagingDirectory: staging)
            let outcome: UpdateOutcome
            switch githubOutcome {
            case .fallbackToDownloads(let githubFailure):
                await showProgress(TomLensUpdateMessages.checkingDownloads)
                outcome = try await downloadsUpdate(
                    installedVersion: installedVersion,
                    stagingDirectory: staging,
                    githubFailure: githubFailure
                )
            case .resolved(let resolved):
                outcome = resolved
            }
            switch outcome {
            case .stop(let message, let tone):
                presentFinished(message, tone: tone)
                didPresent = true
            case .ready(let stagedAppURL, let version):
                await showProgress(TomLensUpdateMessages.installing(version: version))
                try await Task.detached {
                    try TomLensUpdateInstaller.spawnSwap(stagedAppURL: stagedAppURL, stagingDirectory: staging)
                }.value
                handedToSwapScript = true
                didPresent = true
                NSApp.terminate(nil)
            }
        } catch {
            if !didPresent {
                presentFinished(TomLensUpdateMessages.couldNotFinish, tone: .warning)
            }
        }
    }

    private func githubUpdate(installedVersion: String?, stagingDirectory: URL) async -> GitHubAttempt {
        let releases: [TomLensGitHubRelease]
        switch await listReleases() {
        case .failed(let failure):
            return .fallbackToDownloads(failure)
        case .listed(let listedReleases):
            releases = listedReleases
        }
        guard let release = TomLensUpdatePolicy.pickRelease(from: releases),
              let marketingVersion = release.marketingVersion,
              let zipAsset = release.unsignedZipAsset,
              let zipURL = zipAsset.downloadURL else {
            return .resolved(.stop(TomLensUpdateMessages.nothingPublished, .warning))
        }
        switch TomLensUpdatePolicy.versionOrder(candidate: marketingVersion.canonical, installed: installedVersion) {
        case .older:
            return .resolved(.stop(
                TomLensUpdateMessages.olderRelease(candidateVersion: marketingVersion.canonical, installedVersion: installedVersion ?? marketingVersion.canonical),
                .warning
            ))
        case .same:
            return .resolved(.stop(TomLensUpdateMessages.alreadyUpToDate(version: marketingVersion.canonical), .success))
        case .unreadable:
            return .resolved(.stop(TomLensUpdateMessages.nothingPublished, .warning))
        case .newer:
            break
        }

        var checksumFileName: String?
        var checksumFileText: String?
        if let checksumAsset = TomLensUpdatePolicy.checksumAsset(in: release), let checksumURL = checksumAsset.downloadURL {
            // A published checksum that we cannot read is not a reason to skip the check.
            switch await download(url: checksumURL, maximumByteCount: TomLensUpdatePolicy.maximumChecksumByteCount) {
            case .data(let checksumData):
                checksumFileName = checksumAsset.name
                checksumFileText = String(decoding: checksumData, as: UTF8.self)
            case .tooLarge:
                return .resolved(.stop(TomLensUpdateMessages.downloadTooLarge, .warning))
            case .rateLimited:
                return .fallbackToDownloads(.rateLimited)
            case .unreachable:
                return .fallbackToDownloads(.unreachable)
            case .failed:
                return .resolved(.stop(TomLensUpdateMessages.couldNotDownload, .warning))
            }
        }
        let publishedChecksum = TomLensUpdatePolicy.publishedChecksum(
            releaseBody: release.body,
            checksumFileName: checksumFileName,
            checksumFileText: checksumFileText
        )
        let expectedDigest: String?
        switch publishedChecksum {
        case .conflict:
            return .resolved(.stop(TomLensUpdateMessages.checksumMismatch, .warning))
        case .absent:
            expectedDigest = nil
        case .digest(let digest):
            expectedDigest = digest
        }

        await showProgress(TomLensUpdateMessages.downloading)
        let downloadedZip: Data
        switch await download(url: zipURL, maximumByteCount: TomLensUpdatePolicy.maximumZipByteCount) {
        case .data(let zipData):
            downloadedZip = zipData
        case .tooLarge:
            return .resolved(.stop(TomLensUpdateMessages.downloadTooLarge, .warning))
        case .rateLimited:
            return .fallbackToDownloads(.rateLimited)
        case .unreachable:
            return .fallbackToDownloads(.unreachable)
        case .failed:
            return .resolved(.stop(TomLensUpdateMessages.couldNotDownload, .warning))
        }

        await showProgress(TomLensUpdateMessages.checkingDownload)
        let actualDigest = expectedDigest == nil ? nil : TomLensSHA256.hexDigest(of: downloadedZip)
        let zipFileURL = stagingDirectory.appendingPathComponent("TomLens-unsigned.zip")
        let extractDirectory = stagingDirectory.appendingPathComponent("github", isDirectory: true)
        var extractedAppURL: URL?
        do {
            extractedAppURL = try await Task.detached { () throws -> URL? in
                try downloadedZip.write(to: zipFileURL, options: .atomic)
                try TomLensUpdateInstaller.unzip(zipFileURL: zipFileURL, into: extractDirectory)
                return TomLensUpdateInstaller.tomLensApp(inside: extractDirectory)
            }.value
        } catch {
            return .resolved(.stop(TomLensUpdateMessages.couldNotOpenZip, .warning))
        }
        guard let appURL = extractedAppURL else {
            return .resolved(.stop(TomLensUpdateMessages.couldNotOpenZip, .warning))
        }
        let identity = TomLensUpdateInstaller.identity(ofApp: appURL)
        let decision = TomLensUpdatePolicy.installDecision(
            bundleIdentifier: identity.bundleIdentifier,
            candidateVersion: identity.marketingVersion,
            installedVersion: installedVersion,
            expectedSHA256Hex: expectedDigest,
            actualSHA256Hex: actualDigest
        )
        do {
            return .resolved(try await finish(decision: decision, appURL: appURL, stagingDirectory: stagingDirectory, olderIsZip: false))
        } catch {
            return .resolved(.stop(TomLensUpdateMessages.couldNotFinish, .warning))
        }
    }

    private func downloadsUpdate(
        installedVersion: String?,
        stagingDirectory: URL,
        githubFailure: TomLensGitHubListFailure
    ) async throws -> UpdateOutcome {
        let scan = await Task.detached {
            TomLensUpdateInstaller.scanDownloads(stagingDirectory: stagingDirectory)
        }.value
        guard let best = TomLensUpdatePolicy.pickZip(from: scan.located.map(\.candidate)),
              let match = scan.located.first(where: { $0.candidate.location == best.location }) else {
            if scan.sawUnsignedZipName {
                return .stop(TomLensUpdateMessages.wrongZip, .warning)
            }
            switch githubFailure {
            case .rateLimited:
                return .stop(TomLensUpdateMessages.rateLimited, .warning)
            case .unreachable:
                return .stop(TomLensUpdateMessages.couldNotReachGitHub, .warning)
            }
        }
        let decision = TomLensUpdatePolicy.installDecision(
            bundleIdentifier: best.bundleIdentifier,
            candidateVersion: best.marketingVersion,
            installedVersion: installedVersion,
            expectedSHA256Hex: nil,
            actualSHA256Hex: nil
        )
        return try await finish(decision: decision, appURL: match.appURL, stagingDirectory: stagingDirectory, olderIsZip: true)
    }

    private func finish(
        decision: TomLensUpdateInstallDecision,
        appURL: URL,
        stagingDirectory: URL,
        olderIsZip: Bool
    ) async throws -> UpdateOutcome {
        switch decision {
        case .install(let version):
            let stagedAppURL = try await Task.detached {
                try TomLensUpdateInstaller.stageApp(at: appURL, stagingDirectory: stagingDirectory)
            }.value
            return .ready(stagedAppURL, version)
        case .alreadyUpToDate(let version):
            return .stop(TomLensUpdateMessages.alreadyUpToDate(version: version), .success)
        case .refuseDowngrade(let candidateVersion, let installedVersion):
            let message = olderIsZip
                ? TomLensUpdateMessages.olderZip(candidateVersion: candidateVersion, installedVersion: installedVersion)
                : TomLensUpdateMessages.olderRelease(candidateVersion: candidateVersion, installedVersion: installedVersion)
            return .stop(message, .warning)
        case .rejectBundleIdentifier, .missingBundleVersion:
            return .stop(olderIsZip ? TomLensUpdateMessages.wrongZip : TomLensUpdateMessages.wrongDownload, .warning)
        case .checksumMismatch:
            return .stop(TomLensUpdateMessages.checksumMismatch, .warning)
        }
    }

    private func listReleases() async -> ReleaseListResult {
        var pageNumber = 1
        var releases: [TomLensGitHubRelease] = []
        while pageNumber <= 5 {
            guard let pageURL = TomLensUpdatePolicy.releasesListURL(page: pageNumber) else {
                return pageNumber == 1 ? .failed(.unreachable) : .listed(releases)
            }
            let pageResult: (data: Data, statusCode: Int)
            do {
                pageResult = try await fetch(url: pageURL, accept: "application/vnd.github+json", assetDownload: false)
            } catch {
                return pageNumber == 1 ? .failed(.unreachable) : .listed(releases)
            }
            if let failure = TomLensUpdatePolicy.githubListFailure(httpStatus: pageResult.statusCode) {
                return pageNumber == 1 ? .failed(failure) : .listed(releases)
            }
            guard let pageReleases = TomLensUpdatePolicy.parseReleaseList(pageResult.data) else {
                return pageNumber == 1 ? .failed(.unreachable) : .listed(releases)
            }
            releases.append(contentsOf: pageReleases)
            if pageReleases.count < 100 { break }
            pageNumber += 1
        }
        return .listed(releases)
    }

    private func download(url: URL, maximumByteCount: Int) async -> DownloadPayload {
        do {
            let (data, statusCode) = try await fetch(url: url, accept: "application/octet-stream", assetDownload: true)
            if statusCode == 403 { return .rateLimited }
            if statusCode >= 500 { return .unreachable }
            guard statusCode == 200 else { return .failed }
            if data.count > maximumByteCount { return .tooLarge }
            return .data(data)
        } catch {
            return .unreachable
        }
    }

    /// Release lists use the API. Zip and checksum files use the public download link. Neither sends credentials.
    private func fetch(url: URL, accept: String, assetDownload: Bool) async throws -> (data: Data, statusCode: Int) {
        let allowed = assetDownload
            ? TomNetworkAllowlist.isTomLensGitHubAssetDownloadURL(url)
            : TomNetworkAllowlist.isTomLensGitHubReleaseURL(url)
        guard allowed else { throw UpdateFetchError.notAllowed }
        try TomNetworkAllowlist.validate(url, configuredWebhookURL: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("TomLens", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await downloadSession.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, statusCode)
    }

    private func showProgress(_ message: String) async {
        statusMessage = message
        statusTone = .progress
        await Task.yield()
    }

    private func presentFinished(_ message: String, tone: TomLensUpdateStatusTone) {
        statusMessage = message
        statusTone = tone
        isUpdating = false
        let alert = NSAlert()
        alert.messageText = "Update TomLens"
        alert.informativeText = message
        alert.alertStyle = tone == .warning ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private enum DownloadPayload {
        case data(Data)
        case tooLarge
        case failed
        case rateLimited
        case unreachable
    }

    private enum UpdateOutcome {
        case stop(String, TomLensUpdateStatusTone)
        case ready(URL, String)
    }

    private enum ReleaseListResult {
        case listed([TomLensGitHubRelease])
        case failed(TomLensGitHubListFailure)
    }

    private enum GitHubAttempt {
        case fallbackToDownloads(TomLensGitHubListFailure)
        case resolved(UpdateOutcome)
    }

    private enum UpdateFetchError: Error {
        case notAllowed
    }
}

struct TomLensUpdateSection: View {
    var usesMenuBarChrome: Bool
    @ObservedObject private var updateController = TomLensUpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !usesMenuBarChrome {
                Text("Update")
                    .font(.headline)
            }

            Button(action: { updateController.startUpdate() }) {
                updateButtonLabel
            }
            .buttonStyle(.plain)
            .disabled(updateController.isUpdating)
            .pointerCursor(isEnabled: !updateController.isUpdating)
            .help("Looks for a newer TomLens and replaces the copy in Applications.")

            if updateController.isUpdating {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !updateController.statusMessage.isEmpty {
                Text(updateController.statusMessage)
                    .font(.system(size: usesMenuBarChrome ? 11 : 13))
                    .foregroundColor(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var updateButtonLabel: some View {
        HStack(spacing: 6) {
            if usesMenuBarChrome {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            Text(updateController.isUpdating ? TomLensUpdateMessages.updatingTitle : TomLensUpdateMessages.menuItemTitle)
                .font(.system(size: usesMenuBarChrome ? 12 : 13, weight: usesMenuBarChrome ? .semibold : .regular))
        }
        .foregroundColor(usesMenuBarChrome ? DS.Colors.accent : Color.primary)
        .frame(maxWidth: usesMenuBarChrome ? .infinity : nil, alignment: .leading)
    }

    private var statusColor: Color {
        switch updateController.statusTone {
        case .idle, .progress:
            return usesMenuBarChrome ? DS.Colors.textSecondary : Color.secondary
        case .success:
            return usesMenuBarChrome ? DS.Colors.success : Color.green
        case .warning:
            return usesMenuBarChrome ? DS.Colors.warning : Color.orange
        }
    }
}
