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
// Hermetic wire tests for the session-token (UPST) lifecycle: fixture replay for
// the Auth Service and Identity responses, and request-shape assertions for the
// requests the SDK builds. Offline — no ~/.oci/config, no credentials, no
// network. Every file touched lives in a per-test temporary directory.
//
// ## Why these fixtures are synthetic
//
// Unlike every other fixture under `Fixtures/`, `sessionRefresh*.json`,
// `generateUpst*.json` and `sessionValidateListRegions*.json` were **not**
// captured from live OCI, and must not be. The success body of a refresh or a
// `GenerateUpst` *is a credential* — a live user session token — and its claims
// carry the real user and tenancy OCIDs. Committing a capture would commit a
// secret and real OCIDs, both of which this repo forbids. The response shape
// here is a single `{"token": "<JWT>"}` field, so the fixtures carry a
// well-formed JWT built from EXAMPLE OCIDs instead, with a far-future `exp` so
// they never age out. The error bodies use the Auth Service's real `code`/
// `message` shape.
//

import Crypto
import Foundation
import Testing
import _CryptoExtras

@testable import OCIKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// No-op signer: these tests exercise request building and response parsing, not
// signature correctness. Sessions the SDK signs with are covered by the keyId
// assertions below, which use a real ``SecurityTokenSigner``.
private struct StubSigner: Signer {
  func sign(_ req: inout URLRequest) async throws {
    req.setValue("stub", forHTTPHeaderField: "Authorization")
  }
}

private actor RequestRecorder {
  private(set) var last: URLRequest?
  /// How many requests the transport was asked to perform, so a test can assert
  /// that a call was made — or that none was.
  private(set) var count = 0

  func record(_ request: URLRequest) {
    last = request
    count += 1
  }
}

/// Records the request and replays a committed fixture as the response, so one
/// test can assert on both halves of the exchange.
private func recordingTransport(fixture: HTTPFixture, into recorder: RequestRecorder) -> HTTPClient {
  HTTPClient { request in
    await recorder.record(request)
    return fixture.makeResponse()
  }
}

private func fixtureURL(_ name: String) -> URL {
  URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)")
}

private func loadFixture(_ name: String) throws -> HTTPFixture {
  try HTTPFixture.load(fromFile: fixtureURL(name))
}

/// The `token` field of a fixture body, i.e. what the SDK is expected to return.
private func fixtureToken(_ name: String) throws -> String {
  let fixture = try loadFixture(name)
  let object = try #require(try JSONSerialization.jsonObject(with: fixture.body) as? [String: Any])
  return try #require(object["token"] as? String)
}

/// A throwaway RSA key for signing the requests under test.
private func makeSessionKey() throws -> _RSA.Signing.PrivateKey {
  try _RSA.Signing.PrivateKey(keySize: .bits2048)
}

private func makeTempDirectory() throws -> String {
  let path = NSTemporaryDirectory() + "oci-session-wire-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

/// A session token that is valid now, so it can legitimately be refreshed.
private func liveSessionToken() -> String {
  let now = Int(Date().timeIntervalSince1970)
  let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
  let payload = try! JSONSerialization.data(withJSONObject: [
    "iat": now,
    "exp": now + 3600,
    "sub": "ocid1.user.oc1..EXAMPLE",
    "tenant": "ocid1.tenancy.oc1..EXAMPLE",
  ])
  func segment(_ data: Data) -> String {
    data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
  }
  return "\(segment(header)).\(segment(payload)).c2ln"
}

// MARK: - Fixture replay

struct SessionTokenHermeticTests {
  @Test("refreshSecurityToken decodes the token from a captured-shape refresh response")
  func refreshDecodesToken() async throws {
    let http = try HTTPClient.replaying(fromFile: fixtureURL("sessionRefresh.json"))
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: http)

    let token = try await client.refreshSecurityToken(
      currentToken: liveSessionToken(),
      privateKey: try makeSessionKey()
    )
    #expect(token == (try fixtureToken("sessionRefresh.json")))

    // The refreshed token parses, and its claims are the ones a caller reports.
    let container = try SecurityTokenContainer(token: token)
    #expect(container.subject == "ocid1.user.oc1..EXAMPLE")
    #expect(container.tenancyId == "ocid1.tenancy.oc1..EXAMPLE")
    #expect(container.isValid())
  }

  @Test("refreshSecurityToken: a 401 maps to refreshRejected, not a generic failure")
  func refreshUnauthorizedMapsToRejection() async throws {
    let http = try HTTPClient.replaying(fromFile: fixtureURL("sessionRefresh_401.json"))
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: http)

    await #expect(throws: SessionTokenError.refreshRejected) {
      try await client.refreshSecurityToken(currentToken: liveSessionToken(), privateKey: try makeSessionKey())
    }
  }

  @Test("generateUserSecurityToken decodes the issued token from a GenerateUpst response")
  func generateDecodesToken() async throws {
    let http = try HTTPClient.replaying(fromFile: fixtureURL("generateUpst.json"))
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: http)
    let keyPair = try SessionKeyPair.generate()

    let token = try await client.generateUserSecurityToken(
      publicKeyPEM: keyPair.publicKeyPEM,
      sessionExpirationInMinutes: 60,
      signer: StubSigner()
    )
    #expect(token == (try fixtureToken("generateUpst.json")))
  }

  @Test("generateUserSecurityToken: a non-2xx carries the status and body through")
  func generateErrorMapping() async throws {
    let fixture = try loadFixture("generateUpst_409.json")
    let client = try SessionTokenClient(region: "us-phoenix-1", transport: .replaying(fixture))

    await #expect(throws: SessionTokenError.self) {
      try await client.generateUserSecurityToken(publicKeyPEM: "-----BEGIN PUBLIC KEY-----", signer: StubSigner())
    }
    // The body is preserved for diagnostics rather than swallowed.
    do {
      _ = try await client.generateUserSecurityToken(publicKeyPEM: "-----BEGIN PUBLIC KEY-----", signer: StubSigner())
      Issue.record("expected the 409 to throw")
    }
    catch let error as SessionTokenError {
      guard case .tokenGenerationFailed(let status, let message) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(status == 409)
      #expect(message.contains("IncorrectState"))
    }
  }

  @Test("validateWithService accepts a 200 from ListRegions and rejects a 401")
  func validateAgainstFixtures() async throws {
    let token = liveSessionToken()
    let key = try makeSessionKey()

    let ok = try SessionTokenClient(
      region: "us-phoenix-1",
      transport: try .replaying(fromFile: fixtureURL("sessionValidateListRegions.json"))
    )
    try await ok.validateWithService(token: token, privateKey: key)

    let denied = try SessionTokenClient(
      region: "us-phoenix-1",
      transport: try .replaying(fromFile: fixtureURL("sessionValidateListRegions_401.json"))
    )
    await #expect(throws: SessionTokenError.rejectedByService) {
      try await denied.validateWithService(token: token, privateKey: key)
    }
  }
}

// MARK: - Request shape

struct SessionTokenRequestShapeTests {
  @Test("The refresh request is a signed POST of {currentToken} to /v1/authentication/refresh")
  func refreshRequestShape() async throws {
    let recorder = RequestRecorder()
    let current = liveSessionToken()
    let client = try SessionTokenClient(
      region: "us-phoenix-1",
      transport: recordingTransport(fixture: try loadFixture("sessionRefresh.json"), into: recorder)
    )
    _ = try await client.refreshSecurityToken(currentToken: current, privateKey: try makeSessionKey())

    let request = try #require(await recorder.last)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.host == "auth.us-phoenix-1.oraclecloud.com")
    #expect(request.url?.path == "/v1/authentication/refresh")
    #expect(request.url?.query == nil)
    #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "accept") == "application/json")
    #expect(request.timeoutInterval == SessionTokenClient.timeoutSeconds)

    let body = try #require(request.httpBody)
    let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
    #expect(decoded == ["currentToken": current])

    // Signed with the token being refreshed, and — because it is a POST — over
    // the body as well.
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.contains(#"keyId="ST$\#(current)""#))
    #expect(authorization.contains("x-content-sha256"))
    #expect(request.value(forHTTPHeaderField: "x-content-sha256") != nil)
    #expect(request.value(forHTTPHeaderField: "content-length") == String(body.count))
  }

  @Test("The GenerateUpst request carries the full public key PEM, the duration, and opc-request-id")
  func generateRequestShape() async throws {
    let recorder = RequestRecorder()
    let keyPair = try SessionKeyPair.generate()
    let client = try SessionTokenClient(
      region: "us-phoenix-1",
      transport: recordingTransport(fixture: try loadFixture("generateUpst.json"), into: recorder)
    )
    _ = try await client.generateUserSecurityToken(
      publicKeyPEM: keyPair.publicKeyPEM,
      sessionExpirationInMinutes: 15,
      signer: StubSigner(),
      requestId: "test-request-id"
    )

    let request = try #require(await recorder.last)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/token/upst/actions/GenerateUpst")
    #expect(request.value(forHTTPHeaderField: "opc-request-id") == "test-request-id")
    // The caller's signer is the one that authenticates this call.
    #expect(request.value(forHTTPHeaderField: "Authorization") == "stub")

    let body = try #require(request.httpBody)
    let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(decoded["sessionExpirationInMinutes"] as? Int == 15)
    // Sent as a complete PEM — the X.509 federation flow strips the armour, this
    // one must not.
    let sentPEM = try #require(decoded["publicKey"] as? String)
    #expect(sentPEM == keyPair.publicKeyPEM)
    #expect(sentPEM.contains("-----BEGIN PUBLIC KEY-----"))
    #expect(sentPEM.contains("-----END PUBLIC KEY-----"))
  }

  @Test("The remote-validation request is a signed GET of ListRegions on the identity host")
  func validateRequestShape() async throws {
    let recorder = RequestRecorder()
    let token = liveSessionToken()
    let client = try SessionTokenClient(
      region: "us-phoenix-1",
      transport: recordingTransport(fixture: try loadFixture("sessionValidateListRegions.json"), into: recorder)
    )
    try await client.validateWithService(token: token, privateKey: try makeSessionKey())

    let request = try #require(await recorder.last)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.host == "identity.us-phoenix-1.oci.oraclecloud.com")
    #expect(request.url?.path == "/20160918/regions")
    #expect(request.httpBody == nil)
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.contains(#"keyId="ST$\#(token)""#))
    // A GET is signed over the generic headers only — no body digest.
    #expect(!authorization.contains("x-content-sha256"))
  }
}

// MARK: - Profile-level replay

struct SessionTokenManagerWireTests {
  /// Writes a session profile whose token is `token`, and returns its paths.
  private func makeProfile(in directory: String, token: String) throws -> (config: String, tokenPath: String) {
    let keyPair = try SessionKeyPair.generate()
    let config = "\(directory)/config"
    let keyPath = "\(directory)/oci_api_key.pem"
    let tokenPath = "\(directory)/token"
    try SessionTokenStore.writePrivateKey(keyPair.privateKeyPEM, toPath: keyPath)
    try SessionTokenStore.writeToken(token, toPath: tokenPath)
    try SessionTokenStore.upsertProfile(
      configFilePath: config,
      profile: "session",
      entries: [
        (key: "region", value: "us-phoenix-1"),
        (key: "key_file", value: keyPath),
        (key: "security_token_file", value: tokenPath),
        (key: "fingerprint", value: keyPair.fingerprint),
      ]
    )
    return (config, tokenPath)
  }

  @Test("refresh() replays a refresh response and leaves the profile pointing at the new token")
  func refreshWritesFixtureTokenToProfile() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let profile = try makeProfile(in: directory, token: liveSessionToken())
    let http = try HTTPClient.replaying(fromFile: fixtureURL("sessionRefresh.json"))

    let manager = SessionTokenManager(configFilePath: profile.config, profile: "session", transport: http)
    let container = try await manager.refresh()

    let expected = try fixtureToken("sessionRefresh.json")
    #expect(container.token == expected)
    #expect(try SessionTokenStore.readToken(atPath: profile.tokenPath) == expected)
    // A signer built from the profile afterwards signs with the refreshed token,
    // which is the whole point of writing it back.
    var request = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
    try await manager.signer().sign(&request)
    #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("ST$\(expected)") == true)
  }

  @Test("validate() contacts the service by default, and validate(local: true) makes no request")
  func validateDefaultsToTheServiceCheck() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let profile = try makeProfile(in: directory, token: liveSessionToken())
    let recorder = RequestRecorder()
    let manager = SessionTokenManager(
      configFilePath: profile.config,
      profile: "session",
      transport: recordingTransport(fixture: try loadFixture("sessionValidateListRegions.json"), into: recorder)
    )

    // Plain `oci session validate` asks the service, which is the only check that
    // catches a session terminated before its token expired — so the default must
    // not be the offline one.
    try await manager.validate()
    #expect(await recorder.count == 1)
    let request = try #require(await recorder.last)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.host == "identity.us-phoenix-1.oci.oraclecloud.com")
    #expect(request.url?.path == "/20160918/regions")

    // `--local` is the opt-in that stays offline.
    try await manager.validate(local: true)
    #expect(await recorder.count == 1)
  }

  @Test("A 401 refresh leaves the profile's token file exactly as it was")
  func rejectedRefreshDoesNotTouchProfile() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let original = liveSessionToken()
    let profile = try makeProfile(in: directory, token: original)
    let http = try HTTPClient.replaying(fromFile: fixtureURL("sessionRefresh_401.json"))

    let manager = SessionTokenManager(configFilePath: profile.config, profile: "session", transport: http)
    await #expect(throws: SessionTokenError.refreshRejected) { try await manager.refresh() }
    #expect(try SessionTokenStore.readToken(atPath: profile.tokenPath) == original)
  }

  @Test("authenticate() persists the issued token in the CLI's session layout")
  func authenticatePersistsIssuedToken() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let http = try HTTPClient.replaying(fromFile: fixtureURL("generateUpst.json"))

    let session = try await SessionTokenManager.authenticate(
      using: StubSigner(),
      region: "us-phoenix-1",
      profile: "wire-session",
      configFilePath: "\(directory)/config",
      sessionsDirectory: "\(directory)/sessions",
      transport: http
    )

    let expected = try fixtureToken("generateUpst.json")
    #expect(session.container.token == expected)
    #expect(session.paths.tokenPath == "\(directory)/sessions/wire-session/token")
    #expect(try SessionTokenStore.readToken(atPath: session.paths.tokenPath) == expected)

    let section = try SessionTokenStore.profileSection(
      configFilePath: "\(directory)/config",
      profile: "wire-session"
    )
    #expect(section["security_token_file"] == session.paths.tokenPath)
    #expect(section["key_file"] == session.paths.privateKeyPath)
    #expect(section["user"] == "ocid1.user.oc1..EXAMPLE")
    #expect(section["tenancy"] == "ocid1.tenancy.oc1..EXAMPLE")
  }
}
