//
//  ResponsesAPIProtocolTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import TomLens

struct ResponsesAPIProtocolTests {

    @Test func requestIsStorelessStreamingAndOmitsUnsupportedFields() throws {
        let body = ResponsesRequestBuilder.requestBody(
            model: "gpt-x", instructions: "be tom",
            conversationHistory: [ResponsesConversationTurn(userText: "hi", assistantText: "hello")],
            images: [ResponsesInputImage(jpegData: Data([0xFF, 0xD8]), label: "frame 1")],
            userPrompt: "is this a fork?"
        )
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["instructions"] as? String == "be tom")
        #expect(Set(body.keys).isDisjoint(with: ResponsesRequestBuilder.unsupportedTopLevelFields))
        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.count == 3)
        #expect(!input.contains { ($0["role"] as? String) == "system" })
        let lastContent = try #require(input.last?["content"] as? [[String: Any]])
        #expect(lastContent[1]["image_url"] as? String == "data:image/jpeg;base64,/9g=")
        #expect(lastContent.last?["text"] as? String == "is this a fork?")
        _ = try ResponsesRequestBuilder.requestBodyData(body)
    }

    @Test func streamParserAccumulatesDeltasAndCompletes() {
        var parser = ResponsesStreamParser()
        var events: [ResponsesStreamParser.StreamEvent] = []
        let stream = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Wait "}

        data: {"type":"response.output_text.delta","delta":"for close."}

        : keep-alive

        data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"Wait for close."}]}]}}

        """
        for line in stream.components(separatedBy: "\n") {
            if let event = parser.consume(line: line) { events.append(event) }
        }
        #expect(events == [.textDelta("Wait "), .textDelta("for close."), .completed(fullText: "Wait for close.")])
    }

    @Test func streamParserReportsFailuresAndIncomplete() {
        #expect(ResponsesStreamParser.event(fromDataPayload: #"{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"m"}}}"#)
                == .failed(code: "subscription_sharing_usage_limit_exceeded", message: "m"))
        #expect(ResponsesStreamParser.event(fromDataPayload: #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max"}}}"#) == .incomplete(reason: "max"))
        #expect(ResponsesStreamParser.event(fromDataPayload: "[DONE]") == .ignored)
        var parser = ResponsesStreamParser()
        _ = parser.consume(line: #"data: {"type":"response.output_text.delta","delta":"x"}"#)
        #expect(parser.finish() == .textDelta("x"))
    }

    @Test func errorsMapToPauseWithoutPaidFallback() {
        let limit = ResponsesErrorClassifier.error(httpStatus: 429, responseBody: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#.utf8))
        #expect(limit == .usageLimitReached)
        #expect(limit.pausesAutomaticCalls)
        #expect(ResponsesErrorClassifier.error(httpStatus: 401, responseBody: Data(#"{"detail":"nope"}"#.utf8)) == .signInRejected)
        #expect(ResponsesErrorClassifier.error(httpStatus: 503, responseBody: Data()) == .temporarilyUnavailable)
        #expect(ResponsesErrorClassifier.error(httpStatus: 400, responseBody: Data(#"{"error":{"code":"subscription_sharing_unsupported_capability","param":"temperature"}}"#.utf8)) == .unsupportedCapability("temperature"))
    }

    @Test func modelCatalogKeepsListedModelsInOrder() {
        let body = Data(#"{"models":[{"slug":"a","display_name":"A","visibility":"list"},{"slug":"h","visibility":"hide"},{"slug":"b","visibility":"list"}]}"#.utf8)
        #expect(ChatGPTModelCatalog.listedModels(fromResponseBody: body) == [
            ChatGPTModelChoice(slug: "a", displayName: "A"), ChatGPTModelChoice(slug: "b", displayName: "b"),
        ])
    }

    @Test func callCapDefaultsToFortyPerHourAndSlides() {
        let limiter = ModelCallRateLimiter()
        #expect(limiter.maximumCallsPerWindow == 40)
        let start = Date(timeIntervalSince1970: 0)
        for second in 0..<40 { #expect(limiter.reserveCall(now: start.addingTimeInterval(Double(second))) == nil) }
        #expect(limiter.reserveCall(now: start.addingTimeInterval(100)) == 3500)
        #expect(limiter.remainingCalls(now: start.addingTimeInterval(100)) == 0)
        #expect(limiter.reserveCall(now: start.addingTimeInterval(3600)) == nil)
    }
}
