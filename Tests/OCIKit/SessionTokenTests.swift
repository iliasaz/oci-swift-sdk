//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2026 Ilia Sazonov and the oci-swift-sdk project authors
// Licensed under MIT License
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of oci-swift-sdk project authors
//
// SPDX-License-Identifier: MIT License
//
//===----------------------------------------------------------------------===//
//
// Credential-free unit tests for the session-token (UPST) lifecycle: the claim
// reader (`SecurityTokenContainer`), the Auth Service calls behind
// `oci session refresh` / `validate` / `authenticate --no-browser`
// (`SessionTokenClient`), the on-disk layout (`SessionTokenStore`) and the
// profile-level composition (`SessionTokenManager`).
//
// Everything here runs offline: the HTTP transport is injected, and every file
// touched lives in a per-test temporary directory. No ~/.oci/config, no network,
// no environment variables.
//

import Crypto
import Foundation
import Logging
import Synchronization
import Testing
import _CryptoExtras

@testable import OCIKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Helpers

/// Base64url-encodes without padding (JWT segment encoding).
private func sessionBase64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacing("+", with: "-")
    .replacing("/", with: "_")
    .replacing("=", with: "")
}

/// Builds an unsigned-but-well-formed JWT whose payload carries `claims`. Nothing
/// under test verifies the signature, so the segment is a placeholder.
private func sessionJWT(claims: [String: Any]) -> String {
  let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
  let payload = try! JSONSerialization.data(withJSONObject: claims)
  return "\(sessionBase64URL(header)).\(sessionBase64URL(payload)).c2ln"
}

/// A session token with an explicit validity window relative to `now`.
private func sessionToken(
  validFor seconds: Int = 3600,
  issuedAgo: Int = 0,
  subject: String = "ocid1.user.oc1..aaaaexampleuser",
  tenant: String = "ocid1.tenancy.oc1..aaaaexampletenancy",
  marker: String = ""
) -> String {
  let now = Int(Date().timeIntervalSince1970)
  return sessionJWT(claims: [
    "iat": now - issuedAgo,
    "exp": now + seconds,
    "sub": subject,
    "tenant": tenant,
    "marker": marker,
  ])
}

/// A transport that records every request it is handed and replies with a canned
/// status + body.
private final class RecordingTransport: Sendable {
  private let requests = Mutex<[URLRequest]>([])
  private let status: Int
  private let body: Data

  init(status: Int = 200, json: [String: Any]) {
    self.status = status
    self.body = try! JSONSerialization.data(withJSONObject: json)
  }

  init(status: Int, rawBody: String) {
    self.status = status
    self.body = Data(rawBody.utf8)
  }

  var recorded: [URLRequest] { requests.withLock { $0 } }
  var first: URLRequest? { recorded.first }

  var client: HTTPClient {
    HTTPClient { [self] request in
      requests.withLock { $0.append(request) }
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )!
      return (body, response)
    }
  }
}

/// A throwaway directory, removed when the test finishes.
private func makeTempDirectory() throws -> String {
  let path = NSTemporaryDirectory() + "oci-session-tests-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

private func posixPermissions(ofPath path: String) throws -> Int {
  let attributes = try FileManager.default.attributesOfItem(atPath: path)
  return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

// MARK: - SecurityTokenContainer

struct SecurityTokenContainerTests {
  @Test("Reads the exp, iat, sub and tenant claims out of a session token")
  func readsClaims() throws {
    let now = Int(Date().timeIntervalSince1970)
    let token = sessionJWT(claims: [
      "iat": now,
      "exp": now + 3600,
      "sub": "ocid1.user.oc1..aaaauser",
      "tenant": "ocid1.tenancy.oc1..aaaatenancy",
    ])
    let container = try SecurityTokenContainer(token: token)
    #expect(container.expiry == now + 3600)
    #expect(container.issuedAt == now)
    #expect(container.subject == "ocid1.user.oc1..aaaauser")
    #expect(container.tenancyId == "ocid1.tenancy.oc1..aaaatenancy")
    #expect(container.expiresAt == Date(timeIntervalSince1970: TimeInterval(now + 3600)))
  }

  @Test("A token with no exp claim is rejected rather than treated as valid")
  func rejectsTokenWithoutExpiry() {
    let token = sessionJWT(claims: ["sub": "ocid1.user.oc1..aaaauser"])
    #expect(throws: SessionTokenError.self) { try SecurityTokenContainer(token: token) }
  }

  @Test("A non-JWT string and an empty string are both rejected")
  func rejectsMalformedTokens() {
    #expect(throws: SessionTokenError.self) { try SecurityTokenContainer(token: "not-a-jwt") }
    #expect(throws: SessionTokenError.self) { try SecurityTokenContainer(token: "   ") }
  }

  @Test("isValid is true up to exp and false past it")
  func validityAtExpiry() throws {
    let container = try SecurityTokenContainer(token: sessionJWT(claims: ["iat": 1000, "exp": 2000]))
    #expect(container.isValid(now: Date(timeIntervalSince1970: 1999)))
    #expect(container.isValid(now: Date(timeIntervalSince1970: 2000)))
    #expect(!container.isValid(now: Date(timeIntervalSince1970: 2001)))
  }

  @Test("isValid(jitterSeconds:) treats the last seconds before exp as already expired")
  func validityWithJitter() throws {
    let container = try SecurityTokenContainer(token: sessionJWT(claims: ["iat": 1000, "exp": 2000]))
    #expect(container.isValid(jitterSeconds: 60, now: Date(timeIntervalSince1970: 1940)))
    #expect(!container.isValid(jitterSeconds: 60, now: Date(timeIntervalSince1970: 1941)))
  }

  @Test("isValidWithinHalfExpiration flips at the midpoint of the validity window")
  func validityAtHalfExpiration() throws {
    // Window 1000...2000 — midpoint 1500.
    let container = try SecurityTokenContainer(token: sessionJWT(claims: ["iat": 1000, "exp": 2000]))
    #expect(container.isValidWithinHalfExpiration(now: Date(timeIntervalSince1970: 1499)))
    #expect(!container.isValidWithinHalfExpiration(now: Date(timeIntervalSince1970: 1500)))
  }

  @Test("A token with no iat claim falls back to the 60s expiry jitter")
  func halfExpirationWithoutIssuedAt() throws {
    let container = try SecurityTokenContainer(token: sessionJWT(claims: ["exp": 2000]))
    #expect(container.issuedAt == nil)
    #expect(container.isValidWithinHalfExpiration(now: Date(timeIntervalSince1970: 1939)))
    #expect(!container.isValidWithinHalfExpiration(now: Date(timeIntervalSince1970: 1940)))
  }
}

// MARK: - SessionTokenClient endpoints

struct SessionTokenClientEndpointTests {
  @Test("Composes the Auth Service and Identity endpoints from a long-form region")
  func composesEndpoints() throws {
    let client = try SessionTokenClient(region: "us-phoenix-1")
    #expect(client.authEndpoint.absoluteString == "https://auth.us-phoenix-1.oraclecloud.com/v1")
    #expect(client.identityEndpoint.absoluteString == "https://identity.us-phoenix-1.oci.oraclecloud.com")
  }

  @Test("Maps a short region code to its long form and honours a non-commercial realm")
  func mapsShortRegionAndRealm() throws {
    let client = try SessionTokenClient(region: "PHX", realmDomainComponent: "oraclegovcloud.com")
    #expect(client.authEndpoint.absoluteString == "https://auth.us-phoenix-1.oraclegovcloud.com/v1")
  }

  @Test("An unknown but well-formed region is passed through rather than rejected")
  func passesThroughUnknownRegion() throws {
    let client = try SessionTokenClient(region: "us-newregion-1")
    #expect(client.authEndpoint.absoluteString == "https://auth.us-newregion-1.oraclecloud.com/v1")
  }

  @Test("A region or realm carrying URL-significant characters is refused")
  func refusesHostInjection() {
    #expect(throws: SessionTokenError.self) {
      try SessionTokenClient(region: "us-phoenix-1.oraclecloud.com@evil.example")
    }
    #expect(throws: SessionTokenError.self) {
      try SessionTokenClient(region: "us-phoenix-1", realmDomainComponent: "oraclecloud.com/evil")
    }
  }
}

// MARK: - SessionTokenClient wire calls

struct SessionTokenClientRequestTests {
  private func makeKey() throws -> _RSA.Signing.PrivateKey {
    try _RSA.Signing.PrivateKey(keySize: .bits2048)
  }

  @Test("refreshSecurityToken POSTs the current token to /v1/authentication/refresh, signed with it")
  func buildsRefreshRequest() async throws {
    let current = sessionToken()
    let refreshed = sessionToken(marker: "refreshed")
    let transport = RecordingTransport(json: ["token": refreshed])
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: transport.client)

    let result = try await client.refreshSecurityToken(currentToken: current, privateKey: makeKey())
    #expect(result == refreshed)

    let request = try #require(transport.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://auth.us-phoenix-1.oraclecloud.com/v1/authentication/refresh")
    let requestBody = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: String])
    #expect(body == ["currentToken": current])
    // Signed with the session token itself: keyId is ST$<token>.
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.contains(#"keyId="ST$\#(current)""#))
    #expect(authorization.contains("x-content-sha256"))
  }

  @Test("A 401 from refresh reports the session as unrefreshable, not as a generic failure")
  func mapsRefreshRejection() async throws {
    let transport = RecordingTransport(status: 401, rawBody: "{\"code\":\"NotAuthenticated\"}")
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: transport.client)
    await #expect(throws: SessionTokenError.refreshRejected) {
      try await client.refreshSecurityToken(currentToken: sessionToken(), privateKey: makeKey())
    }
  }

  @Test("A non-401 failure from refresh carries the status and body through")
  func mapsRefreshFailure() async throws {
    let transport = RecordingTransport(status: 503, rawBody: "unavailable")
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: transport.client)
    await #expect(throws: SessionTokenError.refreshFailed(status: 503, message: "unavailable")) {
      try await client.refreshSecurityToken(currentToken: sessionToken(), privateKey: makeKey())
    }
  }

  @Test("A 200 with no token field is reported as a malformed response")
  func mapsMalformedRefreshResponse() async throws {
    let transport = RecordingTransport(json: ["notAToken": "x"])
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: transport.client)
    await #expect(throws: SessionTokenError.self) {
      try await client.refreshSecurityToken(currentToken: sessionToken(), privateKey: makeKey())
    }
  }

  @Test("generateUserSecurityToken POSTs the public key PEM and duration to GenerateUpst")
  func buildsGenerateRequest() async throws {
    let issued = sessionToken(marker: "issued")
    let transport = RecordingTransport(json: ["token": issued])
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: transport.client)
    let keyPair = try SessionKeyPair.generate()
    let apiKeySigner = SecurityTokenSigner(securityToken: sessionToken(), privateKey: try makeKey())

    let result = try await client.generateUserSecurityToken(
      publicKeyPEM: keyPair.publicKeyPEM,
      sessionExpirationInMinutes: 30,
      signer: apiKeySigner
    )
    #expect(result == issued)

    let request = try #require(transport.first)
    #expect(request.httpMethod == "POST")
    #expect(
      request.url?.absoluteString == "https://auth.us-phoenix-1.oraclecloud.com/v1/token/upst/actions/GenerateUpst"
    )
    let requestBody = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    // The PEM goes over the wire complete, headers and all — unlike the X.509
    // federation flow, which strips them.
    #expect(body["publicKey"] as? String == keyPair.publicKeyPEM)
    #expect((body["publicKey"] as? String)?.hasPrefix("-----BEGIN PUBLIC KEY-----") == true)
    #expect(body["sessionExpirationInMinutes"] as? Int == 30)
  }

  @Test("A session duration outside 5-60 minutes is refused before any request is made")
  func refusesOutOfRangeDuration() async throws {
    let transport = RecordingTransport(json: ["token": sessionToken()])
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: transport.client)
    let signer = SecurityTokenSigner(securityToken: sessionToken(), privateKey: try makeKey())

    for minutes in [4, 61, 0, -1] {
      await #expect(throws: SessionTokenError.invalidSessionDuration(minutes: minutes)) {
        try await client.generateUserSecurityToken(
          publicKeyPEM: "pem",
          sessionExpirationInMinutes: minutes,
          signer: signer
        )
      }
    }
    #expect(transport.recorded.isEmpty)
  }

  @Test("validateWithService GETs ListRegions with the session token and maps 401 to a rejection")
  func validatesAgainstService() async throws {
    let token = sessionToken()
    let key = try makeKey()
    let ok = RecordingTransport(json: ["items": []])
    let okClient = try SessionTokenClient(region: "us-phoenix-1", transport: ok.client)
    try await okClient.validateWithService(token: token, privateKey: key)

    let request = try #require(ok.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://identity.us-phoenix-1.oci.oraclecloud.com/20160918/regions")
    #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("ST$") == true)

    let denied = RecordingTransport(status: 401, rawBody: "")
    let deniedClient = try SessionTokenClient(region: "us-phoenix-1", transport: denied.client)
    await #expect(throws: SessionTokenError.rejectedByService) {
      try await deniedClient.validateWithService(token: token, privateKey: key)
    }
  }
}

// MARK: - SessionKeyPair

struct SessionKeyPairTests {
  @Test("A generated keypair round-trips through PEM and yields a colon-separated MD5 fingerprint")
  func generatesUsableKeyPair() throws {
    let keyPair = try SessionKeyPair.generate()
    #expect(keyPair.privateKeyPEM.contains("PRIVATE KEY"))
    #expect(keyPair.publicKeyPEM.hasPrefix("-----BEGIN PUBLIC KEY-----"))
    // Re-reading the PEM produces the same key, so a session key written to disk
    // and loaded back signs identically.
    let reloaded = SessionKeyPair(privateKey: try _RSA.Signing.PrivateKey(pemRepresentation: keyPair.privateKeyPEM))
    #expect(reloaded.publicKeyPEM == keyPair.publicKeyPEM)
    #expect(reloaded.fingerprint == keyPair.fingerprint)

    let fingerprint = keyPair.fingerprint
    #expect(fingerprint.count == 47)  // 16 bytes → 32 hex chars + 15 colons
    #expect(fingerprint.split(separator: ":").count == 16)
    #expect(fingerprint.allSatisfy { $0 == ":" || $0.isHexDigit })
    #expect(fingerprint.lowercased() == fingerprint)
  }

  @Test("The fingerprint is the MD5 of the DER the PEM encodes")
  func fingerprintMatchesDigestOfDER() throws {
    let keyPair = try SessionKeyPair.generate()
    let body =
      keyPair.publicKeyPEM
      .replacing("-----BEGIN PUBLIC KEY-----", with: "")
      .replacing("-----END PUBLIC KEY-----", with: "")
      .replacing("\n", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let der = try #require(Data(base64Encoded: body))
    #expect(keyPair.fingerprint.replacing(":", with: "") == der.md5hex)
  }

  @Test("A public key PEM whose body is not base64 is rejected")
  func rejectsCorruptPEM() {
    #expect(throws: SessionTokenError.self) {
      try SessionKeyPair.fingerprint(forPublicKeyPEM: "-----BEGIN PUBLIC KEY-----\n!!!!\n-----END PUBLIC KEY-----")
    }
  }
}

// MARK: - SessionTokenStore

struct SessionTokenStoreTests {
  @Test("upsertProfile replaces only the named section and leaves the others intact")
  func replacesOnlyTargetProfile() {
    let existing = """
      [DEFAULT]
      user=ocid1.user.oc1..default
      region=us-ashburn-1

      # a session profile
      [session]
      region=us-phoenix-1
      security_token_file=/old/token

      [other]
      region=eu-frankfurt-1
      """
    let updated = SessionTokenStore.upsertProfile(
      in: existing,
      profile: "session",
      entries: [(key: "region", value: "us-phoenix-1"), (key: "security_token_file", value: "/new/token")]
    )
    #expect(updated.contains("[DEFAULT]"))
    #expect(updated.contains("user=ocid1.user.oc1..default"))
    #expect(updated.contains("[other]"))
    #expect(updated.contains("region=eu-frankfurt-1"))
    #expect(updated.contains("security_token_file=/new/token"))
    #expect(!updated.contains("/old/token"))
    // Exactly one [session] section survives.
    #expect(updated.components(separatedBy: "[session]").count == 2)
    // The comment belonging to the replaced section goes with it; comments in
    // other sections are untouched.
    #expect(updated.hasSuffix("\n"))
  }

  @Test("upsertProfile on an empty config writes just the new profile")
  func writesProfileIntoEmptyConfig() {
    let updated = SessionTokenStore.upsertProfile(
      in: "",
      profile: "session",
      entries: [(key: "region", value: "us-phoenix-1")]
    )
    #expect(updated == "[session]\nregion=us-phoenix-1\n")
  }

  @Test("Token and private key are written with user-only permissions, the public key readable")
  func writesWithRestrictivePermissions() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }

    try SessionTokenStore.writeToken("a-token", toPath: "\(directory)/nested/token")
    try SessionTokenStore.writePrivateKey("a-key", toPath: "\(directory)/nested/key.pem")
    try SessionTokenStore.writePublicKey("a-public-key", toPath: "\(directory)/nested/key_public.pem")

    #expect(try posixPermissions(ofPath: "\(directory)/nested/token") == 0o600)
    #expect(try posixPermissions(ofPath: "\(directory)/nested/key.pem") == 0o600)
    #expect(try posixPermissions(ofPath: "\(directory)/nested/key_public.pem") == 0o644)
    #expect(try SessionTokenStore.readToken(atPath: "\(directory)/nested/token") == "a-token")
  }

  @Test("readToken rejects a missing or empty token file")
  func rejectsUnusableTokenFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    try SessionTokenStore.writeToken("   \n", toPath: "\(directory)/empty")

    #expect(throws: ConfigErrors.self) { try SessionTokenStore.readToken(atPath: "\(directory)/missing") }
    #expect(throws: ConfigErrors.self) { try SessionTokenStore.readToken(atPath: "\(directory)/empty") }
  }

  @Test("persistSession writes the CLI's session layout and a profile pointing at it")
  func persistsSessionInCLILayout() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"
    let keyPair = try SessionKeyPair.generate()
    let token = sessionToken()

    let paths = try SessionTokenStore.persistSession(
      keyPair: keyPair,
      token: token,
      profile: "my-session",
      region: "us-phoenix-1",
      tenancyOCID: "ocid1.tenancy.oc1..aaaatenancy",
      userOCID: "ocid1.user.oc1..aaaauser",
      configFilePath: configPath,
      sessionsDirectory: "\(directory)/sessions"
    )

    #expect(paths.privateKeyPath == "\(directory)/sessions/my-session/oci_api_key.pem")
    #expect(paths.publicKeyPath == "\(directory)/sessions/my-session/oci_api_key_public.pem")
    #expect(paths.tokenPath == "\(directory)/sessions/my-session/token")
    #expect(try SessionTokenStore.readToken(atPath: paths.tokenPath) == token)
    #expect(try posixPermissions(ofPath: paths.privateKeyPath) == 0o600)
    #expect(try posixPermissions(ofPath: configPath) == 0o600)

    let section = try SessionTokenStore.profileSection(configFilePath: configPath, profile: "my-session")
    #expect(section["region"] == "us-phoenix-1")
    #expect(section["key_file"] == paths.privateKeyPath)
    #expect(section["security_token_file"] == paths.tokenPath)
    #expect(section["fingerprint"] == keyPair.fingerprint)
    #expect(section["tenancy"] == "ocid1.tenancy.oc1..aaaatenancy")
    #expect(section["user"] == "ocid1.user.oc1..aaaauser")
  }
}

// MARK: - SessionTokenManager

/// Writes a complete session profile into `directory` and returns its config path.
private func makeSessionProfile(
  in directory: String,
  profile: String = "session",
  token: String,
  region: String = "us-phoenix-1"
) throws -> (configPath: String, tokenPath: String, keyPair: SessionKeyPair) {
  let keyPair = try SessionKeyPair.generate()
  let configPath = "\(directory)/config"
  let keyPath = "\(directory)/key.pem"
  let tokenPath = "\(directory)/token"
  try SessionTokenStore.writePrivateKey(keyPair.privateKeyPEM, toPath: keyPath)
  try SessionTokenStore.writeToken(token, toPath: tokenPath)
  try SessionTokenStore.upsertProfile(
    configFilePath: configPath,
    profile: profile,
    entries: [
      (key: "region", value: region),
      (key: "key_file", value: keyPath),
      (key: "security_token_file", value: tokenPath),
      (key: "fingerprint", value: keyPair.fingerprint),
    ]
  )
  return (configPath, tokenPath, keyPair)
}

struct SessionTokenManagerTests {
  @Test("validate(local:) accepts an unexpired session without touching the network")
  func validatesLocally() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let token = sessionToken(validFor: 1800)
    let profile = try makeSessionProfile(in: directory, token: token)
    let transport = RecordingTransport(json: [:])

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    let container = try await manager.validate(local: true)
    #expect(container.token == token)
    #expect(container.expiresAt > Date())
    #expect(transport.recorded.isEmpty)
  }

  @Test("validate reports an expired session as expired rather than calling the service")
  func rejectsExpiredSession() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let profile = try makeSessionProfile(in: directory, token: sessionToken(validFor: -60))
    let transport = RecordingTransport(json: [:])

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    await #expect(throws: SessionTokenError.self) { try await manager.validate(local: false) }
    #expect(transport.recorded.isEmpty)
  }

  @Test("validate(local: false) additionally calls the service with the session token")
  func validatesRemotely() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let profile = try makeSessionProfile(in: directory, token: sessionToken())
    let transport = RecordingTransport(json: ["items": []])

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    try await manager.validate(local: false)
    let request = try #require(transport.first)
    #expect(request.url?.absoluteString == "https://identity.us-phoenix-1.oci.oraclecloud.com/20160918/regions")
  }

  @Test("refresh writes the new token back to the profile's security_token_file")
  func refreshWritesTokenBack() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let original = sessionToken(validFor: 600, marker: "original")
    let refreshed = sessionToken(validFor: 3600, marker: "refreshed")
    let profile = try makeSessionProfile(in: directory, token: original)
    let transport = RecordingTransport(json: ["token": refreshed])

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    let container = try await manager.refresh()
    #expect(container.token == refreshed)
    #expect(try SessionTokenStore.readToken(atPath: profile.tokenPath) == refreshed)
    #expect(try posixPermissions(ofPath: profile.tokenPath) == 0o600)
    // The refreshed token is what a subsequent read of the profile sees.
    #expect(try manager.container().token == refreshed)
  }

  @Test("refresh of an already-expired session fails locally, with no doomed request")
  func refuseToRefreshExpiredSession() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let expired = sessionToken(validFor: -1)
    let profile = try makeSessionProfile(in: directory, token: expired)
    let transport = RecordingTransport(json: ["token": sessionToken()])

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    await #expect(throws: SessionTokenError.self) { try await manager.refresh() }
    #expect(transport.recorded.isEmpty)
    // The on-disk token is left exactly as it was.
    #expect(try SessionTokenStore.readToken(atPath: profile.tokenPath) == expired)
  }

  @Test("A refresh the service rejects leaves the existing token file untouched")
  func rejectedRefreshLeavesTokenFile() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let original = sessionToken()
    let profile = try makeSessionProfile(in: directory, token: original)
    let transport = RecordingTransport(status: 401, rawBody: "")

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    await #expect(throws: SessionTokenError.refreshRejected) { try await manager.refresh() }
    #expect(try SessionTokenStore.readToken(atPath: profile.tokenPath) == original)
  }

  @Test("A profile with no security_token_file reports the same error as SecurityTokenSigner")
  func reportsMissingTokenFileEntry() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"
    try SessionTokenStore.upsertProfile(
      configFilePath: configPath,
      profile: "session",
      entries: [(key: "region", value: "us-phoenix-1"), (key: "key_file", value: "\(directory)/key.pem")]
    )
    let manager = SessionTokenManager(configFilePath: configPath, profile: "session")
    #expect(throws: ConfigErrors.self) { try manager.container() }
  }

  @Test("authenticate mints a session, persists it in the CLI layout, and yields a usable signer")
  func authenticatesWithoutBrowser() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let issued = sessionToken(
      validFor: 3600,
      subject: "ocid1.user.oc1..aaaaissueduser",
      tenant: "ocid1.tenancy.oc1..aaaaissuedtenancy"
    )
    let transport = RecordingTransport(json: ["token": issued])
    let existingSigner = SecurityTokenSigner(
      securityToken: sessionToken(),
      privateKey: try _RSA.Signing.PrivateKey(keySize: .bits2048)
    )

    let session = try await SessionTokenManager.authenticate(
      using: existingSigner,
      region: "us-phoenix-1",
      profile: "new-session",
      configFilePath: "\(directory)/config",
      sessionsDirectory: "\(directory)/sessions",
      sessionExpirationInMinutes: 45,
      transport: transport.client
    )

    #expect(session.container.token == issued)
    #expect(session.container.subject == "ocid1.user.oc1..aaaaissueduser")

    // The persisted profile is complete enough for the ordinary signer path.
    let manager = SessionTokenManager(configFilePath: "\(directory)/config", profile: "new-session")
    #expect(try manager.container().token == issued)
    let signer = try manager.signer()
    var request = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
    try await signer.sign(&request)
    #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("ST$\(issued)") == true)

    // And the token/user claims were written into the profile.
    let section = try SessionTokenStore.profileSection(configFilePath: "\(directory)/config", profile: "new-session")
    #expect(section["user"] == "ocid1.user.oc1..aaaaissueduser")
    #expect(section["tenancy"] == "ocid1.tenancy.oc1..aaaaissuedtenancy")
    #expect(section["region"] == "us-phoenix-1")
  }
}
