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

/// The error `body` throws, or `nil` when it returns normally. Used where a test
/// compares the errors *two* APIs report for the same input, which
/// `#expect(throws:)` cannot express on its own.
private func capturedError(_ body: () throws -> Void) -> Error? {
  do {
    try body()
    return nil
  }
  catch {
    return error
  }
}

/// The error an `async` `body` throws, or `nil` when it returns normally.
private func capturedAsyncError(_ body: () async throws -> Void) async -> Error? {
  do {
    try await body()
    return nil
  }
  catch {
    return error
  }
}

/// A short, comparable name for a thrown error, so two APIs' errors for the same
/// input can be compared even though ``ConfigErrors`` is not `Equatable`.
private func errorName(_ error: Error?) -> String {
  guard let error else { return "<no error thrown>" }
  return String(describing: error)
}

/// A config file that exists and holds readable profiles but cannot be decoded as
/// UTF-8, because of one stray byte at the end.
///
/// This is the portable way to make a read fail: a `chmod 000` file is still
/// readable by root, and the Linux CI container runs the tests as root.
private func writeUndecodableConfig(atPath path: String, readableProfiles: String) throws -> Data {
  var bytes = Data(readableProfiles.utf8)
  bytes.append(0xFF)
  try bytes.write(to: URL(fileURLWithPath: path))
  return bytes
}

/// Profile names that must be refused everywhere a profile name reaches disk —
/// as a path component under the sessions directory and as an INI section name.
private let unusableProfileNames = [
  "../escape",  // parent traversal
  "..",
  ".",
  "nested/profile",  // path separator
  "/absolute",
  "ev]il",  // terminates the INI section header
  "key=value",  // injects a key into the section
  "line\nbreak",  // starts a new INI line
  "carriage\rreturn",
  "",
  "   ",  // whitespace only
  "trailing ",
  "naïve",  // non-ASCII
]

/// Watches a directory for the POSIX mode of every file that appears in it, so a
/// test can assert that private material is never *observable* at a loose mode —
/// not merely that it ends up correct.
///
/// `Mutex` is `~Copyable` and so cannot be captured by the detached polling task
/// directly; wrapping it in a `Sendable` reference type is the approach
/// ``RecordingTransport`` already takes here.
private final class DirectoryModeObserver: Sendable {
  private let directory: String
  private let modes = Mutex<[String: Set<Int>]>([:])
  private let stopped = Mutex(false)

  init(directory: String) {
    self.directory = directory
  }

  /// Every mode each file in the directory was ever seen at.
  var observed: [String: Set<Int>] { modes.withLock { $0 } }

  /// Polls until ``stop()``.
  func watch() async {
    while !stopped.withLock({ $0 }) {
      if let names = try? FileManager.default.contentsOfDirectory(atPath: directory) {
        for name in names {
          guard let mode = try? posixPermissions(ofPath: "\(directory)/\(name)") else { continue }
          modes.withLock { _ = $0[name, default: []].insert(mode) }
        }
      }
      await Task.yield()
    }
  }

  func stop() {
    stopped.withLock { $0 = true }
  }
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

  @Test("A token with no iat claim falls back to defaultExpiryJitterSeconds of slack")
  func halfExpirationWithoutIssuedAt() throws {
    // There is no window to halve without `iat`, so the fallback slack applies.
    // Derived from the constant rather than written out as 60, so the public name
    // and the policy behind it can never drift apart unnoticed.
    let slack = SecurityTokenContainer.defaultExpiryJitterSeconds
    #expect(slack > 0)
    let expiry = 2000
    let container = try SecurityTokenContainer(token: sessionJWT(claims: ["exp": expiry]))
    #expect(container.issuedAt == nil)
    #expect(
      container.isValidWithinHalfExpiration(
        now: Date(timeIntervalSince1970: TimeInterval(expiry - slack - 1))
      )
    )
    #expect(
      !container.isValidWithinHalfExpiration(
        now: Date(timeIntervalSince1970: TimeInterval(expiry - slack))
      )
    )
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

  @Test("An unrecognised success body is reported by shape, never by content, so a token cannot leak")
  func malformedResponseCarriesShapeNotCredential() async throws {
    // The hazard: a success body on these endpoints *is* a credential. If the
    // service ever wrapped the token in an envelope, the SDK must not paste it
    // into a thrown error and from there into the caller's logs.
    let secret = sessionToken(marker: "must-not-appear-in-any-error")
    let transport = RecordingTransport(json: ["data": ["securityToken": secret], "expiresAt": "soon"])
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: transport.client)

    let error = await capturedAsyncError {
      _ = try await client.refreshSecurityToken(currentToken: sessionToken(), privateKey: try makeKey())
    }
    let described = try #require((error as? SessionTokenError)?.errorDescription)
    #expect(!described.contains(secret))
    // Not merely absent — no fragment of the token survives either.
    #expect(!described.contains(String(secret.prefix(24))))
    // Still diagnosable: the keys that *were* present are named.
    #expect(described.contains("data"))
    #expect(described.contains("expiresAt"))
  }

  @Test("A short error body reaches the caller verbatim, an enormous one is bounded")
  func errorBodiesAreCarriedButBounded() async throws {
    let short = RecordingTransport(status: 503, rawBody: "unavailable")
    let shortClient = try SessionTokenClient(region: "us-phoenix-1", transport: short.client)
    await #expect(throws: SessionTokenError.refreshFailed(status: 503, message: "unavailable")) {
      try await shortClient.refreshSecurityToken(currentToken: sessionToken(), privateKey: try makeKey())
    }

    // A proxy's HTML error page must not paste kilobytes into a log line.
    let huge = String(repeating: "x", count: SessionTokenClient.maximumDiagnosticCharacters * 4)
    let hugeClient = try SessionTokenClient(
      region: "us-phoenix-1",
      transport: RecordingTransport(status: 502, rawBody: huge).client
    )
    let error = await capturedAsyncError {
      _ = try await hugeClient.refreshSecurityToken(currentToken: sessionToken(), privateKey: try makeKey())
    }
    guard case .refreshFailed(let status, let message) = try #require(error as? SessionTokenError) else {
      Issue.record("expected refreshFailed, got \(String(describing: error))")
      return
    }
    #expect(status == 502)
    #expect(message.count < huge.count)
    #expect(message.hasPrefix("xxxx"))
    #expect(message.contains("truncated"))
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
    let reloaded = try SessionKeyPair(
      privateKey: try _RSA.Signing.PrivateKey(pemRepresentation: keyPair.privateKeyPEM)
    )
    #expect(reloaded.publicKeyPEM == keyPair.publicKeyPEM)
    #expect(reloaded.fingerprint == keyPair.fingerprint)

    let fingerprint = keyPair.fingerprint
    #expect(!fingerprint.isEmpty)
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

  @Test("A public key PEM whose body is not base64 is reported as a malformed public key")
  func rejectsCorruptPEM() {
    let error = #expect(throws: SessionTokenError.self) {
      try SessionKeyPair.fingerprint(forPublicKeyPEM: "-----BEGIN PUBLIC KEY-----\n!!!!\n-----END PUBLIC KEY-----")
    }
    guard let error, case .malformedPublicKey = error else {
      Issue.record("Expected .malformedPublicKey, got \(String(describing: error))")
      return
    }
  }

  @Test("A generated keypair always carries a usable fingerprint, with no error to unwrap")
  func fingerprintIsAvailableInfallibly() throws {
    // `fingerprint` is a stored property computed at init, so a keypair that
    // exists cannot hand out an empty fingerprint — which would previously have
    // been written into the config profile as `fingerprint=`.
    for _ in 0..<3 {
      let keyPair = try SessionKeyPair.generate()
      #expect(!keyPair.fingerprint.isEmpty)
      #expect(keyPair.fingerprint == (try SessionKeyPair.fingerprint(forPublicKeyPEM: keyPair.publicKeyPEM)))
    }
  }

  @Test("A CRLF-wrapped public key PEM fingerprints identically to the LF one")
  func fingerprintsCRLFPEMIdentically() throws {
    let keyPair = try SessionKeyPair.generate()
    let crlf = keyPair.publicKeyPEM.replacing("\n", with: "\r\n")
    #expect(crlf.contains("\r\n"))
    #expect(try SessionKeyPair.fingerprint(forPublicKeyPEM: crlf) == keyPair.fingerprint)
    // And a body with no header/footer at all fingerprints the same way.
    let bare =
      crlf
      .replacing("-----BEGIN PUBLIC KEY-----", with: "")
      .replacing("-----END PUBLIC KEY-----", with: "")
    #expect(try SessionKeyPair.fingerprint(forPublicKeyPEM: bare) == keyPair.fingerprint)
  }
}

// MARK: - SessionTokenStore

struct SessionTokenStoreTests {
  @Test("upsertProfile replaces only the named section and leaves the others intact")
  func replacesOnlyTargetProfile() throws {
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
    let updated = try SessionTokenStore.upsertProfile(
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

  @Test("A section header with a trailing comment ends the replaced section instead of being swallowed")
  func treatsHeaderWithTrailingCommentAsHeader() throws {
    // `[work] ; note` is section `work` to every parser that reads these files —
    // INIParser (and so `profileSection`), and the CLI's configparser. A writer that
    // required the line to *end* in `]` would not see a header here, would consider
    // the replaced section to run on through `[work]`, and would delete that whole
    // profile.
    let existing = """
      [session-a]
      region=us-phoenix-1
      security_token_file=/old/token
      [work] ; my other tenancy
      user=ocid1.user.oc1..EXAMPLE
      region=eu-frankfurt-1
      """
    let updated = try SessionTokenStore.upsertProfile(
      in: existing,
      profile: "session-a",
      entries: [(key: "security_token_file", value: "/new/token")]
    )
    #expect(updated.contains("[work] ; my other tenancy"))
    #expect(updated.contains("region=eu-frankfurt-1"))
    #expect(updated.contains("user=ocid1.user.oc1..EXAMPLE"))
    #expect(updated.contains("security_token_file=/new/token"))
    #expect(!updated.contains("/old/token"))

    // And the result still parses into both profiles, i.e. writer and reader agree.
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"
    try updated.write(toFile: configPath, atomically: true, encoding: .utf8)
    #expect(
      try SessionTokenStore.profileSection(configFilePath: configPath, profile: "work")["region"]
        == "eu-frankfurt-1"
    )
    #expect(
      try SessionTokenStore.profileSection(configFilePath: configPath, profile: "session-a")["security_token_file"]
        == "/new/token"
    )
  }

  @Test("A CRLF config file keeps exactly one section per profile after an upsert")
  func replacesSectionInCRLFConfig() throws {
    // A `~/.oci/config` copied in from Windows ends every header in `]\r`, which
    // `CharacterSet.whitespaces` does not cover. Missing the header would append a
    // second `[session-a]` — silently merged by INIParser, and a hard
    // DuplicateSectionError for the CLI's strict configparser.
    let existing = "[session-a]\r\nregion=us-phoenix-1\r\nsecurity_token_file=/old/token\r\n"
    let updated = try SessionTokenStore.upsertProfile(
      in: existing,
      profile: "session-a",
      entries: [(key: "region", value: "us-phoenix-1"), (key: "security_token_file", value: "/new/token")]
    )
    #expect(updated.components(separatedBy: "[session-a]").count == 2, "the profile appears twice: \(updated)")
    #expect(!updated.contains("/old/token"))
    #expect(updated.contains("security_token_file=/new/token"))
  }

  @Test("An entry whose value carries a line break is refused instead of injecting config lines")
  func refusesEntryValuesThatWouldInjectLines() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"
    let existing = "[DEFAULT]\nkey_file=/home/user/.oci/oci_api_key.pem\nregion=us-ashburn-1\n"
    try existing.write(toFile: configPath, atomically: true, encoding: .utf8)

    // A duplicate section is *merged* by the parsers that read these files, later
    // assignments winning — so an injected [DEFAULT] block would silently re-point
    // another profile's key_file.
    let injecting = [
      (key: "region", value: "us-phoenix-1\n[DEFAULT]\nkey_file=/attacker/key.pem"),
      (key: "region", value: "us-phoenix-1\r[DEFAULT]"),
      (key: "user", value: "ocid1.user.oc1..EXAMPLE\nfingerprint=aa:bb"),
    ]
    for entry in injecting {
      #expect(throws: SessionTokenError.self) {
        try SessionTokenStore.upsertProfile(in: existing, profile: "session", entries: [entry])
      }
      #expect(throws: SessionTokenError.self) {
        try SessionTokenStore.upsertProfile(configFilePath: configPath, profile: "session", entries: [entry])
      }
    }
    // Keys are refused for the same reason, plus anything that would end the
    // `key=value` shape.
    for key in ["", " region", "region ", "re=gion", "region]", "[region", "reg#ion", "reg;ion", "reg\nion"] {
      #expect(throws: SessionTokenError.self) {
        try SessionTokenStore.upsertProfile(
          in: existing,
          profile: "session",
          entries: [(key: key, value: "us-phoenix-1")]
        )
      }
    }
    // Nothing was written, so the config a user depends on is untouched.
    #expect(try String(contentsOfFile: configPath, encoding: .utf8) == existing)
  }

  @Test("A private key is never observable at a group- or world-readable mode, not even mid-write")
  func neverExposesPrivateMaterialAtALooseMode() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    // Large enough that the write takes long enough for the observer to catch the
    // file while it is being filled. A create-then-chmod implementation exposes the
    // whole payload at the umask default (typically 0644) for that whole window.
    let payload = String(repeating: "k", count: 24 * 1024 * 1024)
    let observer = DirectoryModeObserver(directory: directory)
    let watcher = Task.detached { await observer.watch() }

    try SessionTokenStore.writePrivateKey(payload, toPath: "\(directory)/oci_api_key.pem")
    try SessionTokenStore.writeToken(payload, toPath: "\(directory)/token")
    observer.stop()
    await watcher.value

    #expect(try posixPermissions(ofPath: "\(directory)/oci_api_key.pem") == 0o600)
    for (name, modes) in observer.observed {
      for mode in modes {
        #expect(mode & 0o077 == 0, "\(name) was observable at mode \(String(mode, radix: 8))")
      }
    }
  }

  @Test("An explicit mode survives a restrictive umask, so a public key is not silently narrowed")
  func appliesExactPermissionsUnderARestrictiveUmask() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    // `open(2)` masks its mode argument with the umask, so the exclusive create has
    // to pin the mode explicitly afterwards — otherwise the public key would land
    // at 0600 here and a 0022 umask would decide the private key's group bits.
    let previous = umask(0o077)
    defer { umask(previous) }

    try SessionTokenStore.writePublicKey("a-public-key", toPath: "\(directory)/key_public.pem")
    try SessionTokenStore.writePrivateKey("a-key", toPath: "\(directory)/key.pem")
    #expect(try posixPermissions(ofPath: "\(directory)/key_public.pem") == 0o644)
    #expect(try posixPermissions(ofPath: "\(directory)/key.pem") == 0o600)
  }

  @Test("upsertProfile on an empty config writes just the new profile")
  func writesProfileIntoEmptyConfig() throws {
    let updated = try SessionTokenStore.upsertProfile(
      in: "",
      profile: "session",
      entries: [(key: "region", value: "us-phoenix-1")]
    )
    #expect(updated == "[session]\nregion=us-phoenix-1\n")
  }

  @Test("upsertProfile creates a config file that does not exist yet")
  func createsAbsentConfigFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/nested/config"

    try SessionTokenStore.upsertProfile(
      configFilePath: configPath,
      profile: "session",
      entries: [(key: "region", value: "us-phoenix-1")]
    )
    #expect(try String(contentsOfFile: configPath, encoding: .utf8) == "[session]\nregion=us-phoenix-1\n")
    #expect(try posixPermissions(ofPath: configPath) == 0o600)
  }

  @Test("upsertProfile refuses to replace a config file it cannot read, keeping the other profiles")
  func refusesToReplaceUnreadableConfig() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"
    let readableProfiles = """
      [DEFAULT]
      user=ocid1.user.oc1..default
      region=us-ashburn-1

      [other]
      region=eu-frankfurt-1

      """
    let original = try writeUndecodableConfig(atPath: configPath, readableProfiles: readableProfiles)

    let error = #expect(throws: SessionTokenError.self) {
      try SessionTokenStore.upsertProfile(
        configFilePath: configPath,
        profile: "session",
        entries: [(key: "region", value: "us-phoenix-1")]
      )
    }
    guard let error, case .persistenceFailed(let path, _) = error else {
      Issue.record("Expected .persistenceFailed, got \(String(describing: error))")
      return
    }
    #expect(path == configPath)

    // Nothing was replaced: the file is byte-for-byte what it was, so the other
    // profiles a user depends on are still there. Treating an unreadable config as
    // empty would have left only the session profile behind.
    let after = try Data(contentsOf: URL(fileURLWithPath: configPath))
    #expect(after == original)
    let text = String(decoding: after.dropLast(), as: UTF8.self)
    #expect(text.contains("[DEFAULT]"))
    #expect(text.contains("[other]"))
    #expect(!text.contains("[session]"))
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
    // Nothing is left behind by the write-then-move, so a session directory holds
    // only session material.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: "\(directory)/nested")
      .filter { $0.hasSuffix(".tmp") }
    #expect(leftovers.isEmpty)
  }

  @Test("Every directory level created for session material is user-only")
  func createsSessionDirectoriesUserOnly() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }

    try SessionTokenStore.writeToken("a-token", toPath: "\(directory)/oci/sessions/session/token")

    // Not just the leaf: a world-readable `~/.oci` above a 0700 session directory
    // would still expose the directory listing.
    #expect(try posixPermissions(ofPath: "\(directory)/oci") == 0o700)
    #expect(try posixPermissions(ofPath: "\(directory)/oci/sessions") == 0o700)
    #expect(try posixPermissions(ofPath: "\(directory)/oci/sessions/session") == 0o700)
  }

  @Test("Overwriting a session file — even a read-only one — succeeds and lands at the intended mode")
  func overwritesExistingFilesAtIntendedMode() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let tokenPath = "\(directory)/token"
    let keyPath = "\(directory)/oci_api_key.pem"
    let publicKeyPath = "\(directory)/oci_api_key_public.pem"

    try SessionTokenStore.writeToken("first", toPath: tokenPath)
    try SessionTokenStore.writePrivateKey("first-key", toPath: keyPath)
    try SessionTokenStore.writePublicKey("first-public-key", toPath: publicKeyPath)

    // A token file an older CLI (or a cautious user) left read-only cannot be
    // opened for writing at all, so an in-place write would fail here.
    for path in [tokenPath, keyPath, publicKeyPath] {
      try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path)
    }

    try SessionTokenStore.writeToken("second", toPath: tokenPath)
    try SessionTokenStore.writePrivateKey("second-key", toPath: keyPath)
    try SessionTokenStore.writePublicKey("second-public-key", toPath: publicKeyPath)

    #expect(try SessionTokenStore.readToken(atPath: tokenPath) == "second")
    #expect(try String(contentsOfFile: keyPath, encoding: .utf8) == "second-key")
    #expect(try String(contentsOfFile: publicKeyPath, encoding: .utf8) == "second-public-key")
    // The replacement carries the intended mode, not the mode it replaced and not
    // a umask default: the private material is never observable as 0644.
    #expect(try posixPermissions(ofPath: tokenPath) == 0o600)
    #expect(try posixPermissions(ofPath: keyPath) == 0o600)
    #expect(try posixPermissions(ofPath: publicKeyPath) == 0o644)

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory)
      .filter { $0.hasSuffix(".tmp") }
    #expect(leftovers.isEmpty)
  }

  @Test("An existing 0600 config file stays 0600 when a profile is upserted into it")
  func keepsConfigFileUserOnlyOnRewrite() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"

    try SessionTokenStore.upsertProfile(
      configFilePath: configPath,
      profile: "first",
      entries: [(key: "region", value: "us-ashburn-1")]
    )
    try SessionTokenStore.upsertProfile(
      configFilePath: configPath,
      profile: "second",
      entries: [(key: "region", value: "us-phoenix-1")]
    )
    #expect(try posixPermissions(ofPath: configPath) == 0o600)
    let text = try String(contentsOfFile: configPath, encoding: .utf8)
    #expect(text.contains("[first]"))
    #expect(text.contains("[second]"))
  }

  @Test("An unusable profile name is refused by every entry point that takes one")
  func refusesUnusableProfileNames() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"
    let sessionsDirectory = "\(directory)/sessions"
    let existing = "[DEFAULT]\nregion=us-ashburn-1\n"
    try existing.write(toFile: configPath, atomically: true, encoding: .utf8)
    let keyPair = try SessionKeyPair.generate()

    for name in unusableProfileNames {
      #expect(!SessionTokenStore.isValidProfileName(name), "\"\(name)\" must not be a valid profile name")
      #expect(throws: SessionTokenError.invalidProfileName(name)) {
        try SessionTokenStore.validateProfileName(name)
      }
      #expect(throws: SessionTokenError.invalidProfileName(name)) {
        try SessionTokenStore.sessionDirectory(forProfile: name, sessionsDirectory: sessionsDirectory)
      }
      #expect(throws: SessionTokenError.invalidProfileName(name)) {
        try SessionTokenStore.upsertProfile(
          in: existing,
          profile: name,
          entries: [(key: "region", value: "us-phoenix-1")]
        )
      }
      #expect(throws: SessionTokenError.invalidProfileName(name)) {
        try SessionTokenStore.upsertProfile(
          configFilePath: configPath,
          profile: name,
          entries: [(key: "region", value: "us-phoenix-1")]
        )
      }
      #expect(throws: SessionTokenError.invalidProfileName(name)) {
        try SessionTokenStore.persistSession(
          keyPair: keyPair,
          token: sessionToken(),
          profile: name,
          region: "us-phoenix-1",
          tenancyOCID: nil,
          userOCID: nil,
          configFilePath: configPath,
          sessionsDirectory: sessionsDirectory
        )
      }
    }

    // A rejected name wrote nothing at all: the config file is untouched and no
    // session directory — inside or outside `sessions` — came into existence.
    #expect(try String(contentsOfFile: configPath, encoding: .utf8) == existing)
    #expect(!FileManager.default.fileExists(atPath: sessionsDirectory))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory).sorted() == ["config"])
  }

  @Test("A profile name of letters, digits, dots, dashes and underscores is accepted")
  func acceptsOrdinaryProfileNames() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    for name in ["DEFAULT", "my-session", "my_session", "session.1", "a", String(repeating: "p", count: 255)] {
      #expect(SessionTokenStore.isValidProfileName(name), "\"\(name)\" must be a valid profile name")
      #expect(
        try SessionTokenStore.sessionDirectory(forProfile: name, sessionsDirectory: "\(directory)/sessions")
          == "\(directory)/sessions/\(name)"
      )
    }
    // 256 characters is one too many for a path component on common filesystems.
    #expect(!SessionTokenStore.isValidProfileName(String(repeating: "p", count: 256)))
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

  @Test("persistSession refuses a config it cannot read before it replaces any session material")
  func failsBeforeTouchingMaterialWhenTheConfigIsUnreadable() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"
    let sessionsDirectory = "\(directory)/sessions"
    let firstKeyPair = try SessionKeyPair.generate()
    let firstToken = sessionToken(marker: "first")

    let paths = try SessionTokenStore.persistSession(
      keyPair: firstKeyPair,
      token: firstToken,
      profile: "my-session",
      region: "us-phoenix-1",
      tenancyOCID: nil,
      userOCID: nil,
      configFilePath: configPath,
      sessionsDirectory: sessionsDirectory
    )

    // The config file becomes unreadable — which this type refuses to overwrite.
    // Re-authenticating writes the *same* paths, so a material-first order would
    // have replaced the working session's key and token and then failed, leaving a
    // profile whose fingerprint no longer matches the key on disk.
    let original = try writeUndecodableConfig(
      atPath: configPath,
      readableProfiles: "[DEFAULT]\nregion=us-ashburn-1\n"
    )
    let secondKeyPair = try SessionKeyPair.generate()
    #expect(throws: SessionTokenError.self) {
      try SessionTokenStore.persistSession(
        keyPair: secondKeyPair,
        token: sessionToken(marker: "second"),
        profile: "my-session",
        region: "us-phoenix-1",
        tenancyOCID: nil,
        userOCID: nil,
        configFilePath: configPath,
        sessionsDirectory: sessionsDirectory
      )
    }

    #expect(try Data(contentsOf: URL(fileURLWithPath: configPath)) == original)
    #expect(try SessionTokenStore.readToken(atPath: paths.tokenPath) == firstToken)
    #expect(try String(contentsOfFile: paths.privateKeyPath, encoding: .utf8) == firstKeyPair.privateKeyPEM)
    #expect(try String(contentsOfFile: paths.publicKeyPath, encoding: .utf8) == firstKeyPair.publicKeyPEM)
  }

  @Test("Concurrent upserts of different profiles into one config file all survive")
  func concurrentUpsertsKeepEveryProfile() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"
    let profiles = (0..<8).map { "session-\($0)" }

    // Each upsert is a read-modify-write of the whole file, so unsynchronised
    // callers read the same "before" text and the last writer drops every profile
    // the others added.
    await withTaskGroup(of: Void.self) { group in
      for profile in profiles {
        group.addTask {
          _ = try? SessionTokenStore.upsertProfile(
            configFilePath: configPath,
            profile: profile,
            entries: [(key: "region", value: "us-phoenix-1"), (key: "security_token_file", value: "/t/\(profile)")]
          )
        }
      }
    }

    for profile in profiles {
      let section = try SessionTokenStore.profileSection(configFilePath: configPath, profile: profile)
      #expect(section["security_token_file"] == "/t/\(profile)", "\(profile) was lost")
    }
  }

  @Test("Concurrent persistSession calls for one profile leave a matching key, token and fingerprint")
  func concurrentPersistSessionKeepsTheTripleConsistent() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"
    let sessionsDirectory = "\(directory)/sessions"

    // Same profile, so all four writes go to the same paths. Interleaving them
    // yields a profile whose token belongs to one session and whose key belongs to
    // another — every later signature from it is rejected, by the SDK and the CLI
    // alike.
    let sessions = try (0..<6).map { index -> (keyPair: SessionKeyPair, token: String) in
      (try SessionKeyPair.generate(), sessionToken(marker: "session-\(index)"))
    }
    for round in 0..<20 {
      await withTaskGroup(of: Void.self) { group in
        for session in sessions {
          group.addTask {
            _ = try? SessionTokenStore.persistSession(
              keyPair: session.keyPair,
              token: session.token,
              profile: "my-session",
              region: "us-phoenix-1",
              tenancyOCID: nil,
              userOCID: nil,
              configFilePath: configPath,
              sessionsDirectory: sessionsDirectory
            )
          }
        }
      }
      // Checked after every round: the interleaving that breaks the profile is a
      // narrow window between four fast writes, so one wave is not enough to
      // provoke it reliably.
      let section = try SessionTokenStore.profileSection(configFilePath: configPath, profile: "my-session")
      let keyFilePath = try #require(section["key_file"])
      let privateKeyPEM = try String(contentsOfFile: keyFilePath, encoding: .utf8)
      let onDisk = try SessionKeyPair(privateKey: try _RSA.Signing.PrivateKey(pemRepresentation: privateKeyPEM))
      let tokenFilePath = try #require(section["security_token_file"])
      let token = try SessionTokenStore.readToken(atPath: tokenFilePath)
      let winner = try #require(sessions.first { $0.keyPair.fingerprint == onDisk.fingerprint })
      let publicKeyPEM = try String(
        contentsOfFile: "\(sessionsDirectory)/my-session/oci_api_key_public.pem",
        encoding: .utf8
      )

      #expect(
        section["fingerprint"] == onDisk.fingerprint,
        "round \(round): the profile's fingerprint is not the key on disk"
      )
      #expect(token == winner.token, "round \(round): the token on disk belongs to another session than the key")
      #expect(publicKeyPEM == winner.keyPair.publicKeyPEM, "round \(round): the keypair halves are from two sessions")
    }
  }

  @Test("Concurrent writes under a missing shared ancestor directory all succeed")
  func concurrentWritesCreateTheDirectoryTreeOnce() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    // `~/.oci/sessions` does not exist yet, and every task needs it: creating a
    // level that another task has just created must not fail the write and discard
    // an already-minted token.
    let sessions = "\(directory)/oci/sessions"
    let outcomes = await withTaskGroup(of: Error?.self) { group -> [Error?] in
      for index in 0..<8 {
        group.addTask {
          capturedError {
            try SessionTokenStore.writeToken("token-\(index)", toPath: "\(sessions)/profile-\(index)/token")
          }
        }
      }
      var collected: [Error?] = []
      for await outcome in group { collected.append(outcome) }
      return collected
    }

    #expect(outcomes.compactMap { $0 }.isEmpty, "\(outcomes.compactMap { errorName($0) })")
    for index in 0..<8 {
      #expect(try SessionTokenStore.readToken(atPath: "\(sessions)/profile-\(index)/token") == "token-\(index)")
    }
    #expect(try posixPermissions(ofPath: sessions) == 0o700)
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

  @Test("validate() defaults to the service check, exactly like `oci session validate`")
  func validateDefaultsToTheServiceCheck() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let token = sessionToken()
    let profile = try makeSessionProfile(in: directory, token: token)
    let transport = RecordingTransport(json: ["items": []])

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    // No `local:` argument at all: the default must be the network check, because
    // only that detects a session terminated before its `exp`.
    let container = try await manager.validate()
    #expect(container.token == token)
    #expect(transport.recorded.count == 1)
    let request = try #require(transport.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://identity.us-phoenix-1.oci.oraclecloud.com/20160918/regions")
    #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("ST$\(token)") == true)
  }

  @Test("validate(local: true) is the offline opt-in and issues no request")
  func validateLocalIssuesNoRequest() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let profile = try makeSessionProfile(in: directory, token: sessionToken())
    let transport = RecordingTransport(json: ["items": []])

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    try await manager.validate(local: true)
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

  @Test("A session in its last seconds fails locally as too-close-to-expiry, not as a doomed round trip")
  func refusesRefreshInsideTheExpiryJitter() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    // Alive, but with less than the default slack left.
    let expiring = sessionToken(validFor: SecurityTokenContainer.defaultExpiryJitterSeconds - 10)
    let profile = try makeSessionProfile(in: directory, token: expiring)
    let transport = RecordingTransport(json: ["token": sessionToken()])

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    let error = await capturedAsyncError { _ = try await manager.refresh() }
    guard case .sessionTooCloseToExpiry(_, let minimumRemaining) = try #require(error as? SessionTokenError) else {
      Issue.record("expected sessionTooCloseToExpiry, got \(String(describing: error))")
      return
    }
    #expect(minimumRemaining == SecurityTokenContainer.defaultExpiryJitterSeconds)
    #expect(transport.recorded.isEmpty)
    #expect(try SessionTokenStore.readToken(atPath: profile.tokenPath) == expiring)
  }

  @Test("minimumRemaining: 0 attempts the refresh anyway, for a caller that would rather ask than give up")
  func honoursOptingOutOfTheExpiryJitter() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let expiring = sessionToken(validFor: SecurityTokenContainer.defaultExpiryJitterSeconds - 10)
    let extended = sessionToken(validFor: 3600, marker: "extended")
    let profile = try makeSessionProfile(in: directory, token: expiring)
    let transport = RecordingTransport(json: ["token": extended])

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    let container = try await manager.refresh(minimumRemaining: 0)
    #expect(container.token == extended)
    #expect(transport.recorded.count == 1)
    #expect(try SessionTokenStore.readToken(atPath: profile.tokenPath) == extended)
  }

  @Test("An already-expired session is still refused even when the jitter gate is opted out of")
  func expiredSessionIsRefusedEvenWithoutJitter() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let profile = try makeSessionProfile(in: directory, token: sessionToken(validFor: -1))
    let transport = RecordingTransport(json: ["token": sessionToken()])

    let manager = SessionTokenManager(
      configFilePath: profile.configPath,
      profile: "session",
      transport: transport.client
    )
    // An expired session reports `sessionExpired`, not the too-close-to-expiry
    // judgement call — the gate is opted out of, but expiry is not negotiable.
    let error = await capturedAsyncError { _ = try await manager.refresh(minimumRemaining: 0) }
    guard case .sessionExpired = try #require(error as? SessionTokenError) else {
      Issue.record("expected sessionExpired, got \(String(describing: error))")
      return
    }
    #expect(transport.recorded.isEmpty)
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
    let keyPair = try SessionKeyPair.generate()
    let usableKeyPath = "\(directory)/key.pem"
    try SessionTokenStore.writePrivateKey(keyPair.privateKeyPEM, toPath: usableKeyPath)

    // Two profiles with no `security_token_file`: one otherwise fine, one whose
    // `key_file` is missing too. Parity has to hold for both — the errors are
    // raised in the signer's own order, so a doubly-broken profile does not report
    // a different case here than it does there.
    let cases = [
      ("usable-key", usableKeyPath),
      ("unreadable-key", "\(directory)/does-not-exist.pem"),
    ]
    for (profile, keyPath) in cases {
      let configPath = "\(directory)/config-\(profile)"
      try SessionTokenStore.upsertProfile(
        configFilePath: configPath,
        profile: profile,
        entries: [(key: "region", value: "us-phoenix-1"), (key: "key_file", value: keyPath)]
      )
      let manager = SessionTokenManager(configFilePath: configPath, profile: profile)
      let managerError = capturedError { _ = try manager.container() }
      let signerError = capturedError {
        _ = try SecurityTokenSigner(configFilePath: configPath, configName: profile)
      }
      #expect(managerError is ConfigErrors)
      #expect(errorName(signerError) == errorName(managerError), "parity broken for \(profile)")
    }
  }

  @Test("refresh(using:) refreshes the profile read it was handed, not a second read of the file")
  func refreshUsesTheProfileReadItWasGiven() async throws {
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

    let state = try manager.profileState()
    // Something rewrites the profile between the caller's read and the refresh —
    // `oci session authenticate` rotating the keypair, say. A second read inside
    // refresh() would use *that* material, and the caller pairing the issued token
    // with the key it read would hold a mismatched pair.
    try SessionTokenStore.writeToken(sessionToken(marker: "rotated"), toPath: profile.tokenPath)

    let container = try await manager.refresh(using: state)
    #expect(container.token == refreshed)
    let requestBody = try #require(transport.first?.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: String])
    #expect(body == ["currentToken": original], "the refresh used a different read of the profile")
    #expect(try SessionTokenStore.readToken(atPath: profile.tokenPath) == refreshed)
  }

  @Test("An absent profile reports missingConfig — the same case SecurityTokenSigner reports")
  func absentProfileMatchesSignerError() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    // A well-formed config file that simply has no [session] profile.
    let profile = try makeSessionProfile(in: directory, profile: "other", token: sessionToken())

    let manager = SessionTokenManager(configFilePath: profile.configPath, profile: "session")
    let managerError = capturedError { _ = try manager.container() }
    let signerError = capturedError {
      _ = try SecurityTokenSigner(configFilePath: profile.configPath, configName: "session")
    }
    #expect(errorName(managerError) == "missingConfig")
    // Parity asserted directly against the signer for the same file and profile: a
    // caller already handling SecurityTokenSigner's errors needs no second path.
    #expect(errorName(signerError) == errorName(managerError))

    // Every entry point of the lifecycle reports it, not only `container()`.
    #expect(errorName(capturedError { _ = try manager.signer() }) == "missingConfig")
    let validateError = await capturedAsyncError { _ = try await manager.validate() }
    #expect(errorName(validateError) == "missingConfig")
    let refreshError = await capturedAsyncError { _ = try await manager.refresh() }
    #expect(errorName(refreshError) == "missingConfig")
  }

  @Test("A config file that cannot be parsed reports badConfigFileFormat, as SecurityTokenSigner does")
  func unparseableConfigMatchesSignerError() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/config"
    _ = try writeUndecodableConfig(atPath: configPath, readableProfiles: "[session]\nregion=us-phoenix-1\n")

    let manager = SessionTokenManager(configFilePath: configPath, profile: "session")
    let managerError = capturedError { _ = try manager.container() }
    let signerError = capturedError {
      _ = try SecurityTokenSigner(configFilePath: configPath, configName: "session")
    }
    #expect(errorName(managerError) == "badConfigFileFormat")
    #expect(errorName(signerError) == errorName(managerError))
  }

  @Test("A config file that does not exist reports badConfigFileFormat, as SecurityTokenSigner does")
  func missingConfigFileMatchesSignerError() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let configPath = "\(directory)/does-not-exist"

    let manager = SessionTokenManager(configFilePath: configPath, profile: "session")
    let managerError = capturedError { _ = try manager.container() }
    let signerError = capturedError {
      _ = try SecurityTokenSigner(configFilePath: configPath, configName: "session")
    }
    #expect(errorName(managerError) == "badConfigFileFormat")
    #expect(errorName(signerError) == errorName(managerError))
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
