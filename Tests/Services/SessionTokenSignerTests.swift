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
// Credential-free, offline tests for `SessionTokenSigner` — the self-maintaining
// signer for a `security_token` (UPST) config profile. No ~/.oci, no network, no
// credentials, no environment variables: every profile these tests read lives in
// a per-test temporary directory, and the refresh exchange is answered by an
// injected `HTTPClient`.
//
// What is pinned here is exactly what the type claims over `SecurityTokenSigner`,
// which snapshots its token at init and signs with it forever:
//
//   * a session still inside its half-life is signed with as-is, with no wire
//     call at all;
//   * a session past its half-life is refreshed once, the refreshed token is what
//     subsequent requests are signed with, and it is written back to the
//     profile's `security_token_file` so the CLI and other processes see it;
//   * a session refreshed **out of band** (`oci session refresh`, another
//     process) is picked up from disk with no redundant wire call — the whole
//     reason this type re-reads the profile instead of caching it;
//   * a burst of concurrent `sign(_:)` calls past the half-life refreshes once,
//     not N times, and every one of them carries the same refreshed token;
//   * a session the service is done with (`401`) surfaces as an error instead of
//     being signed with, and leaves the on-disk token alone;
//   * an already-expired session fails before any request is made.
//
// ## Fixtures and tokens
//
// The `401` body is the committed `sessionRefresh_401.json` fixture, i.e. the
// Auth Service's real error shape. Success bodies are built in-test rather than
// replayed, because these tests need tokens with *specific* validity windows
// (fresh / past half-life / expired) and the committed success fixture carries a
// far-future `exp` on purpose. The tokens are synthetic JWTs over EXAMPLE OCIDs
// built the same way the other signer suites build theirs — see the note at the
// top of `SessionTokenHermeticTests.swift` for why a real session token must
// never be committed.
//
// The gate/counter scaffolding (``ImdsGate``, ``EnteredCounter``, ``openGate``,
// ``SignedRequestObservation``, ``httpResponse(_:_:)``) is shared with the
// instance-principal suites; see `InstancePrincipalTestSupport.swift` and
// `InstancePrincipalConcurrencyTests.swift`.
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

// MARK: - Synthetic session tokens

/// Builds a session-token JWT with an explicit validity window.
///
/// - Parameters:
///   - issuedAt: the `iat` claim, in epoch seconds.
///   - expiry: the `exp` claim, in epoch seconds.
///   - marker: makes two tokens with the same window distinguishable strings.
private func makeSessionToken(issuedAt: Int, expiry: Int, marker: String) -> String {
  ipMakeJWT(claims: [
    "iat": issuedAt,
    "exp": expiry,
    "sub": "ocid1.user.oc1..EXAMPLE",
    "tenant": "ocid1.tenancy.oc1..EXAMPLE",
    "marker": marker,
  ])
}

/// A session comfortably inside the first half of its validity window, so the
/// signer must use it as-is.
private func freshSessionToken(marker: String) -> String {
  let now = Int(Date().timeIntervalSince1970)
  return makeSessionToken(issuedAt: now, expiry: now + 3600, marker: marker)
}

/// A session that is still valid — so it can legitimately be refreshed — but past
/// its half-life, so the signer must not keep signing with it.
/// The window is deliberately long (issued an hour ago, ten minutes still to run)
/// rather than only just past its midpoint: the midpoint is what makes it stale,
/// and the ten minutes of headroom keep the token from *expiring* mid-test on a
/// loaded CI runner, where a single test in this suite can take tens of seconds.
private func staleSessionToken(marker: String) -> String {
  let now = Int(Date().timeIntervalSince1970)
  return makeSessionToken(issuedAt: now - 3600, expiry: now + 600, marker: marker)
}

/// A session that has already ended, which no refresh can recover.
private func expiredSessionToken(marker: String) -> String {
  let now = Int(Date().timeIntervalSince1970)
  return makeSessionToken(issuedAt: now - 7200, expiry: now - 60, marker: marker)
}

// MARK: - A session profile on disk

/// A throwaway `security_token` config profile — key file, token file, and a
/// config file pointing at both — written under a per-test temporary directory.
private struct SessionProfileFixture {
  let profile: String
  let directory: String
  let configFilePath: String
  let tokenFilePath: String
  let keyFilePath: String

  /// Writes a complete session profile whose `security_token_file` holds `token`.
  static func make(token: String, profile: String = "session-signer") throws -> SessionProfileFixture {
    let directory = NSTemporaryDirectory() + "oci-session-signer-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let base = URL(fileURLWithPath: directory, isDirectory: true)
    let fixture = SessionProfileFixture(
      profile: profile,
      directory: directory,
      configFilePath: base.appending(path: "config").path,
      tokenFilePath: base.appending(path: "token").path,
      keyFilePath: base.appending(path: "oci_api_key.pem").path
    )
    let keyPair = try SessionKeyPair.generate()
    try SessionTokenStore.writePrivateKey(keyPair.privateKeyPEM, toPath: fixture.keyFilePath)
    try SessionTokenStore.writeToken(token, toPath: fixture.tokenFilePath)
    try SessionTokenStore.upsertProfile(
      configFilePath: fixture.configFilePath,
      profile: profile,
      entries: [
        (key: "region", value: "us-phoenix-1"),
        (key: "key_file", value: fixture.keyFilePath),
        (key: "security_token_file", value: fixture.tokenFilePath),
        (key: "fingerprint", value: keyPair.fingerprint),
      ]
    )
    return fixture
  }

  /// Rewrites the profile's token file, simulating `oci session refresh` or
  /// another process extending the session behind the signer's back.
  func rewriteToken(_ token: String) throws {
    try SessionTokenStore.writeToken(token, toPath: tokenFilePath)
  }

  /// The token currently on disk.
  func tokenOnDisk() throws -> String {
    try SessionTokenStore.readToken(atPath: tokenFilePath)
  }

  func remove() {
    try? FileManager.default.removeItem(atPath: directory)
  }
}

// MARK: - A counting Auth Service stub

/// Stands in for the Auth Service refresh endpoint: counts every request, records
/// the path it was made to, and answers with scripted tokens (the last one
/// repeating) or a committed error fixture.
///
/// `Mutex` is `~Copyable` and so cannot be captured by the `@Sendable` transport
/// closure directly; wrapping it in a `Sendable` reference type is the approach
/// ``SessionKeyLedger`` and ``EnteredCounter`` already take in this target.
private final class RefreshStub: Sendable {
  private struct State {
    var issuing: [String]
    var errorFixture: HTTPFixture?
    var requestedPaths: [String] = []
    var currentTokensSent: [String] = []
  }

  private let box: Mutex<State>

  /// - Parameters:
  ///   - issuing: tokens to hand back, consumed front-first; the last one repeats
  ///     for any further request.
  ///   - errorFixture: when set, every request is answered with this committed
  ///     fixture instead of a token.
  private init(issuing: [String], errorFixture: HTTPFixture?) {
    box = Mutex(State(issuing: issuing, errorFixture: errorFixture))
  }

  /// A stub that issues `tokens`.
  static func issuing(_ tokens: String...) -> RefreshStub {
    RefreshStub(issuing: tokens, errorFixture: nil)
  }

  /// A stub that answers every refresh with the committed `sessionRefresh_401.json`
  /// body — the Auth Service's answer once a user session is over.
  static func rejectingEverything() throws -> RefreshStub {
    let url = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "Fixtures/sessionRefresh_401.json")
    return RefreshStub(issuing: [], errorFixture: try HTTPFixture.load(fromFile: url))
  }

  /// How many requests the stub has been asked to serve.
  var callCount: Int { box.withLock { $0.requestedPaths.count } }
  /// The paths of every request, in arrival order.
  var requestedPaths: [String] { box.withLock { $0.requestedPaths } }
  /// The `currentToken` of every refresh body, in arrival order.
  var currentTokensSent: [String] { box.withLock { $0.currentTokensSent } }

  /// The stub as an injectable transport.
  ///
  /// - Parameter gate: when supplied, a request is counted on arrival and then
  ///   parks until the gate opens, so a test can hold one exchange in flight for
  ///   as long as it needs instead of racing a wall-clock window.
  func transport(gate: ImdsGate? = nil) -> HTTPClient {
    HTTPClient { [self] request in
      let url = request.url ?? URL(string: "https://auth.invalid/")!
      let outcome = box.withLock { state -> Result<(Data, URLResponse), any Error> in
        state.requestedPaths.append(url.path)
        if let body = request.httpBody,
          let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let current = payload["currentToken"] as? String
        {
          state.currentTokensSent.append(current)
        }
        if let fixture = state.errorFixture {
          let (data, response) = fixture.makeResponse()
          return .success((data, response))
        }
        // Consume the scripted tokens front-first, but keep the last one so a
        // stub scripted with one token can serve any number of requests.
        let scripted = state.issuing.count > 1 ? state.issuing.removeFirst() : state.issuing.first
        guard let token = scripted else {
          return .success((Data("no token scripted".utf8), httpResponse(url, 500)))
        }
        do {
          return .success((try JSONSerialization.data(withJSONObject: ["token": token]), httpResponse(url, 200)))
        }
        catch {
          return .failure(error)
        }
      }
      if let gate { try await gate.waitUntilOpen() }
      return try outcome.get()
    }
  }
}

// MARK: - Signing helpers

/// A fresh, query-free GET — the shape ``SignedRequestObservation`` can read back.
private func sessionServiceRequest() -> URLRequest {
  var request = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
  request.httpMethod = "GET"
  return request
}

/// Signs a fresh request and returns the session token the signature was made
/// under, read out of the `keyId="ST$<token>"` field.
private func signAndReadToken(_ signer: SessionTokenSigner) async throws -> String {
  var request = sessionServiceRequest()
  try await signer.sign(&request)
  return try SignedRequestObservation(request: request).token
}

/// Builds a signer for `fixture` over `stub`, with no live config or network in
/// reach: the config path is the fixture's, and the transport is the stub's.
private func makeSessionSigner(
  for fixture: SessionProfileFixture,
  stub: RefreshStub,
  gate: ImdsGate? = nil
) -> SessionTokenSigner {
  SessionTokenSigner(
    configFilePath: fixture.configFilePath,
    profile: fixture.profile,
    transport: stub.transport(gate: gate),
    logger: Logger(label: "test")
  )
}

// MARK: - Suite

struct SessionTokenSignerTests {

  // MARK: A fresh session is used as-is

  @Test("a session inside its half-life is signed with directly, with no wire call")
  func freshSessionSignsWithoutRefreshing() async throws {
    let token = freshSessionToken(marker: "fresh")
    let fixture = try SessionProfileFixture.make(token: token)
    defer { fixture.remove() }
    let stub = RefreshStub.issuing(freshSessionToken(marker: "unexpected"))
    let signer = makeSessionSigner(for: fixture, stub: stub)

    var request = sessionServiceRequest()
    try await signer.sign(&request)

    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.contains(#"keyId="ST$\#(token)""#))
    #expect(stub.callCount == 0, "a fresh session must not be refreshed: \(stub.requestedPaths)")

    // Repeated signing stays offline, and the profile is left exactly as it was.
    #expect(try await signAndReadToken(signer) == token)
    #expect(stub.callCount == 0)
    #expect(try fixture.tokenOnDisk() == token)
  }

  @Test("a session in its last seconds is still refreshed rather than abandoned")
  func nearlyExpiredSessionStillAsksTheService() async throws {
    // `SessionTokenManager.refresh()` refuses, by default, to spend a round trip on
    // a session with under a minute left. This signer deliberately opts out: its
    // alternative is failing the caller's request and demanding an interactive
    // re-authentication, so while the session is alive at all it is worth asking.
    let extended = freshSessionToken(marker: "extended")
    // The window this test needs is narrow — inside the manager's default slack but
    // not yet expired — so every slow step (RSA keygen for the fixture, the config
    // write) happens BEFORE the clock is read, and the token is given as much of
    // that slack as it can have. Reading `now` first and generating a keypair
    // afterwards is what made this expire for real on CI.
    let fixture = try SessionProfileFixture.make(token: freshSessionToken(marker: "placeholder"))
    defer { fixture.remove() }
    let stub = RefreshStub.issuing(extended)
    let signer = makeSessionSigner(for: fixture, stub: stub)

    let now = Int(Date().timeIntervalSince1970)
    let slack = SecurityTokenContainer.defaultExpiryJitterSeconds
    let expiring = makeSessionToken(issuedAt: now - 3600, expiry: now + slack - 15, marker: "expiring")
    try fixture.rewriteToken(expiring)
    // Precondition: alive, but inside the slack the manager's own gate applies.
    let container = try SecurityTokenContainer(token: expiring)
    #expect(container.isValid())
    #expect(!container.isValid(jitterSeconds: slack))

    #expect(try await signAndReadToken(signer) == extended)
    #expect(stub.callCount == 1, "the exchange must be attempted, not skipped: \(stub.requestedPaths)")
    #expect(try fixture.tokenOnDisk() == extended)
  }

  @Test("the profile's region is readable without a wire call")
  func regionComesFromTheProfile() async throws {
    let fixture = try SessionProfileFixture.make(token: freshSessionToken(marker: "region"))
    defer { fixture.remove() }
    let stub = RefreshStub.issuing(freshSessionToken(marker: "unexpected"))
    let signer = makeSessionSigner(for: fixture, stub: stub)

    #expect(try await signer.regionId() == "us-phoenix-1")
    #expect(stub.callCount == 0)
  }

  // MARK: Past the half-life: refresh once, sign with the new token, write it back

  @Test("a session past its half-life refreshes exactly once and signs with the refreshed token")
  func staleSessionRefreshesOnceAndSignsWithTheNewToken() async throws {
    let original = staleSessionToken(marker: "original")
    let refreshed = freshSessionToken(marker: "refreshed")
    let fixture = try SessionProfileFixture.make(token: original)
    defer { fixture.remove() }
    let stub = RefreshStub.issuing(refreshed)
    let signer = makeSessionSigner(for: fixture, stub: stub)

    #expect(try await signAndReadToken(signer) == refreshed)
    #expect(stub.callCount == 1)
    // The refresh went to the Auth Service's refresh operation, signed with the
    // token being replaced.
    #expect(stub.requestedPaths == ["/v1/authentication/refresh"])
    #expect(stub.currentTokensSent == [original])

    // Written back to the profile, so the CLI and any other process see it too.
    #expect(try fixture.tokenOnDisk() == refreshed)

    // And the new token is fresh, so the next request adds no traffic.
    #expect(try await signAndReadToken(signer) == refreshed)
    #expect(stub.callCount == 1)
  }

  // MARK: The point of the type: adopt a session refreshed out of band

  @Test("a session refreshed out of band is adopted from disk with no wire call")
  func outOfBandRefreshIsAdoptedWithoutRefreshing() async throws {
    // The signer's first refresh is answered with a token that is itself already
    // past its half-life, so its cache is stale again immediately — the state in
    // which a snapshotting signer would keep signing with a superseded token.
    let original = staleSessionToken(marker: "original")
    let wireToken = staleSessionToken(marker: "from-the-wire")
    let fixture = try SessionProfileFixture.make(token: original)
    defer { fixture.remove() }
    let stub = RefreshStub.issuing(wireToken)
    let signer = makeSessionSigner(for: fixture, stub: stub)

    #expect(try await signAndReadToken(signer) == wireToken)
    #expect(stub.callCount == 1)

    // `oci session refresh` (or another process) extends the session behind the
    // signer's back.
    let outOfBand = freshSessionToken(marker: "out-of-band")
    try fixture.rewriteToken(outOfBand)

    // The stale cache is resolved by re-reading the profile, not by asking the
    // service again: the out-of-band token is adopted and no second refresh is
    // made. This is the claim `SecurityTokenSigner` cannot make.
    #expect(try await signAndReadToken(signer) == outOfBand)
    #expect(
      stub.callCount == 1,
      "the out-of-band token should have been adopted from disk, not re-refreshed: \(stub.requestedPaths)"
    )
    #expect(try fixture.tokenOnDisk() == outOfBand)
  }

  // MARK: A session the service is done with

  @Test("a refresh the service rejects surfaces the error and leaves the on-disk token untouched")
  func rejectedRefreshSurfacesAndPreservesTheProfile() async throws {
    let original = staleSessionToken(marker: "doomed")
    let fixture = try SessionProfileFixture.make(token: original)
    defer { fixture.remove() }
    let stub = try RefreshStub.rejectingEverything()
    let signer = makeSessionSigner(for: fixture, stub: stub)

    var request = sessionServiceRequest()
    await #expect(throws: SessionTokenError.refreshRejected) { try await signer.sign(&request) }
    // Nothing was signed with a session the service has finished with.
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(stub.callCount == 1)
    #expect(try fixture.tokenOnDisk() == original)

    // A failed exchange does not poison the signer: the next attempt tries again
    // rather than replaying the dead task's error forever.
    await #expect(throws: SessionTokenError.refreshRejected) { try await signer.refreshIfNeeded() }
    #expect(stub.callCount == 2)
    #expect(try fixture.tokenOnDisk() == original)
  }

  @Test("an already-expired session fails before any request is made")
  func expiredSessionFailsWithoutTouchingTheWire() async throws {
    let expired = expiredSessionToken(marker: "over")
    let fixture = try SessionProfileFixture.make(token: expired)
    defer { fixture.remove() }
    let stub = RefreshStub.issuing(freshSessionToken(marker: "unreachable"))
    let signer = makeSessionSigner(for: fixture, stub: stub)

    var request = sessionServiceRequest()
    do {
      try await signer.sign(&request)
      Issue.record("expected an expired session to throw")
    }
    catch let error as SessionTokenError {
      guard case .sessionExpired = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(stub.callCount == 0, "an expired session cannot be refreshed, so nothing should be sent")
  }

  // MARK: forceRefresh (the 401 path)

  @Test("forceRefresh replaces a token the service rejected and the next sign uses the new one")
  func forceRefreshObtainsNewMaterial() async throws {
    // The on-disk session is still locally fresh, which is exactly the case the
    // on-disk shortcut must refuse after a 401: re-adopting it would re-sign the
    // retry with the token the service just refused.
    let rejected = freshSessionToken(marker: "rejected")
    let replacement = freshSessionToken(marker: "replacement")
    let fixture = try SessionProfileFixture.make(token: rejected)
    defer { fixture.remove() }
    let stub = RefreshStub.issuing(replacement)
    let signer = makeSessionSigner(for: fixture, stub: stub)

    // Prime: the fresh on-disk session is adopted offline.
    #expect(try await signAndReadToken(signer) == rejected)
    #expect(stub.callCount == 0)

    try await signer.forceRefresh()
    #expect(stub.callCount == 1)
    #expect(stub.currentTokensSent == [rejected])
    #expect(try await signAndReadToken(signer) == replacement)
    #expect(stub.callCount == 1)
    #expect(try fixture.tokenOnDisk() == replacement)
  }

  @Test("after a rejected 401 a routine refresh does not fall back to the rejected token on disk")
  func routineRefreshAfterARejectionDoesNotReadoptTheRejectedToken() async throws {
    // The rejected session is still locally *fresh*, so the on-disk shortcut would
    // happily hand it back. Holding the rejection only for the duration of the
    // forced exchange is not enough: once that exchange fails, the next ordinary
    // `sign(_:)` starts a routine exchange that knows nothing about the 401 and
    // re-adopts the very token the service refused — every later request is then
    // signed with a dead token and the caller never sees `refreshRejected`.
    let rejected = freshSessionToken(marker: "rejected")
    let fixture = try SessionProfileFixture.make(token: rejected)
    defer { fixture.remove() }
    let stub = try RefreshStub.rejectingEverything()
    let signer = makeSessionSigner(for: fixture, stub: stub)

    #expect(try await signAndReadToken(signer) == rejected)
    #expect(stub.callCount == 0)

    await #expect(throws: SessionTokenError.refreshRejected) { try await signer.forceRefresh() }
    #expect(stub.callCount == 1)

    // The session is over, so this must surface as an error rather than as a
    // signature made with the rejected token.
    var request = sessionServiceRequest()
    await #expect(throws: SessionTokenError.refreshRejected) { try await signer.sign(&request) }
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(stub.callCount > 1, "the rejected token was adopted from disk instead of being refreshed")
    #expect(try fixture.tokenOnDisk() == rejected)
  }

  @Test("a session replaced out of band after a rejection is adopted, so a rejection is not permanent")
  func rejectionDoesNotOutliveTheRejectedToken() async throws {
    let rejected = freshSessionToken(marker: "rejected")
    let fixture = try SessionProfileFixture.make(token: rejected)
    defer { fixture.remove() }
    let stub = try RefreshStub.rejectingEverything()
    let signer = makeSessionSigner(for: fixture, stub: stub)

    #expect(try await signAndReadToken(signer) == rejected)
    await #expect(throws: SessionTokenError.refreshRejected) { try await signer.forceRefresh() }

    // A human ran `oci session authenticate` again. The new token is not the
    // rejected one, so it is adopted from disk with no further wire traffic.
    let renewed = freshSessionToken(marker: "renewed")
    try fixture.rewriteToken(renewed)
    let callsBefore = stub.callCount
    #expect(try await signAndReadToken(signer) == renewed)
    #expect(stub.callCount == callsBefore)
  }
}

// MARK: - Concurrency

struct SessionTokenSignerConcurrencyTests {

  @Test("a burst of concurrent sign calls past the half-life refreshes once and shares the new token")
  func concurrentSignsCoalesceOntoOneRefresh() async throws {
    let original = staleSessionToken(marker: "original")
    let refreshed = freshSessionToken(marker: "refreshed")
    let fixture = try SessionProfileFixture.make(token: original)
    defer { fixture.remove() }
    let stub = RefreshStub.issuing(refreshed)
    let gate = ImdsGate()
    let signer = makeSessionSigner(for: fixture, stub: stub, gate: gate)

    // Hold the refresh in flight until the whole wave has entered `sign(_:)`, so
    // the traffic count below means "they all overlapped" rather than "they were
    // fast enough". A loaded machine slows the test down instead of changing it.
    let waveSize = 24
    gate.close()
    let arrived = EnteredCounter()
    let opener = Task { await openGate(gate, onceEveryoneArrived: arrived, of: waveSize) }

    let tokens = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
      for _ in 0..<waveSize {
        group.addTask {
          arrived.increment()
          return try await signAndReadToken(signer)
        }
      }
      var collected: [String] = []
      for try await token in group { collected.append(token) }
      return collected
    }
    await opener.value

    #expect(tokens.count == waveSize)
    #expect(Set(tokens) == [refreshed], "the wave did not share one refreshed session: \(Set(tokens))")
    #expect(stub.callCount == 1, "the wave refreshed \(stub.callCount) times: \(stub.requestedPaths)")
    #expect(try fixture.tokenOnDisk() == refreshed)
  }

  @Test("a concurrent forceRefresh wave coalesces onto a single post-401 refresh")
  func concurrentForceRefreshesCoalesce() async throws {
    let rejected = freshSessionToken(marker: "rejected")
    let replacement = freshSessionToken(marker: "replacement")
    let fixture = try SessionProfileFixture.make(token: rejected)
    defer { fixture.remove() }
    let stub = RefreshStub.issuing(replacement)
    let gate = ImdsGate()
    let signer = makeSessionSigner(for: fixture, stub: stub, gate: gate)

    // Prime offline, so the wave below starts from a cached — and, as far as the
    // service is concerned, dead — session.
    try await signer.refreshIfNeeded()
    #expect(stub.callCount == 0)

    let waveSize = 12
    gate.close()
    let arrived = EnteredCounter()
    let opener = Task { await openGate(gate, onceEveryoneArrived: arrived, of: waveSize) }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<waveSize {
        group.addTask {
          arrived.increment()
          try await signer.forceRefresh()
        }
      }
      try await group.waitForAll()
    }
    await opener.value

    #expect(stub.callCount == 1, "the 401 wave refreshed \(stub.callCount) times: \(stub.requestedPaths)")
    #expect(try await signAndReadToken(signer) == replacement)
    #expect(stub.callCount == 1)
  }

  @Test("signs interleaved with 401 recoveries never fail with the signer's own cache error")
  func signsInterleavedWithForceRefreshesNeverReportNotPrimed() async throws {
    // `forceRefresh()` empties the cache synchronously, so it can empty it again in
    // the window between the exchange a `sign(_:)` was waiting on completing and
    // that `sign(_:)` being resumed. A request must not die there with "the signer
    // has no cached session" — `HTTPClient` treats a throwing `sign(_:)` as fatal
    // for the attempt, so a bogus cache error would surface as a failed call in the
    // middle of an ordinary 401 recovery.
    for round in 0..<3 {
      // The on-disk session is past its half-life, so every `sign(_:)` in the wave
      // parks on one gated exchange. Releasing the gate resumes them all just as the
      // exchange assigns the cache — precisely when the 401 loop is clearing it.
      let fixture = try SessionProfileFixture.make(token: staleSessionToken(marker: "round-\(round)"))
      defer { fixture.remove() }
      let stub = RefreshStub.issuing(freshSessionToken(marker: "replacement-\(round)"))
      let gate = ImdsGate()
      let signer = makeSessionSigner(for: fixture, stub: stub, gate: gate)

      let waveSize = 16
      gate.close()
      let arrived = EnteredCounter()
      let opener = Task { await openGate(gate, onceEveryoneArrived: arrived, of: waveSize) }
      let errors = await withTaskGroup(of: Error?.self) { group -> [Error?] in
        for _ in 0..<waveSize {
          group.addTask {
            arrived.increment()
            do {
              _ = try await signAndReadToken(signer)
              return nil
            }
            catch {
              return error
            }
          }
        }
        group.addTask {
          for _ in 0..<48 {
            try? await signer.forceRefresh()
            await Task.yield()
          }
          return nil
        }
        var collected: [Error?] = []
        for await error in group { collected.append(error) }
        return collected
      }
      await opener.value

      let cacheErrors = errors.compactMap { $0 as? SessionTokenSignerError }
      #expect(cacheErrors.isEmpty, "round \(round) failed with \(cacheErrors)")
    }
  }
}
