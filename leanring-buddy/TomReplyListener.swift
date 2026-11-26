//
//  TomReplyListener.swift
//  leanring-buddy
//
//  Outbound HTTPS stream of the private ntfy topic. Runs only while the
//  menu-bar switch is on. Lines are handed to the caller unlogged: an ntfy
//  line contains the topic, and the topic must not reach a log or the journal.
//

import Foundation

@MainActor
final class TomReplyListener {
    private var listenTask: Task<Void, Never>?
    private var shouldListen = false

    func start(topic: String, onLine: @escaping @MainActor (String) -> Void) {
        stop()
        guard let streamURL = TomNetworkAllowlist.ntfyJSONStreamURL(topic: topic) else { return }
        shouldListen = true
        listenTask = Task { [weak self] in
            var failureCount = 0
            while !Task.isCancelled, self?.shouldListen == true {
                do {
                    try TomNetworkAllowlist.validate(streamURL, configuredWebhookURL: nil)
                    var request = URLRequest(url: streamURL)
                    request.timeoutInterval = 3_600
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard statusCode == 200 else { throw URLError(.badServerResponse) }
                    failureCount = 0
                    for try await line in bytes.lines {
                        if Task.isCancelled || self?.shouldListen != true { return }
                        onLine(line)
                    }
                } catch {
                    if Task.isCancelled || self?.shouldListen != true { return }
                    failureCount += 1
                    let delaySeconds = min(30, pow(2.0, Double(min(failureCount, 5))))
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
            }
        }
    }

    func stop() {
        shouldListen = false
        listenTask?.cancel()
        listenTask = nil
    }
}
