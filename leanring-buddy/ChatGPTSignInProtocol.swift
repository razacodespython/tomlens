//
//  ChatGPTSignInProtocol.swift
//  leanring-buddy
//
//  Pure protocol logic for Sign in with ChatGPT (SIWC) plan usage, following
//  developers.openai.com/siwc/token-sharing-open-source: OAuth authorization
//  code + PKCE (S256) with first-time dynamic registration
//  (client_id=dynamic_agent_client), a 127.0.0.1 loopback callback, token
//  exchange/refresh with resource=https://api.openai.com/v1, and ID-token
//  claim checks. No networking or Keychain here so it is testable anywhere;
//  ChatGPTSignInService does the I/O.
//

import Foundation

nonisolated enum ChatGPTSignInConfiguration {
    static let authorizeEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let openIDConfigurationURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let dynamicRegistrationClientID = "dynamic_agent_client"
    static let agentNameHint = "TomLens"
    static let identityScopes = ["openid", "profile", "email"]
    static let planUsageScopes = ["offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]
    static let planUsageScope = "chatgpt.tokens.use.direct"
    static let callbackPath = "/auth/callback"
    /// Preferred loopback port first; only the port may vary between attempts.
    static let callbackPorts: [UInt16] = [1455, 1456, 1457, 54321]
    static let manageUsageURL = URL(string: "https://chatgpt.com/settings/usage")!

    static func redirectURI(port: UInt16) -> String {
        "http://127.0.0.1:\(port)\(callbackPath)"
    }
}

/// One authorization attempt's secrets, kept in memory until the callback.
nonisolated struct ChatGPTAuthorizationAttempt: Equatable {
    let state: String
    let nonce: String
    let codeVerifier: String
    let redirectURI: String
    /// dynamic_agent_client for first registration, else the saved issued ID.
    let requestedClientID: String

    var isNewRegistration: Bool {
        requestedClientID == ChatGPTSignInConfiguration.dynamicRegistrationClientID
    }
}

/// Saved per ChatGPT account (Keychain). Never logged.
nonisolated struct ChatGPTCredentialRecord: Codable, Equatable {
    var email: String?
    var subject: String
    var issuedClientID: String
    var hostID: String
    var idToken: String
    var accessToken: String
    var refreshToken: String?
    var scopes: [String]
    var accessTokenExpiresAt: Date

    var hasPlanUsagePermission: Bool {
        scopes.contains(ChatGPTSignInConfiguration.planUsageScope)
    }

    /// Refresh five minutes before expiry so a call never races the deadline.
    func needsRefresh(now: Date, refreshMarginSeconds: TimeInterval = 300) -> Bool {
        now.addingTimeInterval(refreshMarginSeconds) >= accessTokenExpiresAt
    }
}

/// Token endpoint response (authorization_code and refresh_token grants).
nonisolated struct ChatGPTTokenResponse: Decodable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let tokenType: String?
    let expiresIn: Double?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }

    var grantedScopes: [String] {
        (scope ?? "").split(separator: " ").map(String.init).sorted()
    }
}

nonisolated struct ChatGPTIDTokenClaims: Decodable, Equatable {
    let issuer: String
    let subject: String
    let audience: [String]
    let expiresAt: Double
    let nonce: String?
    let email: String?

    enum CodingKeys: String, CodingKey {
        case issuer = "iss", subject = "sub", audience = "aud", expiresAt = "exp", nonce, email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issuer = try container.decode(String.self, forKey: .issuer)
        subject = try container.decode(String.self, forKey: .subject)
        if let singleAudience = try? container.decode(String.self, forKey: .audience) {
            audience = [singleAudience]
        } else {
            audience = try container.decode([String].self, forKey: .audience)
        }
        expiresAt = try container.decode(Double.self, forKey: .expiresAt)
        nonce = try container.decodeIfPresent(String.self, forKey: .nonce)
        email = try container.decodeIfPresent(String.self, forKey: .email)
    }
}

/// A decoded (not yet signature-verified) JWT.
nonisolated struct DecodedJSONWebToken {
    let headerJSON: [String: Any]
    let payloadData: Data
    let signingInput: Data
    let signature: Data

    var keyID: String? { headerJSON["kid"] as? String }
    var algorithm: String? { headerJSON["alg"] as? String }
}

nonisolated enum ChatGPTSignInError: LocalizedError, Equatable {
    case stateMismatch
    case accessDenied
    case authorizationFailed(String)
    case missingAuthorizationCode
    case registrationIncomplete
    case clientIDMismatch
    case invalidIDToken(String)
    case planUsageNotGranted
    case notSignedIn
    case refreshTokenUnusable
    case tokenEndpointFailed(String)

    var errorDescription: String? {
        switch self {
        case .stateMismatch: return "The ChatGPT sign-in response didn't match this attempt. Please try again."
        case .accessDenied: return "ChatGPT sign-in was cancelled or plan usage was declined."
        case .authorizationFailed(let message): return "ChatGPT sign-in failed: \(message)"
        case .missingAuthorizationCode: return "ChatGPT didn't return an authorization code."
        case .registrationIncomplete: return "ChatGPT didn't finish registering TomLens. Please try again."
        case .clientIDMismatch: return "ChatGPT returned a different app registration; sign-in was rejected."
        case .invalidIDToken(let reason): return "ChatGPT's identity token was invalid (\(reason))."
        case .planUsageNotGranted: return "You're signed in, but ChatGPT plan usage isn't enabled for TomLens."
        case .notSignedIn: return "Sign in with ChatGPT in the TomLens menu first."
        case .refreshTokenUnusable: return "Your ChatGPT session expired. Please sign in again."
        case .tokenEndpointFailed(let message): return "ChatGPT token request failed: \(message)"
        }
    }
}

nonisolated enum ChatGPTSignInProtocol {

    // MARK: - Random values and PKCE

    /// URL-safe random string from 32 bytes (43 base64url chars), used for
    /// state, nonce and the PKCE verifier.
    static func makeRandomURLSafeString(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let randomBytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URLEncodedString(Data(randomBytes))
    }

    static func base64URLEncodedString(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecodedData(_ base64URLString: String) -> Data? {
        var base64String = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64String.count % 4 != 0 { base64String.append("=") }
        return Data(base64Encoded: base64String)
    }

    /// S256 code challenge: base64url(SHA-256(verifier)) without padding.
    /// The digest is injected (CryptoKit on macOS) to keep this file pure.
    static func codeChallenge(forVerifier codeVerifier: String, sha256: (Data) -> Data) -> String {
        base64URLEncodedString(sha256(Data(codeVerifier.utf8)))
    }

    static func makeHostID() -> String {
        "urn:uuid:\(UUID().uuidString.lowercased())"
    }

    // MARK: - Authorization request

    static func makeAttempt(savedIssuedClientID: String?, redirectURI: String) -> ChatGPTAuthorizationAttempt {
        ChatGPTAuthorizationAttempt(
            state: makeRandomURLSafeString(),
            nonce: makeRandomURLSafeString(),
            codeVerifier: makeRandomURLSafeString(),
            redirectURI: redirectURI,
            requestedClientID: savedIssuedClientID ?? ChatGPTSignInConfiguration.dynamicRegistrationClientID
        )
    }

    /// The browser URL. Contains no tokens except an optional id_token_hint;
    /// never log it.
    static func authorizationURL(
        for attempt: ChatGPTAuthorizationAttempt,
        hostID: String,
        codeChallenge: String,
        idTokenHint: String?,
        loginHint: String?
    ) -> URL {
        var queryItems = [
            URLQueryItem(name: "client_id", value: attempt.requestedClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: attempt.redirectURI),
            URLQueryItem(name: "scope", value: (ChatGPTSignInConfiguration.identityScopes + ChatGPTSignInConfiguration.planUsageScopes).joined(separator: " ")),
            URLQueryItem(name: "resource", value: ChatGPTSignInConfiguration.resource),
            URLQueryItem(name: "state", value: attempt.state),
            URLQueryItem(name: "nonce", value: attempt.nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
        ]
        if attempt.isNewRegistration {
            queryItems.append(URLQueryItem(name: "agent_name_hint", value: ChatGPTSignInConfiguration.agentNameHint))
        } else {
            if let idTokenHint { queryItems.append(URLQueryItem(name: "id_token_hint", value: idTokenHint)) }
            if let loginHint { queryItems.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        }
        var components = URLComponents(url: ChatGPTSignInConfiguration.authorizeEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        // URLComponents leaves '+' unescaped in queries; encode it explicitly.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    // MARK: - Callback

    struct CallbackResult: Equatable {
        let authorizationCode: String
        /// The client ID to use for the code exchange (issued ID, never dynamic_agent_client).
        let issuedClientID: String
    }

    /// Validates the loopback callback's query against the pending attempt.
    static func parseCallback(queryItems: [URLQueryItem], attempt: ChatGPTAuthorizationAttempt) throws -> CallbackResult {
        func value(_ name: String) -> String? { queryItems.first(where: { $0.name == name })?.value }

        guard value("state") == attempt.state else { throw ChatGPTSignInError.stateMismatch }
        if let errorCode = value("error") {
            if errorCode == "access_denied" { throw ChatGPTSignInError.accessDenied }
            throw ChatGPTSignInError.authorizationFailed(value("error_description") ?? errorCode)
        }
        guard let authorizationCode = value("code"), !authorizationCode.isEmpty else {
            throw ChatGPTSignInError.missingAuthorizationCode
        }

        let returnedClientID = value("client_id")
        if attempt.isNewRegistration {
            guard let returnedClientID, !returnedClientID.isEmpty,
                  returnedClientID != ChatGPTSignInConfiguration.dynamicRegistrationClientID else {
                throw ChatGPTSignInError.registrationIncomplete
            }
            return CallbackResult(authorizationCode: authorizationCode, issuedClientID: returnedClientID)
        }
        if let returnedClientID, returnedClientID != attempt.requestedClientID {
            throw ChatGPTSignInError.clientIDMismatch
        }
        return CallbackResult(authorizationCode: authorizationCode, issuedClientID: attempt.requestedClientID)
    }

    /// Parses "GET /auth/callback?code=...&state=... HTTP/1.1" from the
    /// loopback listener. Returns nil for any other path.
    static func callbackQueryItems(fromHTTPRequestLine requestLine: String) -> [URLQueryItem]? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path == ChatGPTSignInConfiguration.callbackPath else {
            return nil
        }
        return components.queryItems ?? []
    }

    // MARK: - Token requests

    static func formEncodedBody(_ fields: [(String, String)]) -> Data {
        var allowedCharacters = CharacterSet.alphanumerics
        allowedCharacters.insert(charactersIn: "-._~")
        let body = fields
            .map { name, value in
                "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    static func authorizationCodeExchangeBody(callback: CallbackResult, attempt: ChatGPTAuthorizationAttempt) -> Data {
        formEncodedBody([
            ("grant_type", "authorization_code"),
            ("client_id", callback.issuedClientID),
            ("code", callback.authorizationCode),
            ("code_verifier", attempt.codeVerifier),
            ("redirect_uri", attempt.redirectURI),
            ("resource", ChatGPTSignInConfiguration.resource),
        ])
    }

    /// Omits scope so the existing grant is retained.
    static func refreshBody(for credentialRecord: ChatGPTCredentialRecord) -> Data? {
        guard let refreshToken = credentialRecord.refreshToken else { return nil }
        return formEncodedBody([
            ("grant_type", "refresh_token"),
            ("client_id", credentialRecord.issuedClientID),
            ("refresh_token", refreshToken),
            ("resource", ChatGPTSignInConfiguration.resource),
        ])
    }

    /// Refresh error codes after which the token set is unusable and the user must sign in again.
    static let unusableRefreshErrorCodes: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused",
    ]

    static func isUnusableRefreshError(responseBody: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any] else { return false }
        let errorCode = (json["error"] as? String) ?? ((json["error"] as? [String: Any])?["code"] as? String)
        return errorCode.map { unusableRefreshErrorCodes.contains($0) } ?? false
    }

    // MARK: - ID token

    static func decodeJSONWebToken(_ token: String) throws -> DecodedJSONWebToken {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 3,
              let headerData = base64URLDecodedData(segments[0]),
              let headerJSON = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payloadData = base64URLDecodedData(segments[1]),
              let signature = base64URLDecodedData(segments[2]) else {
            throw ChatGPTSignInError.invalidIDToken("malformed")
        }
        return DecodedJSONWebToken(
            headerJSON: headerJSON,
            payloadData: payloadData,
            signingInput: Data("\(segments[0]).\(segments[1])".utf8),
            signature: signature
        )
    }

    /// Checks issuer, audience (issued client ID), expiry and nonce. The RS256
    /// signature is checked separately against OpenAI's JWKS.
    static func validatedClaims(
        of decodedToken: DecodedJSONWebToken,
        issuedClientID: String,
        expectedNonce: String?,
        now: Date
    ) throws -> ChatGPTIDTokenClaims {
        guard decodedToken.algorithm == "RS256" else { throw ChatGPTSignInError.invalidIDToken("unexpected algorithm") }
        guard let claims = try? JSONDecoder().decode(ChatGPTIDTokenClaims.self, from: decodedToken.payloadData) else {
            throw ChatGPTSignInError.invalidIDToken("unreadable claims")
        }
        guard claims.issuer == ChatGPTSignInConfiguration.issuer else { throw ChatGPTSignInError.invalidIDToken("wrong issuer") }
        guard claims.audience.contains(issuedClientID) else { throw ChatGPTSignInError.invalidIDToken("wrong audience") }
        guard Date(timeIntervalSince1970: claims.expiresAt) > now else { throw ChatGPTSignInError.invalidIDToken("expired") }
        if let expectedNonce, claims.nonce != expectedNonce { throw ChatGPTSignInError.invalidIDToken("nonce mismatch") }
        return claims
    }

    static func credentialRecord(
        from tokenResponse: ChatGPTTokenResponse,
        claims: ChatGPTIDTokenClaims,
        issuedClientID: String,
        hostID: String,
        receivedAt: Date
    ) -> ChatGPTCredentialRecord {
        ChatGPTCredentialRecord(
            email: claims.email,
            subject: claims.subject,
            issuedClientID: issuedClientID,
            hostID: hostID,
            idToken: tokenResponse.idToken ?? "",
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            scopes: tokenResponse.grantedScopes,
            accessTokenExpiresAt: receivedAt.addingTimeInterval(tokenResponse.expiresIn ?? 3600)
        )
    }

    /// Replaces access token, expiry, scopes and the rotating refresh token together.
    static func refreshedRecord(_ record: ChatGPTCredentialRecord, with tokenResponse: ChatGPTTokenResponse, receivedAt: Date) -> ChatGPTCredentialRecord {
        var refreshedRecord = record
        refreshedRecord.accessToken = tokenResponse.accessToken
        refreshedRecord.refreshToken = tokenResponse.refreshToken ?? record.refreshToken
        if tokenResponse.scope != nil { refreshedRecord.scopes = tokenResponse.grantedScopes }
        if let idToken = tokenResponse.idToken { refreshedRecord.idToken = idToken }
        refreshedRecord.accessTokenExpiresAt = receivedAt.addingTimeInterval(tokenResponse.expiresIn ?? 3600)
        return refreshedRecord
    }

    // MARK: - JWKS -> RSA public key (PKCS#1 DER) for SecKeyCreateWithData

    static func pkcs1RSAPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func derLength(_ length: Int) -> Data {
            if length < 0x80 { return Data([UInt8(length)]) }
            var lengthBytes: [UInt8] = []
            var remaining = length
            while remaining > 0 { lengthBytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 }
            return Data([0x80 | UInt8(lengthBytes.count)] + lengthBytes)
        }
        func derInteger(_ unsignedBigEndian: Data) -> Data {
            var integerBytes = Data(unsignedBigEndian.drop(while: { $0 == 0 }))
            if integerBytes.isEmpty { integerBytes = Data([0]) }
            if integerBytes.first! & 0x80 != 0 { integerBytes.insert(0, at: 0) }
            return Data([0x02]) + derLength(integerBytes.count) + integerBytes
        }
        let sequenceContent = derInteger(modulus) + derInteger(exponent)
        return Data([0x30]) + derLength(sequenceContent.count) + sequenceContent
    }
}
