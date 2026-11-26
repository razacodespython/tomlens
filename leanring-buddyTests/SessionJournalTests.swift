//
//  SessionJournalTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import TomLens

struct SessionJournalTests {

    private func makeTemporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tomlens-journal-\(UUID().uuidString)", isDirectory: true)
    }

    private func jsonLines(_ file: URL) throws -> [[String: Any]] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    @Test func defaultRootIsTomLensJournalInHome() {
        #expect(SessionJournal.defaultRootDirectory.path.hasSuffix("/TomLens/journal"))
    }

    @Test func sessionFolderIsNamedByLocalStartTime() {
        let hongKong = TimeZone(identifier: "Asia/Hong_Kong")!
        // 2026-11-26 14:40:05 UTC == 22:40:05 HKT
        #expect(SessionJournal.sessionDirectoryName(for: Date(timeIntervalSince1970: 1_795_704_005), timeZone: hongKong) == "20261126-224005")
    }

    @Test func writesFramesTranscriptAndRedactedModelExchanges() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try SessionJournal(rootDirectory: root, startedAt: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!)
        #expect(journal.sessionDirectory.lastPathComponent == "19700101-000000")

        let turn = journal.beginTurn()
        let frames = [
            TutorFrame(jpegData: Data([0xFF, 0xD8, 1]), widthInPixels: 1024, heightInPixels: 640, capturedAt: Date()),
            TutorFrame(jpegData: Data([0xFF, 0xD8, 2]), widthInPixels: 1024, heightInPixels: 640, capturedAt: Date()),
        ]
        let frameFiles = journal.writeFrames(frames, turn: turn)
        #expect(frameFiles == ["frames/turn0001-frame1.jpg", "frames/turn0001-frame2.jpg"])
        #expect(try Data(contentsOf: journal.sessionDirectory.appendingPathComponent(frameFiles[1])) == Data([0xFF, 0xD8, 2]))

        journal.appendTranscript(speaker: "raza", text: "is this a fork?", trigger: "push_to_talk")
        journal.appendTranscript(speaker: "tom", text: "Wait for the close.", trigger: "push_to_talk")
        let requestBody = ResponsesRequestBuilder.requestBody(
            model: "m", instructions: "be tom", conversationHistory: [],
            images: frames.map { ResponsesInputImage(jpegData: $0.jpegData, label: "f") }, userPrompt: "is this a fork?"
        )
        journal.appendModelExchange(turn: turn, trigger: "push_to_talk", requestBody: requestBody, frameFiles: frameFiles,
                                    responseText: "Wait for the close. <summary>s</summary>", errorDescription: nil)
        journal.appendModelExchange(turn: 2, trigger: "bar_close", requestBody: nil, frameFiles: [], responseText: nil, errorDescription: "cap")

        let transcript = try jsonLines(journal.transcriptFile)
        #expect(transcript.map { $0["speaker"] as? String } == ["raza", "tom"])
        let model = try jsonLines(journal.modelFile)
        #expect(model.count == 2)
        #expect(model[1]["error"] as? String == "cap")

        let modelText = try String(contentsOf: journal.modelFile, encoding: .utf8)
        #expect(!modelText.contains("base64"))
        #expect(modelText.contains("frames/turn0001-frame1.jpg"))
        #expect(modelText.contains("\"store\":false"))
    }

    @Test func redactionReplacesEveryDataURLInOrder() {
        let body: [String: Any] = ["input": [["content": [
            ["type": "input_image", "image_url": "data:image/jpeg;base64,AAA"],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,BBB"],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,CCC"],
        ]]]]
        let redacted = SessionJournal.redactedRequestBody(body, frameFiles: ["a.jpg", "b.jpg"])
        let content = ((redacted["input"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        #expect(content.compactMap { $0["image_url"] as? String } == ["a.jpg", "b.jpg", "[image omitted]"])
    }
}
