//
//  SessionJournal.swift
//  leanring-buddy
//
//  Local session journal: ~/TomLens/journal/<yyyyMMdd-HHmmss>/ with
//    frames/turn0001-frame1.jpg ...  the frames sent to the model
//    transcript.jsonl                 what Raza said and what Tom said
//    model.jsonl                      model requests (images replaced by
//                                     frame file names) and responses
//  One session per switch-on. Nothing is uploaded and no credentials,
//  headers or base64 images are ever written. Foundation only, so it is
//  tested on Linux with a temporary directory.
//

import Foundation

nonisolated final class SessionJournal {
    static let defaultRootDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("TomLens", isDirectory: true)
        .appendingPathComponent("journal", isDirectory: true)

    let sessionDirectory: URL
    let framesDirectory: URL
    private(set) var turnCount = 0

    var transcriptFile: URL { sessionDirectory.appendingPathComponent("transcript.jsonl") }
    var modelFile: URL { sessionDirectory.appendingPathComponent("model.jsonl") }

    init(rootDirectory: URL = SessionJournal.defaultRootDirectory, startedAt: Date = Date(), timeZone: TimeZone = .current) throws {
        sessionDirectory = rootDirectory.appendingPathComponent(Self.sessionDirectoryName(for: startedAt, timeZone: timeZone), isDirectory: true)
        framesDirectory = sessionDirectory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
    }

    static func sessionDirectoryName(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func timestampString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Starts a new model turn and returns its number (1-based).
    func beginTurn() -> Int {
        turnCount += 1
        return turnCount
    }

    /// Writes the frames for a turn; returns their paths relative to the session.
    @discardableResult
    func writeFrames(_ frames: [TutorFrame], turn: Int) -> [String] {
        frames.enumerated().compactMap { index, frame in
            let fileName = String(format: "turn%04d-frame%d.jpg", turn, index + 1)
            do {
                try frame.jpegData.write(to: framesDirectory.appendingPathComponent(fileName), options: .atomic)
                return "frames/\(fileName)"
            } catch {
                return nil
            }
        }
    }

    func appendTranscript(speaker: String, text: String, trigger: String, at date: Date = Date()) {
        append(["ts": Self.timestampString(for: date), "speaker": speaker, "trigger": trigger, "text": text], to: transcriptFile)
    }

    func appendModelExchange(turn: Int, trigger: String, requestBody: [String: Any]?, frameFiles: [String], responseText: String?, errorDescription: String?, at date: Date = Date()) {
        var entry: [String: Any] = ["ts": Self.timestampString(for: date), "turn": turn, "trigger": trigger]
        if let requestBody { entry["request"] = Self.redactedRequestBody(requestBody, frameFiles: frameFiles) }
        if let responseText { entry["response"] = responseText }
        if let errorDescription { entry["error"] = errorDescription }
        append(entry, to: modelFile)
    }

    /// Replaces base64 data-URL images with frame file names, in order.
    static func redactedRequestBody(_ requestBody: [String: Any], frameFiles: [String]) -> [String: Any] {
        var remainingFrameFiles = frameFiles[...]
        func redact(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var redactedDictionary: [String: Any] = [:]
                for (key, nestedValue) in dictionary {
                    if key == "image_url", let dataURL = nestedValue as? String, dataURL.hasPrefix("data:") {
                        redactedDictionary[key] = remainingFrameFiles.popFirst() ?? "[image omitted]"
                    } else {
                        redactedDictionary[key] = redact(nestedValue)
                    }
                }
                return redactedDictionary
            }
            if let array = value as? [Any] { return array.map(redact) }
            return value
        }
        return redact(requestBody) as? [String: Any] ?? [:]
    }

    static func jsonLine(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object),
              var lineData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        lineData.append(0x0A)
        return lineData
    }

    private func append(_ object: [String: Any], to file: URL) {
        guard let lineData = Self.jsonLine(object) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        } else {
            try? lineData.write(to: file, options: .atomic)
        }
    }
}
