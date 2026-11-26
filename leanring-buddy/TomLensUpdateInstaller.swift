//
//  TomLensUpdateInstaller.swift
//  leanring-buddy
//
//  Unpacks a zip, stages TomLens.app, and starts a short helper that swaps
//  /Applications/TomLens.app only after this process has quit. The helper is
//  backgrounded so quitting does not cancel the copy.
//

import Foundation

nonisolated enum TomLensUpdateInstaller {
    struct Failure: Error {
        let message: String
    }

    static func makeStagingDirectory() throws -> URL {
        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let stagingDirectory = cachesRoot
            .appendingPathComponent("com.razacodespython.tomlens", isDirectory: true)
            .appendingPathComponent("update", isDirectory: true)
        if FileManager.default.fileExists(atPath: stagingDirectory.path) {
            try FileManager.default.removeItem(at: stagingDirectory)
        }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        return stagingDirectory
    }

    struct LocatedZip: Sendable {
        let candidate: TomLensZipCandidate
        let appURL: URL
    }

    /// Reads every `TomLens-unsigned*.zip` in Downloads, including Finder's ` (1)` copies.
    /// A zip that does not open is skipped. The caller still decides version and bundle id.
    static func scanDownloads(stagingDirectory: URL) -> (sawUnsignedZipName: Bool, located: [LocatedZip]) {
        let downloadsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let fileURLs = (try? FileManager.default.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var sawUnsignedZipName = false
        var located: [LocatedZip] = []
        for (index, zipURL) in fileURLs.enumerated() {
            guard TomLensUpdatePolicy.isUnsignedReleaseZipFileName(zipURL.lastPathComponent) else { continue }
            sawUnsignedZipName = true
            let extractDirectory = stagingDirectory.appendingPathComponent("zip-\(index)", isDirectory: true)
            do {
                try unzip(zipFileURL: zipURL, into: extractDirectory)
            } catch {
                continue
            }
            guard let appURL = tomLensApp(inside: extractDirectory) else { continue }
            let identity = identity(ofApp: appURL)
            let modifiedAt = (try? zipURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            located.append(LocatedZip(
                candidate: TomLensZipCandidate(
                    fileName: zipURL.lastPathComponent,
                    bundleIdentifier: identity.bundleIdentifier,
                    marketingVersion: identity.marketingVersion,
                    modifiedAt: modifiedAt,
                    location: zipURL.path
                ),
                appURL: appURL
            ))
        }
        return (sawUnsignedZipName, located)
    }

    static func unzip(zipFileURL: URL, into destinationDirectory: URL) throws {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        try run(executable: "/usr/bin/unzip", arguments: ["-oq", zipFileURL.path, "-d", destinationDirectory.path])
    }

    static func tomLensApp(inside directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var relativePaths: [String] = []
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        for case let fileURL as URL in enumerator {
            let filePath = fileURL.standardizedFileURL.path
            guard filePath.hasPrefix(prefix) else { continue }
            relativePaths.append(String(filePath.dropFirst(prefix.count)))
        }
        guard let relativePath = TomLensUpdatePolicy.appBundleRelativePath(extractedRelativePaths: relativePaths) else {
            return nil
        }
        return directory.appendingPathComponent(relativePath, isDirectory: true)
    }

    static func identity(ofApp appURL: URL) -> (bundleIdentifier: String?, marketingVersion: String?) {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: plistURL) else { return (nil, nil) }
        return TomLensUpdatePolicy.bundleIdentity(infoPlistData: plistData)
    }

    static func applicationsCopyIdentity() -> (bundleIdentifier: String?, marketingVersion: String?) {
        let applicationsAppURL = URL(fileURLWithPath: TomLensUpdatePolicy.applicationsAppPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: applicationsAppURL.path) else { return (nil, nil) }
        return identity(ofApp: applicationsAppURL)
    }

    static func stageApp(at sourceAppURL: URL, stagingDirectory: URL) throws -> URL {
        let stagedAppURL = stagingDirectory
            .appendingPathComponent("ready", isDirectory: true)
            .appendingPathComponent("TomLens.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedAppURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: stagedAppURL.path) {
            try FileManager.default.removeItem(at: stagedAppURL)
        }
        try run(executable: "/usr/bin/ditto", arguments: [sourceAppURL.path, stagedAppURL.path])
        return stagedAppURL
    }

    /// The helper waits for this process to exit, then ditto's the staged app into Applications.
    static func spawnSwap(stagedAppURL: URL, stagingDirectory: URL) throws {
        let stagingPath = stagingDirectory.standardizedFileURL.path
        let stagedPath = stagedAppURL.standardizedFileURL.path
        guard TomLensUpdatePolicy.isSafeSwap(stagingDirectoryPath: stagingPath, stagedAppPath: stagedPath) else {
            throw Failure(message: "unsafe staging path")
        }
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tomlens-update-\(ProcessInfo.processInfo.processIdentifier).sh")
        try TomLensUpdatePolicy.swapScript().write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Background immediately so the helper is not tied to this process's lifetime.
        // Paths are separate arguments, not interpolated into the shell command.
        process.arguments = [
            "-c",
            "nohup /bin/sh \"$1\" \"$2\" \"$3\" \"$4\" >/dev/null 2>&1 &",
            "tomlens-update",
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            stagedPath,
            stagingPath,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "could not start the install")
        }
    }

    private static func run(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "command failed")
        }
    }
}
