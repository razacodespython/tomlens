//
//  ChatGPTSignInService.swift
//  leanring-buddy
//
//  macOS side of Sign in with ChatGPT: opens the browser, receives the
//  loopback callback on 127.0.0.1, exchanges the code, verifies the ID
//  token's RS256 signature against OpenAI's JWKS, stores the credential
//  record in the Keychain and serializes refreshes. Tokens are never
//  printed, journaled or put in URLs (the browser URL may carry an
//  id_token_hint and is never logged).
//

import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

// MARK: - Keychain

nonisolated enum TomLensKeychainStore {
    static let service = "com.razacodespython.tomlens.chatgpt"
    static let credentialAccount = "chatgpt-credential-record"
    static let apiKeyAccount = "openai-api-key-fallback"

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess { print("🔐 Keychain save failed (status \(status))") }
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Optional pay-as-you-go fallback with the user's own OpenAI API key.
/// Disabled by default and never used automatically when plan usage fails:
/// it is only used when explicitly enabled AND no ChatGPT sign-in exists.
/// Enable with: defaults write com.razacodespython.tomlens TomLensAPIKeyFallbackEnabled -bool YES
/// and store the key in the Keychain item (service above, account openai-api-key-fallback).
nonisolated enum TomLensAPIKeyFallback {
    static let enabledDefaultsKey = "TomLensAPIKeyFallbackEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    static var storedAPIKey: String? {
        guard isEnabled, let keyData = TomLensKeychainStore.load(account: TomLensKeychainStore.apiKeyAccount) else { return nil }
        let apiKey = String(decoding: keyData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return apiKey.isEmpty ? nil : apiKey
    }
}

// MARK: - Loopback callback server

/// Accepts exactly one GET /auth/callback on 127.0.0.1, then stops.
nonisolated final class ChatGPTLoopbackCallbackServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.razacodespython.tomlens.oauth-callback")
    private var continuation: CheckedContinuation<[URLQueryItem], Error>?
    let port: UInt16

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.port = port
    }

    func waitForCallback(timeoutSeconds: TimeInterval = 300) async throws -> [URLQueryItem] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                self.listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state { self?.finish(.failure(error)) }
                }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    self?.finish(.failure(ChatGPTSignInError.authorizationFailed("timed out waiting for the browser")))
                }
            }
        }
    }

    func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let requestText = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let requestLine = requestText.components(separatedBy: "\r\n").first ?? ""
            let queryItems = ChatGPTSignInProtocol.callbackQueryItems(fromHTTPRequestLine: requestLine)
            let html = queryItems == nil
                ? "Not found"
                : "<html><body style=\"font-family:-apple-system\"><h3>TomLens: you can close this tab.</h3></body></html>"
            let response = "HTTP/1.1 \(queryItems == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let queryItems { self.finish(.success(queryItems)) }
        }
    }

    private func finish(_ result: Result<[URLQueryItem], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        listener.cancel()
        continuation.resume(with: result)
    }
}

// MARK: - Sign-in service

@MainActor
final class ChatGPTSignInService: ObservableObject {
    static let shared = ChatGPTSignInService()

    private static let issuedClientIDDefaultsKey = "TomLensChatGPTIssuedClientID"
    private static let hostIDDefaultsKey = "TomLensChatGPTHostID"
    private static let selectedModelDefaultsKey = "TomLensChatGPTSelectedModel"

    @Published private(set) var signedInEmail: String?
    @Published private(set) var hasPlanUsagePermission = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var availableModels: [ChatGPTModelChoice] = []
    @Published var selectedModelSlug: String? {
        didSet { UserDefaults.standard.set(selectedModelSlug, forKey: Self.selectedModelDefaultsKey) }
    }

    private var credentialRecord: ChatGPTCredentialRecord?
    private var inFlightRefreshTask: Task<ChatGPTCredentialRecord, Error>?
    private var activeCallbackServer: ChatGPTLoopbackCallbackServer?

    private init() {
        selectedModelSlug = UserDefaults.standard.string(forKey: Self.selectedModelDefaultsKey)
        if let recordData = TomLensKeychainStore.load(account: TomLensKeychainStore.credentialAccount),
           let savedRecord = try? JSONDecoder().decode(ChatGPTCredentialRecord.self, from: recordData) {
            applyCredentialRecord(savedRecord)
        }
    }

    var isSignedIn: Bool { credentialRecord != nil }

    private var hostID: String {
        if let savedHostID = UserDefaults.standard.string(forKey: Self.hostIDDefaultsKey) { return savedHostID }
        let newHostID = ChatGPTSignInProtocol.makeHostID()
        UserDefaults.standard.set(newHostID, forKey: Self.hostIDDefaultsKey)
        return newHostID
    }

    // MARK: Sign in / out

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        lastErrorMessage = nil
        Task {
            defer { isSigningIn = false; activeCallbackServer = nil }
            do {
                try await performSignIn()
                await refreshModelCatalog()
            } catch is CancellationError {
                // User closed or retried; nothing to report.
            } catch {
                lastErrorMessage = error.localizedDescription
                print("🔐 ChatGPT sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelSignIn() {
        activeCallbackServer?.stop()
    }

    func signOut() {
        let recordToRevoke = credentialRecord
        TomLensKeychainStore.delete(account: TomLensKeychainStore.credentialAccount)
        credentialRecord = nil
        signedInEmail = nil
        hasPlanUsagePermission = false
        availableModels = []
        // The issued client ID and host ID are kept so the next sign-in reuses the registration.
        if let recordToRevoke { Task { await Self.revokeRefreshToken(of: recordToRevoke) } }
    }

    func openManageUsagePage() {
        NSWorkspace.shared.open(ChatGPTSignInConfiguration.manageUsageURL)
    }

    private func performSignIn() async throws {
        let callbackServer = try Self.startCallbackServerOnFirstFreePort()
        activeCallbackServer = callbackServer

        let savedIssuedClientID = UserDefaults.standard.string(forKey: Self.issuedClientIDDefaultsKey)
        let attempt = ChatGPTSignInProtocol.makeAttempt(
            savedIssuedClientID: savedIssuedClientID,
            redirectURI: ChatGPTSignInConfiguration.redirectURI(port: callbackServer.port)
        )
        let codeChallenge = ChatGPTSignInProtocol.codeChallenge(forVerifier: attempt.codeVerifier) { Data(SHA256.hash(data: $0)) }
        let authorizationURL = ChatGPTSignInProtocol.authorizationURL(
            for: attempt,
            hostID: hostID,
            codeChallenge: codeChallenge,
            idTokenHint: credentialRecord?.idToken,
            loginHint: credentialRecord?.email
        )

        async let callbackQueryItems = callbackServer.waitForCallback()
        print("🔐 Opening ChatGPT sign-in in the browser")
        NSWorkspace.shared.open(authorizationURL)
        let callback = try ChatGPTSignInProtocol.parseCallback(queryItems: try await callbackQueryItems, attempt: attempt)

        // Save the issued client ID before the exchange so a failed exchange never re-registers.
        UserDefaults.standard.set(callback.issuedClientID, forKey: Self.issuedClientIDDefaultsKey)

        let tokenResponse = try await Self.postTokenRequest(
            body: ChatGPTSignInProtocol.authorizationCodeExchangeBody(callback: callback, attempt: attempt)
        )
        guard let idToken = tokenResponse.idToken else { throw ChatGPTSignInError.invalidIDToken("missing") }
        let claims = try await Self.verifiedClaims(
            ofIDToken: idToken,
            issuedClientID: callback.issuedClientID,
            expectedNonce: attempt.nonce
        )
        let newRecord = ChatGPTSignInProtocol.credentialRecord(
            from: tokenResponse,
            claims: claims,
            issuedClientID: callback.issuedClientID,
            hostID: hostID,
            receivedAt: Date()
        )
        persist(newRecord)
        if !newRecord.hasPlanUsagePermission {
            lastErrorMessage = ChatGPTSignInError.planUsageNotGranted.errorDescription
        }
    }

    private static func startCallbackServerOnFirstFreePort() throws -> ChatGPTLoopbackCallbackServer {
        var lastError: Error = ChatGPTSignInError.authorizationFailed("no free loopback port")
        for port in ChatGPTSignInConfiguration.callbackPorts {
            do { return try ChatGPTLoopbackCallbackServer(port: port) } catch { lastError = error }
        }
        throw lastError
    }

    // MARK: Access tokens

    /// Returns a valid plan-usage access token, refreshing first if needed.
    /// Concurrent callers share one refresh (refresh tokens rotate).
    func validPlanUsageAccessToken() async throws -> String {
        guard let currentRecord = credentialRecord else { throw ChatGPTSignInError.notSignedIn }
        guard currentRecord.hasPlanUsagePermission else { throw ChatGPTSignInError.planUsageNotGranted }
        guard currentRecord.needsRefresh(now: Date()) else { return currentRecord.accessToken }

        if let inFlightRefreshTask { return try await inFlightRefreshTask.value.accessToken }
        let refreshTask = Task { () throws -> ChatGPTCredentialRecord in
            guard let refreshBody = ChatGPTSignInProtocol.refreshBody(for: currentRecord) else {
                throw ChatGPTSignInError.refreshTokenUnusable
            }
            let tokenResponse = try await Self.postTokenRequest(body: refreshBody)
            return ChatGPTSignInProtocol.refreshedRecord(currentRecord, with: tokenResponse, receivedAt: Date())
        }
        inFlightRefreshTask = refreshTask
        defer { inFlightRefreshTask = nil }
        do {
            let refreshedRecord = try await refreshTask.value
            persist(refreshedRecord)
            return refreshedRecord.accessToken
        } catch ChatGPTSignInError.refreshTokenUnusable {
            // Terminal refresh error: clear tokens, keep the client ID for re-auth.
            signOut()
            throw ChatGPTSignInError.refreshTokenUnusable
        }
    }

    /// Called when inference returns a confirmed sign-in rejection.
    func markSignInRejected() {
        lastErrorMessage = ResponsesAPIError.signInRejected.errorDescription
    }

    func refreshModelCatalog() async {
        guard let accessToken = try? await validPlanUsageAccessToken() else { return }
        var request = URLRequest(url: ChatGPTModelCatalog.modelsEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (body, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        availableModels = ChatGPTModelCatalog.listedModels(fromResponseBody: body)
        if let selectedModelSlug, availableModels.contains(where: { $0.slug == selectedModelSlug }) { return }
        selectedModelSlug = availableModels.first?.slug
    }

    // MARK: Persistence

    private func persist(_ record: ChatGPTCredentialRecord) {
        if let recordData = try? JSONEncoder().encode(record) {
            TomLensKeychainStore.save(recordData, account: TomLensKeychainStore.credentialAccount)
        }
        applyCredentialRecord(record)
    }

    private func applyCredentialRecord(_ record: ChatGPTCredentialRecord) {
        credentialRecord = record
        signedInEmail = record.email ?? "ChatGPT account"
        hasPlanUsagePermission = record.hasPlanUsagePermission
    }

    // MARK: HTTP

    private static func postTokenRequest(body: Data) async throws -> ChatGPTTokenResponse {
        var request = URLRequest(url: ChatGPTSignInConfiguration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (responseBody, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            if ChatGPTSignInProtocol.isUnusableRefreshError(responseBody: responseBody) {
                throw ChatGPTSignInError.refreshTokenUnusable
            }
            throw ChatGPTSignInError.tokenEndpointFailed("status \(statusCode)")
        }
        return try JSONDecoder().decode(ChatGPTTokenResponse.self, from: responseBody)
    }

    private static func openIDConfiguration() async throws -> [String: Any] {
        let (body, _) = try await URLSession.shared.data(from: ChatGPTSignInConfiguration.openIDConfigurationURL)
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ChatGPTSignInError.invalidIDToken("no OpenID configuration")
        }
        return json
    }

    /// Verifies the RS256 signature with the JWKS key matching `kid`, then the claims.
    private static func verifiedClaims(ofIDToken idToken: String, issuedClientID: String, expectedNonce: String) async throws -> ChatGPTIDTokenClaims {
        let decodedToken = try ChatGPTSignInProtocol.decodeJSONWebToken(idToken)
        let configuration = try await openIDConfiguration()
        guard let jwksURLString = configuration["jwks_uri"] as? String, let jwksURL = URL(string: jwksURLString) else {
            throw ChatGPTSignInError.invalidIDToken("no JWKS")
        }
        let (jwksBody, _) = try await URLSession.shared.data(from: jwksURL)
        let jwks = (try? JSONSerialization.jsonObject(with: jwksBody) as? [String: Any])?["keys"] as? [[String: Any]] ?? []
        guard let matchingKey = jwks.first(where: { ($0["kid"] as? String) == decodedToken.keyID && ($0["kty"] as? String) == "RSA" }),
              let modulus = (matchingKey["n"] as? String).flatMap(ChatGPTSignInProtocol.base64URLDecodedData),
              let exponent = (matchingKey["e"] as? String).flatMap(ChatGPTSignInProtocol.base64URLDecodedData) else {
            throw ChatGPTSignInError.invalidIDToken("signing key not found")
        }
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let publicKey = SecKeyCreateWithData(
            ChatGPTSignInProtocol.pkcs1RSAPublicKeyDER(modulus: modulus, exponent: exponent) as CFData,
            keyAttributes as CFDictionary,
            nil
        ), SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            decodedToken.signingInput as CFData,
            decodedToken.signature as CFData,
            nil
        ) else {
            throw ChatGPTSignInError.invalidIDToken("bad signature")
        }
        return try ChatGPTSignInProtocol.validatedClaims(
            of: decodedToken,
            issuedClientID: issuedClientID,
            expectedNonce: expectedNonce,
            now: Date()
        )
    }

    private static func revokeRefreshToken(of record: ChatGPTCredentialRecord) async {
        guard let refreshToken = record.refreshToken,
              let configuration = try? await openIDConfiguration(),
              let revocationURLString = configuration["revocation_endpoint"] as? String,
              let revocationURL = URL(string: revocationURLString) else { return }
        var request = URLRequest(url: revocationURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatGPTSignInProtocol.formEncodedBody([
            ("token", refreshToken),
            ("token_type_hint", "refresh_token"),
            ("client_id", record.issuedClientID),
        ])
        _ = try? await URLSession.shared.data(for: request)
    }
}
