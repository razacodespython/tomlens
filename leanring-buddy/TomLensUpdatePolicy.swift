//
//  TomLensUpdatePolicy.swift
//  leanring-buddy
//
//  Pure rules for the in-app update: marketing-version compare, which GitHub
//  release to download (prereleases included), which Downloads zip to trust,
//  bundle id / downgrade / same-version decisions, and sha256 checks.
//  No networking and no Keychain, so the Linux tests can run them.
//

import Foundation

/// Dotted marketing version from CFBundleShortVersionString or a release tag.
/// `v0.1.6-alpha` is 0.1.6. Missing components compare as zero, so 0.1 equals 0.1.0.
/// Numeric components, so 0.1.10 is newer than 0.1.9.
nonisolated struct TomLensMarketingVersion: Comparable, Equatable {
    let components: [Int]

    var canonical: String {
        components.map(String.init).joined(separator: ".")
    }

    init?(parsing rawVersion: String) {
        var text = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        var components: [Int] = []
        var currentDigits = ""
        var didSeeDigit = false
        for character in text {
            if Self.isASCIIDigit(character) {
                currentDigits.append(character)
                didSeeDigit = true
                continue
            }
            if character == "." {
                guard let component = Int(currentDigits), !currentDigits.isEmpty else { return nil }
                components.append(component)
                currentDigits = ""
                continue
            }
            break
        }
        guard didSeeDigit, let lastComponent = Int(currentDigits), !currentDigits.isEmpty else { return nil }
        components.append(lastComponent)
        guard !components.isEmpty else { return nil }
        self.components = components
    }

    static func == (lhs: TomLensMarketingVersion, rhs: TomLensMarketingVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: TomLensMarketingVersion, rhs: TomLensMarketingVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let leftComponent = index < lhs.components.count ? lhs.components[index] : 0
            let rightComponent = index < rhs.components.count ? rhs.components[index] : 0
            if leftComponent != rightComponent {
                return leftComponent < rightComponent
            }
        }
        return false
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return scalar.value >= 48 && scalar.value <= 57
    }
}

nonisolated enum TomLensVersionOrder: Equatable {
    case newer
    case same
    case older
    case unreadable
}

/// Why a release list could not be used. 403 is the unauthenticated rate limit.
nonisolated enum TomLensGitHubListFailure: Equatable {
    case rateLimited
    case unreachable
}

nonisolated struct TomLensReleaseAsset: Equatable {
    let name: String
    /// Public download link from the release. No account is required.
    let downloadURL: URL?
}

nonisolated struct TomLensGitHubRelease: Equatable {
    let tagName: String
    let releaseName: String
    let body: String
    let isDraft: Bool
    let isPrerelease: Bool
    let publishedAt: Date?
    let assets: [TomLensReleaseAsset]

    var marketingVersion: TomLensMarketingVersion? {
        TomLensMarketingVersion(parsing: tagName) ?? TomLensMarketingVersion(parsing: releaseName)
    }

    var unsignedZipAsset: TomLensReleaseAsset? {
        assets.first { asset in
            asset.name == TomLensUpdatePolicy.unsignedZipAssetName && asset.downloadURL != nil
        }
    }
}

nonisolated struct TomLensZipCandidate: Equatable, Sendable {
    /// Last path component, for example `TomLens-unsigned (1).zip`.
    let fileName: String
    let bundleIdentifier: String?
    let marketingVersion: String?
    let modifiedAt: Date
    /// Full path, so two files with the same name can still be told apart.
    let location: String
}

nonisolated enum TomLensPublishedChecksum: Equatable {
    case absent
    case digest(String)
    case conflict
}

nonisolated enum TomLensUpdateInstallDecision: Equatable {
    case install(version: String)
    case alreadyUpToDate(version: String)
    case refuseDowngrade(candidateVersion: String, installedVersion: String)
    case rejectBundleIdentifier
    case missingBundleVersion
    case checksumMismatch
}

nonisolated enum TomLensUpdateMessages {
    static let menuItemTitle = "Update TomLens…"
    static let updatingTitle = "Updating…"
    static let lookingUp = "Looking for a newer TomLens…"
    static let checkingDownloads = "Checking Downloads…"
    static let downloading = "Downloading the update…"
    static let checkingDownload = "Checking the download…"
    static let nothingPublished = "No newer TomLens was published. Nothing was changed."
    static let couldNotDownload = "The update couldn't be downloaded. Nothing was changed."
    static let couldNotOpenZip = "The download couldn't be opened. Nothing was changed."
    static let couldNotFinish = "The update didn't finish. Nothing was changed."
    static let downloadTooLarge = "The download was too large to install. Nothing was changed."
    static let checksumMismatch = "The downloaded file didn't match its checksum. Nothing was changed."
    static let wrongZip = "A zip was in Downloads, but it was not TomLens. Use the TomLens-unsigned.zip from the release."
    static let couldNotReachGitHub = "GitHub couldn't be reached. Put the new TomLens zip in Downloads, then try again."
    static let rateLimited = "GitHub is busy right now. Put the new TomLens zip in Downloads, then try again."
    static let wrongDownload = "That download is not TomLens. Nothing was changed."
    static let permissionsStay = "Your permissions stay as they are."

    static func alreadyUpToDate(version: String) -> String {
        "You're already on TomLens \(version). Nothing was changed. \(permissionsStay)"
    }

    static func installing(version: String) -> String {
        "Installing TomLens \(version). TomLens will close and open again. \(permissionsStay)"
    }

    static func olderZip(candidateVersion: String, installedVersion: String) -> String {
        "The zip is version \(candidateVersion), which is older than the TomLens you already have (\(installedVersion)). Stopped, nothing was changed."
    }

    static func olderRelease(candidateVersion: String, installedVersion: String) -> String {
        "The newest release is \(candidateVersion), which is older than the TomLens you already have (\(installedVersion)). Nothing was changed."
    }
}

nonisolated enum TomLensSHA256 {
    static func hexDigest(of data: Data) -> String {
        hex(digest(Array(data)))
    }

    static func digestsMatch(actualHex: String, expectedHex: String) -> Bool {
        guard let actual = normalizedHex(actualHex), let expected = normalizedHex(expectedHex) else { return false }
        return actual == expected
    }

    static func normalizedHex(_ hexText: String) -> String? {
        let trimmed = hexText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 64, trimmed.allSatisfy(isHexCharacter) else { return nil }
        return trimmed
    }

    private static func isHexCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        let value = scalar.value
        return (value >= 48 && value <= 57) || (value >= 97 && value <= 102)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var characters: [Character] = []
        characters.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0f)])
        }
        return String(characters)
    }

    private static func digest(_ message: [UInt8]) -> [UInt8] {
        var hashWords: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        let roundConstants: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]

        var padded = message
        let bitLength = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var offset = 0
        while offset < padded.count {
            var schedule = [UInt32](repeating: 0, count: 64)
            for wordIndex in 0..<16 {
                let start = offset + wordIndex * 4
                schedule[wordIndex] = (UInt32(padded[start]) << 24)
                    | (UInt32(padded[start + 1]) << 16)
                    | (UInt32(padded[start + 2]) << 8)
                    | UInt32(padded[start + 3])
            }
            for wordIndex in 16..<64 {
                let earlier = schedule[wordIndex - 15]
                let recent = schedule[wordIndex - 2]
                let smallSigma = rotateRight(earlier, by: 7) ^ rotateRight(earlier, by: 18) ^ (earlier >> 3)
                let largeSigma = rotateRight(recent, by: 17) ^ rotateRight(recent, by: 19) ^ (recent >> 10)
                schedule[wordIndex] = schedule[wordIndex - 16] &+ smallSigma &+ schedule[wordIndex - 7] &+ largeSigma
            }

            var hashA = hashWords[0]
            var hashB = hashWords[1]
            var hashC = hashWords[2]
            var hashD = hashWords[3]
            var hashE = hashWords[4]
            var hashF = hashWords[5]
            var hashG = hashWords[6]
            var hashH = hashWords[7]
            for round in 0..<64 {
                let upperSigma = rotateRight(hashE, by: 6) ^ rotateRight(hashE, by: 11) ^ rotateRight(hashE, by: 25)
                let choice = (hashE & hashF) ^ (~hashE & hashG)
                let firstTemporary = hashH &+ upperSigma &+ choice &+ roundConstants[round] &+ schedule[round]
                let lowerSigma = rotateRight(hashA, by: 2) ^ rotateRight(hashA, by: 13) ^ rotateRight(hashA, by: 22)
                let majority = (hashA & hashB) ^ (hashA & hashC) ^ (hashB & hashC)
                let secondTemporary = lowerSigma &+ majority
                hashH = hashG
                hashG = hashF
                hashF = hashE
                hashE = hashD &+ firstTemporary
                hashD = hashC
                hashC = hashB
                hashB = hashA
                hashA = firstTemporary &+ secondTemporary
            }
            hashWords[0] = hashWords[0] &+ hashA
            hashWords[1] = hashWords[1] &+ hashB
            hashWords[2] = hashWords[2] &+ hashC
            hashWords[3] = hashWords[3] &+ hashD
            hashWords[4] = hashWords[4] &+ hashE
            hashWords[5] = hashWords[5] &+ hashF
            hashWords[6] = hashWords[6] &+ hashG
            hashWords[7] = hashWords[7] &+ hashH
            offset += 64
        }

        var output: [UInt8] = []
        output.reserveCapacity(32)
        for word in hashWords {
            output.append(UInt8((word >> 24) & 0xff))
            output.append(UInt8((word >> 16) & 0xff))
            output.append(UInt8((word >> 8) & 0xff))
            output.append(UInt8(word & 0xff))
        }
        return output
    }

    private static func rotateRight(_ value: UInt32, by shift: UInt32) -> UInt32 {
        (value >> shift) | (value << (32 - shift))
    }
}

nonisolated enum TomLensUpdatePolicy {
    static let bundleIdentifier = "com.razacodespython.tomlens"
    static let unsignedZipAssetName = "TomLens-unsigned.zip"
    static let unsignedZipFilePrefix = "TomLens-unsigned"
    static let applicationsAppPath = "/Applications/TomLens.app"
    static let repositoryOwner = "razacodespython"
    static let repositoryName = "tomlens"
    static let maximumZipByteCount = 200 * 1024 * 1024
    static let maximumChecksumByteCount = 1024 * 1024
    static let stagingFolderMarker = "/com.razacodespython.tomlens/update"

    /// 403 is GitHub's unauthenticated rate limit. Anything else that is not 200 is treated as unreachable.
    /// `/releases/latest` is never requested, because it skips prereleases.
    static func githubListFailure(httpStatus: Int) -> TomLensGitHubListFailure? {
        if httpStatus == 200 { return nil }
        if httpStatus == 403 { return .rateLimited }
        return .unreachable
    }

    static func releasesListURL(page: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = TomNetworkAllowlist.githubReleaseAPIHost
        components.path = TomNetworkAllowlist.gitHubReleaseRepositoryPath
        let pageNumber = max(page, 1)
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: String(pageNumber)),
        ]
        guard let url = components.url else { return nil }
        guard !url.path.contains("latest") else { return nil }
        guard TomNetworkAllowlist.isTomLensGitHubReleaseURL(url) else { return nil }
        return url
    }

    static func versionOrder(candidate rawCandidate: String, installed rawInstalled: String?) -> TomLensVersionOrder {
        guard let candidate = TomLensMarketingVersion(parsing: rawCandidate) else { return .unreadable }
        guard let rawInstalled, let installed = TomLensMarketingVersion(parsing: rawInstalled) else { return .newer }
        if candidate == installed { return .same }
        if candidate < installed { return .older }
        return .newer
    }

    static func parseReleaseList(_ data: Data) -> [TomLensGitHubRelease]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let releaseObjects = root as? [[String: Any]] else { return nil }
        return releaseObjects.map { releaseObject in
            let assets = (releaseObject["assets"] as? [[String: Any]] ?? []).compactMap { assetObject -> TomLensReleaseAsset? in
                guard let name = assetObject["name"] as? String, !name.isEmpty else { return nil }
                let downloadURL = (assetObject["browser_download_url"] as? String).flatMap(URL.init(string:)).flatMap { url in
                    TomNetworkAllowlist.isTomLensGitHubAssetDownloadURL(url) ? url : nil
                }
                return TomLensReleaseAsset(name: name, downloadURL: downloadURL)
            }
            let publishedAt = (releaseObject["published_at"] as? String).flatMap { publishedText in
                ISO8601DateFormatter().date(from: publishedText)
            }
            let body = releaseObject["body"] as? String ?? ""
            return TomLensGitHubRelease(
                tagName: releaseObject["tag_name"] as? String ?? "",
                releaseName: releaseObject["name"] as? String ?? "",
                body: body,
                isDraft: releaseObject["draft"] as? Bool ?? false,
                isPrerelease: releaseObject["prerelease"] as? Bool ?? false,
                publishedAt: publishedAt,
                assets: assets
            )
        }
    }

    /// Newest marketing version that actually ships the zip. Drafts are skipped.
    /// Prereleases stay in the running. A higher tag with no zip loses to an older one that has it.
    static func pickRelease(from releases: [TomLensGitHubRelease]) -> TomLensGitHubRelease? {
        let eligible = releases.filter { release in
            !release.isDraft && release.unsignedZipAsset != nil && release.marketingVersion != nil
        }
        return eligible.max { left, right in
            guard let leftVersion = left.marketingVersion, let rightVersion = right.marketingVersion else {
                return false
            }
            if leftVersion != rightVersion { return leftVersion < rightVersion }
            let leftPublished = left.publishedAt ?? .distantPast
            let rightPublished = right.publishedAt ?? .distantPast
            if leftPublished != rightPublished { return leftPublished < rightPublished }
            return left.tagName < right.tagName
        }
    }

    static func checksumAsset(in release: TomLensGitHubRelease) -> TomLensReleaseAsset? {
        let preferredNames = ["SHA256SUMS", "SHA256SUMS.txt", "\(unsignedZipAssetName).sha256"]
        for preferredName in preferredNames {
            if let asset = release.assets.first(where: { $0.name == preferredName && $0.downloadURL != nil }) {
                return asset
            }
        }
        return release.assets.first { asset in
            asset.downloadURL != nil
                && asset.name.lowercased().hasSuffix(".sha256")
                && asset.name.contains(unsignedZipFilePrefix)
        }
    }

    static func publishedChecksum(releaseBody: String, checksumFileName: String?, checksumFileText: String?) -> TomLensPublishedChecksum {
        var digests = digestsReferring(toAssetNamed: unsignedZipAssetName, in: releaseBody, acceptBareDigest: false)
        if let checksumFileName, let checksumFileText {
            let acceptBareDigest = checksumFileName.lowercased().hasSuffix(".sha256")
            digests.append(contentsOf: digestsReferring(
                toAssetNamed: unsignedZipAssetName,
                in: checksumFileText,
                acceptBareDigest: acceptBareDigest
            ))
        }
        let uniqueDigests = Array(Set(digests))
        if uniqueDigests.isEmpty { return .absent }
        if uniqueDigests.count > 1 { return .conflict }
        return .digest(uniqueDigests[0])
    }

    /// Finder's duplicate downloads are named `TomLens-unsigned (1).zip`. The same prefix the manual update globs.
    static func isUnsignedReleaseZipFileName(_ fileName: String) -> Bool {
        let baseName = URL(fileURLWithPath: fileName).lastPathComponent
        return baseName.hasPrefix(unsignedZipFilePrefix) && baseName.hasSuffix(".zip")
    }

    static func pickZip(from candidates: [TomLensZipCandidate]) -> TomLensZipCandidate? {
        let valid = candidates.filter { candidate in
            isUnsignedReleaseZipFileName(candidate.fileName)
                && candidate.bundleIdentifier == bundleIdentifier
                && TomLensMarketingVersion(parsing: candidate.marketingVersion ?? "") != nil
        }
        return valid.max { left, right in
            guard let leftVersion = TomLensMarketingVersion(parsing: left.marketingVersion ?? ""),
                  let rightVersion = TomLensMarketingVersion(parsing: right.marketingVersion ?? "") else {
                return false
            }
            if leftVersion != rightVersion { return leftVersion < rightVersion }
            if left.modifiedAt != right.modifiedAt { return left.modifiedAt < right.modifiedAt }
            return left.location < right.location
        }
    }

    /// Checksum is required only when one was published. A mismatch stops before the app is replaced.
    /// The same marketing version is a no-op. An older zip is refused. The bundle id must match.
    static func installDecision(
        bundleIdentifier candidateBundleIdentifier: String?,
        candidateVersion: String?,
        installedVersion: String?,
        expectedSHA256Hex: String?,
        actualSHA256Hex: String?
    ) -> TomLensUpdateInstallDecision {
        if let expectedSHA256Hex {
            guard let expectedDigest = TomLensSHA256.normalizedHex(expectedSHA256Hex),
                  let actualDigest = actualSHA256Hex.flatMap(TomLensSHA256.normalizedHex),
                  expectedDigest == actualDigest else {
                return .checksumMismatch
            }
        }
        guard candidateBundleIdentifier == bundleIdentifier else {
            return .rejectBundleIdentifier
        }
        guard let candidate = TomLensMarketingVersion(parsing: candidateVersion ?? "") else {
            return .missingBundleVersion
        }
        if let installedVersion, let installed = TomLensMarketingVersion(parsing: installedVersion) {
            if candidate < installed {
                return .refuseDowngrade(candidateVersion: candidate.canonical, installedVersion: installed.canonical)
            }
            if candidate == installed {
                return .alreadyUpToDate(version: installed.canonical)
            }
        }
        return .install(version: candidate.canonical)
    }

    static func bundleIdentity(infoPlistData: Data) -> (bundleIdentifier: String?, marketingVersion: String?) {
        guard let propertyList = try? PropertyListSerialization.propertyList(from: infoPlistData, options: [], format: nil),
              let dictionary = propertyList as? [String: Any] else {
            return (nil, nil)
        }
        return (
            dictionary["CFBundleIdentifier"] as? String,
            dictionary["CFBundleShortVersionString"] as? String
        )
    }

    /// Prefer `TomLens.app` at the root of the zip. Otherwise the shallowest nested copy.
    static func appBundleRelativePath(extractedRelativePaths: [String]) -> String? {
        var bestParts: [String]?
        for relativePath in extractedRelativePaths {
            let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
            let parts = normalized.split(separator: "/").map(String.init)
            guard let appIndex = parts.firstIndex(of: "TomLens.app") else { continue }
            let bundleParts = Array(parts.prefix(appIndex + 1))
            if let currentBest = bestParts {
                if bundleParts.count < currentBest.count {
                    bestParts = bundleParts
                }
            } else {
                bestParts = bundleParts
            }
        }
        return bestParts?.joined(separator: "/")
    }

    static func isSafeSwap(stagingDirectoryPath: String, stagedAppPath: String) -> Bool {
        let stagingPath = URL(fileURLWithPath: stagingDirectoryPath).standardizedFileURL.path
        let stagedPath = URL(fileURLWithPath: stagedAppPath).standardizedFileURL.path
        guard stagingPath.contains(stagingFolderMarker) else { return false }
        guard !stagingPath.contains("..") else { return false }
        guard stagedPath.hasPrefix(stagingPath + "/") else { return false }
        guard stagedPath.hasSuffix("/TomLens.app") else { return false }
        return true
    }

    /// Runs only after this process has quit. Replaces `/Applications/TomLens.app` and nothing else.
    /// Leaves zip files in Downloads. Removes unpacked app copies that would confuse the next launch.
    static func swapScript() -> String {
        """
        #!/bin/sh
        # Replaces only /Applications/TomLens.app after TomLens has quit, then opens that copy.
        set -u
        process_identifier="${1:-}"
        staged_app="${2:-}"
        staging_directory="${3:-}"
        destination_app="/Applications/TomLens.app"
        downloads_directory="${HOME}/Downloads"

        case "$staging_directory" in
          */com.razacodespython.tomlens/update) ;;
          *) exit 1 ;;
        esac
        case "$staged_app" in
          "$staging_directory"/*TomLens.app) ;;
          *) exit 1 ;;
        esac
        if [ "$destination_app" != "/Applications/TomLens.app" ]; then
          exit 1
        fi

        wait_count=0
        while kill -0 "$process_identifier" 2>/dev/null; do
          wait_count=$((wait_count + 1))
          if [ "$wait_count" -gt 80 ]; then
            break
          fi
          sleep 0.25
        done

        rm -rf "$destination_app"
        /usr/bin/ditto "$staged_app" "$destination_app" || exit 1
        /usr/bin/xattr -cr "$destination_app" || true
        /usr/bin/open "$destination_app" || exit 1
        rm -rf "$staging_directory" "$downloads_directory/TomLens.app" "$downloads_directory/TomLens 2.app" "$downloads_directory/tomlens-016"
        rm -f "$0"
        exit 0
        """
    }

    private static func digestsReferring(toAssetNamed assetName: String, in text: String, acceptBareDigest: Bool) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if acceptBareDigest, let bareDigest = TomLensSHA256.normalizedHex(trimmed) {
            return [bareDigest]
        }
        let lines = text.components(separatedBy: .newlines)
        var digests: [String] = []
        for (lineIndex, line) in lines.enumerated() {
            guard line.contains(assetName) else { continue }
            let digestsOnLine = hexRuns(in: line).compactMap(TomLensSHA256.normalizedHex)
            if digestsOnLine.count == 1 {
                digests.append(digestsOnLine[0])
                continue
            }
            if digestsOnLine.isEmpty, lineIndex + 1 < lines.count {
                let nextLine = lines[lineIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if let nextDigest = TomLensSHA256.normalizedHex(nextLine) {
                    digests.append(nextDigest)
                }
            }
        }
        return digests
    }

    private static func hexRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                runs.append(current.lowercased())
            }
            current = ""
        }
        for character in text {
            if isHexDigit(character) {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return runs
    }

    private static func isHexDigit(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        let value = scalar.value
        return (value >= 48 && value <= 57) || (value >= 65 && value <= 70) || (value >= 97 && value <= 102)
    }
}
