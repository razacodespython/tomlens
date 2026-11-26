//
//  ChatGPTSignInProtocolTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import TomLens

struct ChatGPTSignInProtocolTests {

    private func makeAttempt(clientID: String = ChatGPTSignInConfiguration.dynamicRegistrationClientID) -> ChatGPTAuthorizationAttempt {
        ChatGPTAuthorizationAttempt(
            state: "state123", nonce: "nonce456", codeVerifier: "verifier",
            redirectURI: ChatGPTSignInConfiguration.redirectURI(port: 1455), requestedClientID: clientID
        )
    }

    private func queryItems(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func pkceChallengeMatchesRFC7636Example() {
        // SHA-256 of the RFC 7636 example verifier, injected as CryptoKit would compute it.
        let digest = Data([19, 211, 30, 150, 26, 26, 216, 236, 47, 22, 177, 12, 76, 152, 46, 8,
                           118, 168, 120, 173, 109, 241, 68, 86, 110, 225, 137, 74, 203, 112, 249, 195])
        let challenge = ChatGPTSignInProtocol.codeChallenge(forVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") { _ in digest }
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func randomValuesAreURLSafeAndLongEnoughForPKCE() {
        let value = ChatGPTSignInProtocol.makeRandomURLSafeString()
        #expect(value.count == 43)
        #expect(!value.contains("+") && !value.contains("/") && !value.contains("="))
        #expect(value != ChatGPTSignInProtocol.makeRandomURLSafeString())
    }

    @Test func firstSignInRegistersDynamicallyWithAllScopes() {
        let url = ChatGPTSignInProtocol.authorizationURL(
            for: makeAttempt(), hostID: "urn:uuid:abc", codeChallenge: "chal",
            idTokenHint: "should-not-appear", loginHint: nil
        )
        let query = queryItems(of: url)
        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/api/accounts/authorize?"))
        #expect(query["client_id"] == "dynamic_agent_client")
        #expect(query["agent_name_hint"] == "TomLens")
        #expect(query["redirect_uri"] == "http://127.0.0.1:1455/auth/callback")
        #expect(query["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(query["resource"] == "https://api.openai.com/v1")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["ext_agent_host_id"] == "urn:uuid:abc")
        #expect(query["id_token_hint"] == nil)
    }

    @Test func reauthorizationReusesIssuedClientIDWithoutAgentNameHint() {
        let url = ChatGPTSignInProtocol.authorizationURL(
            for: makeAttempt(clientID: "oaiapp_123"), hostID: "urn:uuid:abc", codeChallenge: "chal",
            idTokenHint: "idtok", loginHint: "raza@example.com"
        )
        let query = queryItems(of: url)
        #expect(query["client_id"] == "oaiapp_123")
        #expect(query["agent_name_hint"] == nil)
        #expect(query["id_token_hint"] == "idtok")
        #expect(url.absoluteString.contains("login_hint=raza@example.com") || url.absoluteString.contains("raza%40example.com"))
    }

    @Test func callbackRequiresMatchingStateAndAnIssuedClientID() throws {
        let attempt = makeAttempt()
        #expect(throws: ChatGPTSignInError.stateMismatch) {
            try ChatGPTSignInProtocol.parseCallback(queryItems: [URLQueryItem(name: "state", value: "evil"), URLQueryItem(name: "code", value: "c")], attempt: attempt)
        }
        #expect(throws: ChatGPTSignInError.registrationIncomplete) {
            try ChatGPTSignInProtocol.parseCallback(queryItems: [URLQueryItem(name: "state", value: "state123"), URLQueryItem(name: "code", value: "c")], attempt: attempt)
        }
        #expect(throws: ChatGPTSignInError.accessDenied) {
            try ChatGPTSignInProtocol.parseCallback(queryItems: [URLQueryItem(name: "state", value: "state123"), URLQueryItem(name: "error", value: "access_denied")], attempt: attempt)
        }
        let result = try ChatGPTSignInProtocol.parseCallback(queryItems: [
            URLQueryItem(name: "state", value: "state123"), URLQueryItem(name: "code", value: "c"), URLQueryItem(name: "client_id", value: "oaiapp_9"),
        ], attempt: attempt)
        #expect(result == .init(authorizationCode: "c", issuedClientID: "oaiapp_9"))
    }

    @Test func reauthorizationRejectsADifferentClientID() {
        #expect(throws: ChatGPTSignInError.clientIDMismatch) {
            try ChatGPTSignInProtocol.parseCallback(queryItems: [
                URLQueryItem(name: "state", value: "state123"), URLQueryItem(name: "code", value: "c"), URLQueryItem(name: "client_id", value: "oaiapp_other"),
            ], attempt: makeAttempt(clientID: "oaiapp_123"))
        }
    }

    @Test func loopbackRequestLineParsingOnlyAcceptsTheCallbackPath() {
        let items = ChatGPTSignInProtocol.callbackQueryItems(fromHTTPRequestLine: "GET /auth/callback?code=abc&state=s HTTP/1.1")
        #expect(items?.first(where: { $0.name == "code" })?.value == "abc")
        #expect(ChatGPTSignInProtocol.callbackQueryItems(fromHTTPRequestLine: "GET /favicon.ico HTTP/1.1") == nil)
        #expect(ChatGPTSignInProtocol.callbackQueryItems(fromHTTPRequestLine: "POST /auth/callback HTTP/1.1") == nil)
    }

    @Test func tokenRequestsCarryResourceAndNoClientSecretOrScopeOnRefresh() {
        let exchange = String(decoding: ChatGPTSignInProtocol.authorizationCodeExchangeBody(
            callback: .init(authorizationCode: "c/1", issuedClientID: "oaiapp_9"), attempt: makeAttempt()
        ), as: UTF8.self)
        #expect(exchange.contains("grant_type=authorization_code"))
        #expect(exchange.contains("client_id=oaiapp_9"))
        #expect(exchange.contains("code=c%2F1"))
        #expect(exchange.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"))
        #expect(!exchange.contains("client_secret"))

        let record = ChatGPTCredentialRecord(email: nil, subject: "s", issuedClientID: "oaiapp_9", hostID: "h", idToken: "i",
                                             accessToken: "a", refreshToken: "r", scopes: [], accessTokenExpiresAt: Date())
        let refresh = String(decoding: ChatGPTSignInProtocol.refreshBody(for: record)!, as: UTF8.self)
        #expect(refresh.contains("grant_type=refresh_token"))
        #expect(!refresh.contains("scope="))
    }

    @Test func planUsageAndRefreshTiming() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let record = ChatGPTCredentialRecord(email: nil, subject: "s", issuedClientID: "c", hostID: "h", idToken: "i",
                                             accessToken: "a", refreshToken: "r",
                                             scopes: ["chatgpt.tokens.use.direct", "openid"],
                                             accessTokenExpiresAt: now.addingTimeInterval(600))
        #expect(record.hasPlanUsagePermission)
        #expect(!record.needsRefresh(now: now))
        #expect(record.needsRefresh(now: now.addingTimeInterval(400)))
        #expect(ChatGPTSignInProtocol.isUnusableRefreshError(responseBody: Data(#"{"error":"invalid_grant"}"#.utf8)))
        #expect(!ChatGPTSignInProtocol.isUnusableRefreshError(responseBody: Data(#"{"error":"server_error"}"#.utf8)))
    }

    @Test func idTokenClaimsAreCheckedForIssuerAudienceExpiryAndNonce() throws {
        func token(_ payload: String) -> String {
            let header = ChatGPTSignInProtocol.base64URLEncodedString(Data(#"{"alg":"RS256","kid":"k1"}"#.utf8))
            return "\(header).\(ChatGPTSignInProtocol.base64URLEncodedString(Data(payload.utf8))).c2ln"
        }
        let now = Date(timeIntervalSince1970: 1000)
        let good = try ChatGPTSignInProtocol.decodeJSONWebToken(token(#"{"iss":"https://auth.openai.com","sub":"u","aud":"oaiapp_9","exp":2000,"nonce":"n","email":"r@x.com"}"#))
        #expect(good.keyID == "k1")
        let claims = try ChatGPTSignInProtocol.validatedClaims(of: good, issuedClientID: "oaiapp_9", expectedNonce: "n", now: now)
        #expect(claims.email == "r@x.com")
        #expect(throws: ChatGPTSignInError.self) {
            try ChatGPTSignInProtocol.validatedClaims(of: good, issuedClientID: "other", expectedNonce: "n", now: now)
        }
        #expect(throws: ChatGPTSignInError.self) {
            try ChatGPTSignInProtocol.validatedClaims(of: good, issuedClientID: "oaiapp_9", expectedNonce: "wrong", now: now)
        }
        #expect(throws: ChatGPTSignInError.self) {
            try ChatGPTSignInProtocol.validatedClaims(of: good, issuedClientID: "oaiapp_9", expectedNonce: "n", now: Date(timeIntervalSince1970: 3000))
        }
        let wrongIssuer = try ChatGPTSignInProtocol.decodeJSONWebToken(token(#"{"iss":"https://evil","sub":"u","aud":["oaiapp_9"],"exp":2000}"#))
        #expect(throws: ChatGPTSignInError.self) {
            try ChatGPTSignInProtocol.validatedClaims(of: wrongIssuer, issuedClientID: "oaiapp_9", expectedNonce: nil, now: now)
        }
    }

    @Test func rsaPublicKeyDEREncodingPadsHighBitModulus() {
        let der = ChatGPTSignInProtocol.pkcs1RSAPublicKeyDER(modulus: Data([0xC1, 0x02]), exponent: Data([0x01, 0x00, 0x01]))
        #expect(Array(der) == [0x30, 0x0A, 0x02, 0x03, 0x00, 0xC1, 0x02, 0x02, 0x03, 0x01, 0x00, 0x01])
        let longModulus = Data([0x80] + Array(repeating: UInt8(1), count: 255))
        let longDER = ChatGPTSignInProtocol.pkcs1RSAPublicKeyDER(modulus: longModulus, exponent: Data([3]))
        #expect(Array(longDER.prefix(8)) == [0x30, 0x82, 0x01, 0x08, 0x02, 0x82, 0x01, 0x01])
    }
}
