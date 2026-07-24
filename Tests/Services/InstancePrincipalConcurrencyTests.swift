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
// Concurrency tests for `InstancePrincipalSigner`'s actor + single-flight design
// (`SingleFlightExchange`). They complement, rather than repeat, the coalescing
// tests in `InstancePrincipalHermeticTests.swift`, which already pin "50 routine
// refreshes federate once" and the three `forceRefresh()` join rules.
//
// What is pinned here:
//
//   * A *failing* exchange throws to every caller that joined it and still runs
//     its `defer`, so the started/completed counters are not left wedged and the
//     signer recovers on the next refresh — on both the routine and the forced
//     path.
//   * An exchange outlives the cancellation of the callers awaiting it: no torn
//     bookkeeping, and no second exchange started to replace the "lost" one.
//   * Under an interleaved `sign()` / `refresh()` / `forceRefresh()` storm, every
//     signed request pairs the security token of one exchange with the ephemeral
//     session key *of that same exchange*. That is checked cryptographically, by
//     verifying the request signature against the session public key the exchange
//     that minted the token actually presented — a token paired with a sibling
//     exchange's key fails verification even though both halves are individually
//     valid.
//   * Repeated `forceRefresh()` waves that each land on an in-flight routine
//     exchange decline it and coalesce onto exactly one forced exchange, wave
//     after wave.
//
// ## Synchronisation, not sleeping
//
// An exact traffic count ("this wave federated once") only means something if
// every caller in the wave really did overlap the in-flight exchange. Rather than
// widen the window with a delay and hope, these tests hold the exchange open with
// ``ImdsGate``: the fake's `cert.pem` read parks until the test opens the gate,
// which it does only once the whole wave has arrived. The exchange therefore stays
// in flight for as long as the machine needs, so a loaded CI box slows the test
// down instead of changing its outcome.
//
// The in-memory IMDS + federation fake lives in `InstancePrincipalTestSupport.swift`.
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

// MARK: - Waiting for a known state

/// Polls until `condition` holds, sleeping between checks so a saturated
/// cooperative pool still makes progress. Gives up after `timeout` — letting the
/// caller's own expectations fail — rather than hanging the suite forever.
///
/// Prefixed `ip` for the same reason the shared builders in
/// `InstancePrincipalTestSupport.swift` are: a top-level `private` declaration in
/// this target does not shadow a same-named `internal` one elsewhere in the
/// module, it collides with it, and `waitUntil` is a name another suite could
/// plausibly want.
func ipWaitUntil(timeout: Swift.Duration = .seconds(30), _ condition: @Sendable () -> Bool) async {
  let deadline = ContinuousClock.now + timeout
  while !condition(), ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(1))
  }
}

/// A counter test callers use to record that they have reached a point of interest.
/// `Mutex` is `~Copyable`, so it cannot be captured directly by an escaping `Task`
/// closure; wrapping it in a `Sendable` reference type is the same approach
/// ``SessionKeyLedger`` uses.
final class EnteredCounter: Sendable {
  private let box = Mutex(0)

  /// Records that one more caller has arrived.
  func increment() { box.withLock { $0 += 1 } }

  /// How many callers have arrived.
  var value: Int { box.withLock { $0 } }
}

/// A gate the fake's IMDS `cert.pem` read parks on, so a test can hold a
/// federation exchange in flight for exactly as long as it needs — with no
/// wall-clock window to lose on a loaded machine.
final class ImdsGate: Sendable {
  private let box = Mutex(true)

  /// Whether certificate reads may proceed.
  var isOpen: Bool { box.withLock { $0 } }

  /// Parks subsequent IMDS certificate reads until ``open()``.
  func close() { box.withLock { $0 = false } }

  /// Lets the parked exchange run to completion.
  func open() { box.withLock { $0 = true } }

  /// Suspends until the gate opens.
  ///
  /// Throws `CancellationError` if the task waiting here is cancelled, because
  /// that is what a real in-flight `URLSession` read does — a fake that quietly
  /// finished a cancelled read would hide exactly the regression the cancellation
  /// test is looking for. Bounded, so a mistake fails the test rather than hanging
  /// the suite.
  func waitUntilOpen(timeout: Swift.Duration = .seconds(30)) async throws {
    let deadline = ContinuousClock.now + timeout
    while !isOpen, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
  }
}

/// Opens `gate` once `arrived` shows the whole wave has entered the call under
/// test, plus a short settle so a caller that has signalled but not yet reached
/// the actor still joins the in-flight exchange instead of starting a second one.
func openGate(_ gate: ImdsGate, onceEveryoneArrived arrived: EnteredCounter, of waveSize: Int) async {
  await ipWaitUntil { arrived.value >= waveSize }
  try? await Task.sleep(for: .milliseconds(50))
  gate.open()
}

// MARK: - Observing which exchange a signed request came from

/// The outcome of one concurrent refresh, reduced to a `Sendable` value so a task
/// group can collect it.
enum ConcurrentRefreshOutcome: Sendable, Equatable {
  case succeeded
  case failed(InstancePrincipalError)
  /// Something other than an ``InstancePrincipalError`` escaped, kept as text so a
  /// failure message says what it was.
  case failedUnexpectedly(String)
}

/// A signed request reduced to what is needed to tell which federation exchange
/// produced it: the security token in its `keyId`, plus the signature and the
/// exact bytes that were signed.
struct SignedRequestObservation: Sendable {
  /// The `<token>` from `keyId="ST$<token>"`.
  var token: String
  /// The raw RSA signature from the `signature="…"` field.
  var signature: Data
  /// The string `RequestSigner` signed, reconstructed from the request headers.
  var signingString: String

  /// Reads the observation out of a **query-free GET** signed by
  /// ``SecurityTokenSigner`` — the only shape these tests sign, so the signing
  /// string is the three-line `date`/`(request-target)`/`host` form.
  init(request: URLRequest) throws {
    guard
      let authorization = request.value(forHTTPHeaderField: "Authorization"),
      let keyId = Self.field("keyId", in: authorization),
      let signatureField = Self.field("signature", in: authorization),
      let signature = Data(base64Encoded: signatureField)
    else {
      throw SignedRequestObservationError("the request carries no parseable OCI Authorization header")
    }
    guard keyId.hasPrefix("ST$") else {
      throw SignedRequestObservationError("expected a security-token keyId, got \(keyId)")
    }
    guard
      let url = request.url,
      request.url?.query == nil,
      let date = request.value(forHTTPHeaderField: "date")
    else {
      throw SignedRequestObservationError("the request has no date header, or carries a query string")
    }
    // `URL.path` is exactly what the signer signed — deliberately re-read from the
    // request rather than hard-coded, since Foundation normalises the path.
    let path = url.path
    let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    self.token = String(keyId.dropFirst("ST$".count))
    self.signature = signature
    self.signingString = [
      "date: \(date)",
      "(request-target): \(request.httpMethod?.lowercased() ?? "") \(encodedPath)",
      "host: \(url.host ?? "")",
    ].joined(separator: "\n")
  }

  /// Whether this request was signed by the private half of `sanitizedPublicKey`
  /// (the single-line, header-stripped SPKI base64 the federation request carries).
  func isSigned(withSessionPublicKey sanitizedPublicKey: String) throws -> Bool {
    let key = try _RSA.Signing.PublicKey(pemRepresentation: Self.rewrapPublicKeyPEM(sanitizedPublicKey))
    return key.isValidSignature(
      _RSA.Signing.RSASignature(rawRepresentation: signature),
      for: Data(signingString.utf8),
      padding: .insecurePKCS1v1_5
    )
  }

  /// Extracts `name="value"` from an OCI `Authorization` header.
  private static func field(_ name: String, in header: String) -> String? {
    guard let start = header.range(of: "\(name)=\"") else { return nil }
    let rest = header[start.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    return String(rest[..<end])
  }

  /// Restores the PEM armour and 64-column wrapping that
  /// ``InstancePrincipalSigner/sanitizePEM(_:)`` stripped, so swift-crypto parses
  /// the key back. A single unwrapped line is rejected by the PEM parser, so the
  /// wrapping is not optional.
  private static func rewrapPublicKeyPEM(_ sanitized: String) -> String {
    var lines: [String] = []
    var index = sanitized.startIndex
    while index < sanitized.endIndex {
      let end = sanitized.index(index, offsetBy: 64, limitedBy: sanitized.endIndex) ?? sanitized.endIndex
      lines.append(String(sanitized[index..<end]))
      index = end
    }
    return "-----BEGIN PUBLIC KEY-----\n" + lines.joined(separator: "\n") + "\n-----END PUBLIC KEY-----"
  }
}

/// Raised when a request the tests signed cannot be read back.
struct SignedRequestObservationError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

// MARK: - Ledger: which session key did each exchange federate with

/// Records, per federation exchange, the ephemeral session public key that
/// exchange presented, keyed by the security token it was handed back.
///
/// The token is *rewritten* to a value unique to the exchange (the fake otherwise
/// hands out one constant token, which would make every exchange look alike), so
/// the mapping token → session key is injective and a signed request can be traced
/// back to exactly one exchange.
final class SessionKeyLedger: Sendable {
  private struct State {
    var keysByToken: [String: String] = [:]
    var order: [String] = []
  }

  private let box = Mutex(State())

  /// Assigns the exchange presenting `sessionPublicKey` a token unique to it.
  func mint(sessionPublicKey: String) -> String {
    box.withLock { state in
      let token = "ip-exchange-token-\(state.order.count + 1)"
      state.keysByToken[token] = sessionPublicKey
      state.order.append(token)
      return token
    }
  }

  /// The sanitized session public key the exchange that minted `token` presented.
  func sessionPublicKey(for token: String) -> String? { box.withLock { $0.keysByToken[token] } }

  /// Every token minted, in the order the exchanges obtained them.
  var mintedTokens: [String] { box.withLock { $0.order } }

  /// How many exchanges obtained a token.
  var mintedCount: Int { box.withLock { $0.order.count } }
}

// MARK: - What a signing worker observed

/// What one worker saw while signing: how many requests it signed, how many of
/// them each exchange's token served, and every request whose signature did
/// **not** verify against the session key of the exchange that minted its token.
///
/// Verification happens inline, in the worker that signed the request, rather
/// than on a collected array at the end. That is what lets the signing workers
/// run for the whole storm — tens of thousands of requests — instead of stopping
/// at a request ceiling chosen to keep the array small. Stopping early is exactly
/// what made an earlier draft of this test miss a torn cache write: the workers
/// fell silent after the first exchange or two, so the later exchanges landed
/// with no traffic in flight to mispair.
struct SigningReport: Sendable {
  /// How many descriptions of failures are kept. A torn signer mispairs hundreds
  /// of requests, and dumping all of them into an expectation message buries the
  /// rest of the run's output; a handful names the tokens involved just as well.
  static let keptExamples = 4

  /// Total requests signed.
  var signed = 0
  /// Requests signed per security token, i.e. per federation exchange.
  var countsByToken: [String: Int] = [:]
  /// How many requests failed verification.
  var mispairs = 0
  /// Descriptions of the first ``keptExamples`` failures.
  var mispairExamples: [String] = []

  /// Verifies `observation` against `ledger` and folds the result in.
  mutating func record(_ observation: SignedRequestObservation, against ledger: SessionKeyLedger) {
    signed += 1
    countsByToken[observation.token, default: 0] += 1
    guard let sessionPublicKey = ledger.sessionPublicKey(for: observation.token) else {
      note("no exchange ever minted token \(observation.token)")
      return
    }
    if (try? observation.isSigned(withSessionPublicKey: sessionPublicKey)) != true {
      note("token \(observation.token) was signed with a session key from a different exchange")
    }
  }

  /// Folds another worker's report into this one.
  mutating func merge(_ other: SigningReport) {
    signed += other.signed
    countsByToken.merge(other.countsByToken, uniquingKeysWith: +)
    mispairs += other.mispairs
    mispairExamples = Array((mispairExamples + other.mispairExamples).prefix(Self.keptExamples))
  }

  private mutating func note(_ description: String) {
    mispairs += 1
    if mispairExamples.count < Self.keptExamples { mispairExamples.append(description) }
  }
}

// MARK: - Transports and signers

/// Wraps `service`'s transport so the IMDS certificate read parks on `gate`. The
/// read is still *counted* on arrival, so a test can tell that an exchange has
/// reached the gate before it opens it.
func gatedTransport(_ service: FakeMetadataService, gate: ImdsGate) -> HTTPClient {
  let inner = service.transport()
  return HTTPClient { request in
    let result = try await inner.data(request)
    if request.url?.path.hasSuffix("/identity/cert.pem") == true {
      try await gate.waitUntilOpen()
    }
    return result
  }
}

/// Wraps `service`'s transport so each successful federation response carries a
/// token unique to that exchange, recorded in `ledger` against the session public
/// key the request presented. Everything else passes through untouched.
func ledgeredTransport(_ service: FakeMetadataService, ledger: SessionKeyLedger) -> HTTPClient {
  let inner = service.transport()
  return HTTPClient { request in
    let (data, response) = try await inner.data(request)
    guard
      request.url?.path.hasSuffix("/v1/x509") == true,
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode),
      let body = request.httpBody,
      let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let sessionPublicKey = payload["publicKey"] as? String
    else {
      return (data, response)
    }
    let token = ledger.mint(sessionPublicKey: sessionPublicKey)
    return (try JSONSerialization.data(withJSONObject: ["token": token]), response)
  }
}

/// A signer over an arbitrary transport wrapping the fake, with region, realm and
/// federation endpoint pinned — IMDS region discovery is not what these tests are
/// about.
func makeConcurrencySigner(transport: HTTPClient) -> InstancePrincipalSigner {
  InstancePrincipalSigner(
    region: "us-phoenix-1",
    realmDomainComponent: "oraclecloud.com",
    federationEndpoint: URL(string: "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")!,
    metadata: InstanceMetadataURLs(base: fakeMetadataBase)!,
    purpose: nil,
    transport: transport,
    logger: Logger(label: "test")
  )
}

/// A fresh, query-free GET for the signer to sign.
private func serviceRequest() -> URLRequest {
  var request = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
  request.httpMethod = "GET"
  return request
}

/// Signs a fresh service request and records which federation exchange the
/// resulting credentials came from.
private func signAndObserve(_ signer: InstancePrincipalSigner) async throws -> SignedRequestObservation {
  var request = serviceRequest()
  try await signer.sign(&request)
  return try SignedRequestObservation(request: request)
}

// MARK: - Suite

struct InstancePrincipalConcurrencyTests {

  // MARK: A failing exchange must not wedge the counters

  @Test("a failing exchange throws to every joined caller and the signer recovers on the next refresh")
  func failingExchangePropagatesToJoinersAndRecovers() async throws {
    let (service, _) = try makeFakeService()
    service.setFederationResponse(.status(500, body: "boom"))
    let gate = ImdsGate()
    let signer = makeConcurrencySigner(transport: gatedTransport(service, gate: gate))

    // Hold the exchange open until all 30 callers have arrived, so 29 of them
    // provably join it rather than racing a wall-clock window.
    gate.close()
    let arrived = EnteredCounter()
    let opener = Task { await openGate(gate, onceEveryoneArrived: arrived, of: 30) }

    let outcomes = await withTaskGroup(of: ConcurrentRefreshOutcome.self) { group -> [ConcurrentRefreshOutcome] in
      for _ in 0..<30 {
        group.addTask {
          arrived.increment()
          do {
            try await signer.refresh()
            return .succeeded
          }
          catch let error as InstancePrincipalError {
            return .failed(error)
          }
          catch {
            return .failedUnexpectedly(String(describing: error))
          }
        }
      }
      var collected: [ConcurrentRefreshOutcome] = []
      for await outcome in group { collected.append(outcome) }
      return collected
    }
    await opener.value

    // One exchange served all 30, so 29 of these errors came from joining it.
    #expect(service.federationCount == 1)
    #expect(outcomes.count == 30)
    let expected = ConcurrentRefreshOutcome.failed(.federationFailed(status: 500, message: "boom"))
    #expect(outcomes.allSatisfy { $0 == expected }, "outcomes: \(Set(outcomes.map(String.init(describing:))))")

    // The throwing exchange still ran its `defer`, so `completed` caught up with
    // `started`: the next refresh starts a brand-new exchange instead of handing
    // back the dead task's error forever.
    service.setFederationResponse(nil)
    try await signer.refresh()
    #expect(service.federationCount == 2)

    var request = serviceRequest()
    try await signer.sign(&request)
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.contains("keyId=\"ST$\(service.token)\""))
  }

  @Test("a failing forced exchange leaves forceRefresh able to succeed on the next 401")
  func failingForcedExchangeRecovers() async throws {
    let (service, _) = try makeFakeService()
    let gate = ImdsGate()
    let signer = makeConcurrencySigner(transport: gatedTransport(service, gate: gate))
    try await signer.refresh()
    #expect(service.federationCount == 1)

    service.setFederationResponse(.status(503, body: "auth service unavailable"))

    // A rotation rejects 16 in-flight requests at once, and the recovery exchange
    // itself fails. Every caller must see the failure, and the forced-exchange
    // bookkeeping must not be left believing an exchange is still running.
    gate.close()
    let arrived = EnteredCounter()
    let opener = Task { await openGate(gate, onceEveryoneArrived: arrived, of: 16) }

    let outcomes = await withTaskGroup(of: ConcurrentRefreshOutcome.self) { group -> [ConcurrentRefreshOutcome] in
      for _ in 0..<16 {
        group.addTask {
          arrived.increment()
          do {
            try await signer.forceRefresh()
            return .succeeded
          }
          catch let error as InstancePrincipalError {
            return .failed(error)
          }
          catch {
            return .failedUnexpectedly(String(describing: error))
          }
        }
      }
      var collected: [ConcurrentRefreshOutcome] = []
      for await outcome in group { collected.append(outcome) }
      return collected
    }
    await opener.value

    #expect(service.federationCount == 2)  // the whole wave coalesced onto one exchange
    // Asserted before `allSatisfy`, which is vacuously true on an empty result.
    #expect(outcomes.count == 16)
    let expected = ConcurrentRefreshOutcome.failed(.federationFailed(status: 503, message: "auth service unavailable"))
    #expect(outcomes.allSatisfy { $0 == expected }, "outcomes: \(Set(outcomes.map(String.init(describing:))))")

    // The next 401 must be able to recover rather than re-await the dead exchange.
    service.setFederationResponse(nil)
    let rotatedToken = makeToken(offset: 7)
    service.setToken(rotatedToken)
    try await signer.forceRefresh()
    #expect(service.federationCount == 3)

    var request = serviceRequest()
    try await signer.sign(&request)
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.contains("keyId=\"ST$\(rotatedToken)\""))
  }

  // MARK: Cancellation

  @Test("cancelling every caller mid-exchange neither wedges the signer nor starts a second exchange")
  func cancellingCallersLeavesOneExchange() async throws {
    let (service, _) = try makeFakeService()
    let gate = ImdsGate()
    let signer = makeConcurrencySigner(transport: gatedTransport(service, gate: gate))

    gate.close()
    let arrived = EnteredCounter()
    let callers = (0..<5).map { _ in
      Task { [arrived, signer] in
        arrived.increment()
        try await signer.refresh()
      }
    }
    // The exchange is provably in flight — its certificate read has been counted
    // and it is parked on the gate — and every caller has entered `refresh()`.
    await ipWaitUntil { service.certFetchCount >= 1 }
    await ipWaitUntil { arrived.value >= 5 }
    try? await Task.sleep(for: .milliseconds(50))

    for caller in callers { caller.cancel() }
    gate.open()
    for caller in callers { _ = try? await caller.value }

    // The exchange runs in an unstructured task, so it outlived the cancellation
    // of everyone awaiting it: exactly one certificate read and one federation
    // happened, and nothing started a replacement exchange for the "lost" one.
    #expect(service.certFetchCount == 1)
    #expect(service.federationCount == 1)

    // And its result was cached, so the signer is immediately usable.
    var request = serviceRequest()
    try await signer.sign(&request)
    let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
    #expect(authorization.contains("keyId=\"ST$\(service.token)\""))
    #expect(service.certFetchCount == 1)
    #expect(service.federationCount == 1)

    // Not wedged: a later 401 can still force an exchange of its own.
    try await signer.forceRefresh()
    #expect(service.federationCount == 2)
  }

  // MARK: Token/key pairing under an interleaved storm

  @Test("an interleaved sign/refresh/forceRefresh storm never pairs a token with another exchange's session key")
  func tokenAndSessionKeyAlwaysComeFromTheSameExchange() async throws {
    let (service, _) = try makeFakeService()
    let ledger = SessionKeyLedger()
    let signer = makeConcurrencySigner(transport: ledgeredTransport(service, ledger: ledger))
    // A small delay keeps exchanges in flight while other workers are signing, so
    // the storm is genuinely interleaved rather than a sequence of quiet phases.
    // No count is asserted from it — it only affects how much overlap there is.
    service.setCertFetchDelay(millis: 10)

    // The workers are split into two roles on purpose. If every worker refreshed
    // and then signed, they would move in lock-step — each exchange would land
    // while all of them were parked in `refresh()`, and no request would ever be
    // mid-`sign()` at the moment the cache is rewritten, which is exactly the
    // instant a torn token/key pair could be observed. The signers keep requests
    // in flight continuously so every exchange lands during live signing traffic.
    //
    // Most driver rounds ask for a *routine* refresh. `forceRefresh()` stamps
    // `expiry = 0` first, which parks every concurrent `sign()` on the exchange it
    // starts — so a forced exchange is, by construction, one no request can be
    // caught mid-flight against. Routine exchanges leave the cached credentials
    // valid and the signers running, which is what puts traffic on the wire at
    // the instant the cache is rewritten.
    let driverCount = 4
    let driverRounds = 8
    let signerCount = 6
    let driversDone = EnteredCounter()

    let report = try await withThrowingTaskGroup(of: SigningReport.self) { group -> SigningReport in
      for driver in 0..<driverCount {
        group.addTask {
          var report = SigningReport()
          for round in 0..<driverRounds {
            switch (driver + round) % 4 {
            case 0: try await signer.forceRefresh()
            case 3: try await signer.refreshIfNeeded()
            default: try await signer.refresh()
            }
            report.record(try await signAndObserve(signer), against: ledger)
          }
          driversDone.increment()
          return report
        }
      }
      for _ in 0..<signerCount {
        group.addTask {
          var report = SigningReport()
          // Signs for as long as the drivers keep federating — never stopping at
          // a request ceiling that would let the later exchanges land in silence.
          // Bounded twice over, by cancellation and by a ceiling far above any
          // plausible run, so a driver that never finishes fails the test's own
          // expectations instead of spinning forever.
          while driversDone.value < driverCount, !Task.isCancelled, report.signed < 200_000 {
            report.record(try await signAndObserve(signer), against: ledger)
          }
          return report
        }
      }
      var total = SigningReport()
      for try await batch in group { total.merge(batch) }
      return total
    }

    // Guard the premise. A mispaired token/key can only be *observed* if a
    // request was being signed while the cache was being rewritten, so assert
    // that the storm really was interleaved rather than a sequence of quiet
    // phases — otherwise the check below is vacuous and passes on a signer that
    // tears its credentials.
    let minted = ledger.mintedTokens
    #expect(minted.count == service.federationCount)
    #expect(minted.count >= 3, "the storm produced only \(minted.count) exchange(s) to interleave")
    #expect(report.signed >= driverCount * driverRounds + signerCount)
    // Several exchanges must each have served a real share of the traffic. That is
    // the property that makes the check below non-vacuous: it says the signers were
    // still running as the cache turned over, again and again, so a signer that
    // swapped its token and its session key at different moments would have been
    // caught in the act. An earlier draft of this test stopped its signers at a
    // fixed request count; the traffic then piled up entirely on one exchange, and
    // a torn cache write went unnoticed in 6 runs out of 6.
    //
    // Deliberately a floor on how many exchanges saw traffic, not a proportion of
    // them. How the requests split across exchanges is emergent, and one exchange
    // routinely absorbs most of a run, so requiring half of them to be busy fails
    // on a perfectly good storm (observed: [14, 14, 13, 19, 1070, 13, 542, 574, 7]
    // — nine exchanges, all interleaved, but only four above a 15-request bar).
    let busyThreshold = 5
    let busy = minted.filter { (report.countsByToken[$0] ?? 0) >= busyThreshold }
    let perExchange = minted.map { report.countsByToken[$0] ?? 0 }
    #expect(
      busy.count >= 3,
      "the storm was not interleaved: only \(busy.count) exchange(s) served \(busyThreshold)+ requests, \(perExchange)"
    )

    // Every request had to verify against the session key of the exchange that
    // minted the token it presented. A token snapshotted from one exchange and a
    // key from another fails here even though both halves are individually valid.
    #expect(
      report.mispairs == 0,
      "\(report.mispairs) of \(report.signed) signed requests mispaired, e.g. \(report.mispairExamples)"
    )
  }

  // MARK: Repeated forced waves

  @Test("each forceRefresh wave landing on an in-flight routine exchange starts exactly one forced exchange")
  func repeatedForcedWavesEachFederateOnce() async throws {
    let (service, _) = try makeFakeService()
    let gate = ImdsGate()
    let signer = makeConcurrencySigner(transport: gatedTransport(service, gate: gate))
    try await signer.refresh()  // prime

    for wave in 1...3 {
      let federationsBefore = service.federationCount
      let certReadsBefore = service.certFetchCount

      gate.close()
      async let routine: Void = signer.refresh()
      // Proceed only once the routine exchange is provably in flight: its
      // certificate read has been counted and it is parked on the gate.
      await ipWaitUntil { service.certFetchCount > certReadsBefore }

      // A whole wave of 401s lands on top of it. Each must decline the routine
      // exchange — its material predates the rejection — yet still coalesce with
      // its siblings: one forced exchange for the wave, not twelve. The gate opens
      // only once the whole wave has arrived, so none of them can miss it.
      let arrived = EnteredCounter()
      let opener = Task { await openGate(gate, onceEveryoneArrived: arrived, of: 12) }
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
          group.addTask {
            arrived.increment()
            try await signer.forceRefresh()
          }
        }
        try await group.waitForAll()
      }
      await opener.value
      try await routine

      #expect(service.federationCount == federationsBefore + 2, "wave \(wave)")
    }
  }
}
