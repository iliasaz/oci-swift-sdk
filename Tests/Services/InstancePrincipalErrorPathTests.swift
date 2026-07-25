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
// Error-path tests for `InstancePrincipalSigner`, driven end-to-end through the
// in-memory IMDS + Auth Service fake in `InstancePrincipalTestSupport.swift`.
//
// `InstancePrincipalError` is public API, so *which* case a failure reports is
// part of the contract: it is the only thing an operator debugging a live
// instance has to go on, and it is what a caller switches over. Every assertion
// here therefore pins the associated values, not merely that "something threw" —
// a bare `#expect(throws: InstancePrincipalError.self)` passes on the wrong case
// and on the wrong status code.
//
// Cases deliberately not covered here:
//
//   * `invalidRegionMetadata(field:value:)` — covered end-to-end, per component
//     and per hostile character, by `InstancePrincipalHostValidationTests`.
//   * `keyGenerationFailed` — RSA-2048 keygen has no failure mode reachable from
//     the fake; the case exists to translate a `swift-crypto` throw.
//   * `notPrimed` — provably unreachable, see the case's own documentation.
//

import Crypto
import Foundation
import Logging
import Testing

@testable import OCIKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Fixtures local to the error paths

/// A second tenancy OCID, distinct from ``fakeTenancy``, for driving a rotation
/// whose new leaf certificate belongs to a different tenancy. Not a real OCID.
private let rotatedTenancy = "ocid1.tenancy.oc1..aaaaaaaaexamplerotatedtenancy"

/// A URL string neither Foundation nor swift-corelibs-foundation can parse (an
/// unterminated IPv6 literal), so `URL(string:)` returns nil on every platform.
private let unparseableURL = "http://[::1"

/// Raised by an injected transport to simulate the federation POST failing below
/// the HTTP layer (connection refused, DNS failure, TLS error).
private struct FederationTransportFailure: Error {}

/// Wraps `service`'s transport, substituting `federation` for the `/v1/x509`
/// POST. IMDS keeps behaving normally, so the refresh reaches federation with
/// real certificate material and only the federation leg misbehaves.
private func transportOverridingFederation(
  _ service: FakeMetadataService,
  with federation: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
) -> HTTPClient {
  let imds = service.transport()
  return HTTPClient { request in
    if request.url?.path.hasSuffix("/v1/x509") == true {
      return try await federation(request)
    }
    return try await imds.data(request)
  }
}

/// Holds one IMDS certificate read open until the test releases it, and counts
/// the joiners the test has dispatched.
///
/// This is what keeps the concurrent-joiner test free of wall-clock assumptions.
/// Parking the first exchange on its certificate read means the "exchange is in
/// flight" window is bounded by *the test*, not by how quickly a loaded CI runner
/// gets around to scheduling twenty tasks — the exchange provably cannot finish
/// while the gate is shut, however long the joiners take to arrive.
private actor ExchangeGate {
  private var isOpen = false
  private var parked: [CheckedContinuation<Void, Never>] = []
  /// Requests that have reached the gated endpoint.
  private(set) var arrivals = 0
  /// Joiners the test has dispatched and that are about to call `refresh()`.
  private(set) var dispatchedJoiners = 0

  /// Called by the gated transport: records the arrival, then parks until ``open()``.
  func arrive() async {
    arrivals += 1
    if isOpen { return }
    await withCheckedContinuation { parked.append($0) }
  }

  func noteJoinerDispatched() { dispatchedJoiners += 1 }

  /// Releases everything parked and lets subsequent reads straight through.
  func open() {
    isOpen = true
    let waiting = parked
    parked.removeAll()
    for continuation in waiting { continuation.resume() }
  }
}

/// Wraps `service`'s transport so the IMDS `cert.pem` read parks on `gate`.
/// Every other endpoint behaves normally.
private func transportGatingCertificateFetch(
  _ service: FakeMetadataService,
  on gate: ExchangeGate
) -> HTTPClient {
  let imds = service.transport()
  return HTTPClient { request in
    if request.url?.path.hasSuffix("/identity/cert.pem") == true {
      await gate.arrive()
    }
    return try await imds.data(request)
  }
}

/// Builds a signer against an arbitrary transport, with the region/realm and the
/// federation endpoint pinned (so no IMDS discovery runs first).
private func makeSignerOverTransport(_ transport: HTTPClient) -> InstancePrincipalSigner {
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

/// Runs `refresh()` and returns the ``InstancePrincipalError`` it threw, or `nil`
/// when it succeeded. Used to collect the outcome of concurrent joiners without
/// tearing down the surrounding task group on the first failure.
private func refreshError(of signer: InstancePrincipalSigner) async -> InstancePrincipalError? {
  do {
    try await signer.refresh()
    return nil
  }
  catch let error as InstancePrincipalError {
    return error
  }
  catch {
    Issue.record("refresh() threw an unexpected error type: \(error)")
    return nil
  }
}

// MARK: - Suite

struct InstancePrincipalErrorPathTests {

  // MARK: metadataUnavailable

  @Test("a cert.pem that 404s reports metadataUnavailable naming the IMDS certificate path")
  func certificateEndpointUnavailable() async throws {
    let (service, _) = try makeFakeService()
    service.box.withLock { $0.leafCertificateResponse = .notFound }
    let signer = makeSigner(service: service)

    let error = await #expect(throws: InstancePrincipalError.self) {
      try await signer.refresh()
    }
    #expect(error == .metadataUnavailable("/opc/v2/identity/cert.pem"))
    // Nothing was presented to the Auth Service: the refresh never got that far.
    #expect(service.federationCount == 0)
    // The message steers the operator at the real cause — not being on an instance.
    #expect(error?.errorDescription?.contains("OCI compute instance") == true)
  }

  @Test("a key.pem that 500s reports metadataUnavailable naming the IMDS key path")
  func privateKeyEndpointUnavailable() async throws {
    let (service, _) = try makeFakeService()
    service.box.withLock { $0.leafPrivateKeyResponse = .status(500, body: "internal error") }
    let signer = makeSigner(service: service)

    let error = await #expect(throws: InstancePrincipalError.self) {
      try await signer.refresh()
    }
    // The path in the error is the *key* endpoint, so a 500 there is not
    // misreported against the certificate that was read successfully first.
    #expect(error == .metadataUnavailable("/opc/v2/identity/key.pem"))
    #expect(service.certFetchCount == 1)
    #expect(service.keyFetchCount == 1)
    #expect(service.federationCount == 0)
  }

  @Test("region discovery with both IMDS region endpoints absent reports metadataUnavailable")
  func regionDiscoveryFindsNoEndpoint() async throws {
    let (service, _) = try makeFakeService(
      regionInfoRegion: nil,  // regionInfo 404s
      regionInfoRealm: nil,
      shortRegion: nil  // …and so does the older /instance/region
    )

    let error = await #expect(throws: InstancePrincipalError.self) {
      _ = try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: service.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
    }
    #expect(error == .metadataUnavailable("/opc/v2/instance/region"))
    // Both endpoints were tried: regionInfo first, then the older-IMDS fallback.
    #expect(service.regionInfoCount == 1)
    #expect(service.regionCount == 1)
  }

  @Test("an OCI_METADATA_BASE_URL that cannot be parsed is refused before any IMDS request")
  func unparseableMetadataBaseURL() async throws {
    let (service, _) = try makeFakeService()

    let error = await #expect(throws: InstancePrincipalError.self) {
      _ = try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: service.transport(),
        environment: ["OCI_METADATA_BASE_URL": unparseableURL]
      )
    }
    #expect(error == .metadataUnavailable("invalid OCI_METADATA_BASE_URL"))
    // Refused up front rather than after a round of timeouts against a bad host.
    #expect(service.requests.isEmpty)
  }

  // MARK: regionUnavailable

  @Test("a /instance/region that answers 200 with a blank body reports regionUnavailable")
  func blankRegionReportsRegionUnavailable() async throws {
    let (service, _) = try makeFakeService(regionInfoRegion: nil, regionInfoRealm: nil)
    // A 200 with nothing usable in it: reachable IMDS, unusable answer. That is
    // `regionUnavailable`, distinctly *not* `metadataUnavailable`.
    service.box.withLock { $0.regionResponse = .body("   \n") }

    let error = await #expect(throws: InstancePrincipalError.self) {
      _ = try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: service.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
    }
    #expect(error == .regionUnavailable)
    #expect(service.regionCount == 1)
  }

  // MARK: invalidFederationEndpoint

  @Test("a federation endpoint override that cannot be parsed reports invalidFederationEndpoint")
  func unparseableEndpointOverride() async throws {
    let (service, _) = try makeFakeService()

    let error = await #expect(throws: InstancePrincipalError.self) {
      _ = try await InstancePrincipalSigner.make(
        federationEndpointOverride: unparseableURL,
        purpose: nil,
        transport: service.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
    }
    #expect(error == .invalidFederationEndpoint(unparseableURL))
    #expect(error?.errorDescription?.contains(unparseableURL) == true)
  }

  // MARK: invalidPrivateKey

  @Test("a key.pem that is not a parseable RSA PEM reports invalidPrivateKey")
  func unparseablePrivateKey() async throws {
    let ecKeyPEM = P256.Signing.PrivateKey().pemRepresentation
    let bodies: [(String, String)] = [
      ("plain text", "this is not a key"),
      ("PEM envelope with a non-base64 body", "-----BEGIN RSA PRIVATE KEY-----\nnot!base64!\n-----END RSA PRIVATE KEY-----"),
      ("a well-formed PEM holding an EC key", ecKeyPEM),
      ("an empty body", ""),
    ]

    for (label, body) in bodies {
      let (service, _) = try makeFakeService()
      service.setLeafPrivateKey(body)
      let signer = makeSigner(service: service)

      let error = await #expect(throws: InstancePrincipalError.self) {
        try await signer.refresh()
      }
      #expect(error == .invalidPrivateKey, "\(label)")
      // The key is parsed before the federation request is signed, so nothing is
      // sent to the Auth Service.
      #expect(service.federationCount == 0, "\(label)")
    }
  }

  // MARK: invalidCertificate

  @Test("a cert.pem body that is not valid base64 reports invalidCertificate, not a federation error")
  func unparseableCertificate() async throws {
    // Tenancy resolution falls back to the IMDS instance document (the malformed
    // PEM yields no tagged value), so the refresh gets as far as fingerprinting
    // the certificate — which is where the bad base64 is caught.
    let (service, _) = try makeFakeService(
      tenantIdFallback: fakeTenancy,
      leafCertPEM: "-----BEGIN CERTIFICATE-----\nnot!valid!base64!\n-----END CERTIFICATE-----"
    )
    let signer = makeSigner(service: service)

    let error = await #expect(throws: InstancePrincipalError.self) {
      try await signer.refresh()
    }
    #expect(error == .invalidCertificate("the PEM body is not valid base64"))
    #expect(service.instanceDocumentCount == 1)
    #expect(service.federationCount == 0)
    // The regression this pins: the certificate comes from IMDS, so the failure
    // must not be reported as a federation-response decode problem.
    let message = try #require(error?.errorDescription).lowercased()
    #expect(message.contains("imds"))
    #expect(!message.contains("federation"))
  }

  // MARK: tenancyNotFound

  @Test("a certificate with no tenancy tag and no IMDS instance document reports tenancyNotFound")
  func tenancyNotFound() async throws {
    let (service, _) = try makeFakeService(leafCertPEM: makeCertPEMWithoutTenancy())
    let signer = makeSigner(service: service)

    let error = await #expect(throws: InstancePrincipalError.self) {
      try await signer.refresh()
    }
    #expect(error == .tenancyNotFound)
    // The fallback was genuinely attempted before giving up.
    #expect(service.instanceDocumentCount == 1)
    #expect(service.federationCount == 0)
  }

  @Test("an /instance/ document whose tenantId is empty also reports tenancyNotFound")
  func emptyTenantIdReportsTenancyNotFound() async throws {
    let (service, _) = try makeFakeService(leafCertPEM: makeCertPEMWithoutTenancy())
    // A present-but-empty tenantId must not be adopted as the tenancy: it would
    // produce a keyId of "/fed-x509/<fingerprint>".
    service.box.withLock { $0.instanceDocumentResponse = .body(#"{"tenantId": ""}"#) }
    let signer = makeSigner(service: service)

    let error = await #expect(throws: InstancePrincipalError.self) {
      try await signer.refresh()
    }
    #expect(error == .tenancyNotFound)
    #expect(service.federationCount == 0)
  }

  // MARK: tenancyChanged — the #98 consistency check

  @Test("a rotation whose new certificate carries a different tenancy reports tenancyChanged with both OCIDs")
  func rotationChangingTenancyIsRefused() async throws {
    let (service, _) = try makeFakeService(certMarker: "v1", tenancy: fakeTenancy)
    let signer = makeSigner(service: service)

    // Prime. The first exchange has no previous tenancy to compare against, so it
    // must succeed and record `fakeTenancy`.
    try await signer.refresh()
    #expect(service.federationCount == 1)

    // The instance leaf certificate is replaced with one issued to a *different*
    // tenancy: a mis-provisioned rotation, or an IMDS answering for someone else.
    service.rotate(
      certPEM: makeFakeCertPEM(tenancy: rotatedTenancy, marker: "v2"),
      token: makeToken(offset: 1)
    )

    let error = await #expect(throws: InstancePrincipalError.self) {
      try await signer.forceRefresh()
    }
    #expect(error == .tenancyChanged(previous: fakeTenancy, updated: rotatedTenancy))
    // The rotated certificate really was re-read from IMDS…
    #expect(service.certFetchCount == 2)
    // …and never presented to the Auth Service: the check fires before federating,
    // so a certificate for a foreign tenancy is not exchanged for a token.
    #expect(service.federationCount == 1)

    // Both OCIDs reach the operator, so the rotation can be traced to a tenancy.
    let message = try #require(error?.errorDescription)
    #expect(message.contains(fakeTenancy))
    #expect(message.contains(rotatedTenancy))
  }

  @Test("the tenancy consistency check does not fire when a rotation keeps the tenancy")
  func rotationKeepingTenancyIsAccepted() async throws {
    let (service, _) = try makeFakeService(certMarker: "v1")
    let signer = makeSigner(service: service)
    try await signer.refresh()

    // The everyday case: OCI rotates the leaf certificate, tenancy unchanged. A
    // check keyed on the certificate rather than the tenancy would break here —
    // and would break it only in production, hours into a process's life.
    let rotated = makeFakeCertPEM(tenancy: fakeTenancy, marker: "v2")
    service.rotate(certPEM: rotated, token: makeToken(offset: 2))
    try await signer.forceRefresh()

    #expect(service.federationCount == 2)
    #expect(service.lastFederationCertificate == InstancePrincipalSigner.sanitizePEM(rotated))
  }

  @Test("a tenancy change visible only through the IMDS instance document is caught too")
  func tenancyChangeViaInstanceDocument() async throws {
    // Neither certificate carries a tenancy tag, so both exchanges resolve the
    // tenancy through the `/instance/` document — the check must compare the
    // *resolved* tenancy, not just the one parsed out of the certificate.
    let (service, _) = try makeFakeService(
      tenantIdFallback: fakeTenancy,
      leafCertPEM: makeCertPEMWithoutTenancy(marker: "v1")
    )
    let signer = makeSigner(service: service)
    try await signer.refresh()
    #expect(service.federationCount == 1)

    service.setLeafCertificate(makeCertPEMWithoutTenancy(marker: "v2"))
    service.box.withLock { $0.instanceDocumentResponse = .body(#"{"tenantId": "\#(rotatedTenancy)"}"#) }

    let error = await #expect(throws: InstancePrincipalError.self) {
      try await signer.forceRefresh()
    }
    #expect(error == .tenancyChanged(previous: fakeTenancy, updated: rotatedTenancy))
    #expect(service.federationCount == 1)
  }

  // MARK: federationFailed

  @Test("a non-2xx federation response reports federationFailed carrying the status and the body")
  func federationRejected() async throws {
    let rejections: [(status: Int, body: String)] = [
      (400, #"{"code":"InvalidParameter","message":"certificate is malformed"}"#),
      (401, #"{"code":"NotAuthenticated","message":"the required information to complete authentication was not provided"}"#),
      (403, #"{"code":"NotAuthorizedOrNotFound"}"#),
      (429, #"{"code":"TooManyRequests"}"#),
      (500, "internal server error"),
      (503, ""),
    ]

    for rejection in rejections {
      let (service, _) = try makeFakeService()
      service.setFederationResponse(.status(rejection.status, body: rejection.body))
      let signer = makeSigner(service: service)

      let error = await #expect(throws: InstancePrincipalError.self) {
        try await signer.refresh()
      }
      #expect(error == .federationFailed(status: rejection.status, message: rejection.body), "HTTP \(rejection.status)")
      #expect(service.federationCount == 1, "HTTP \(rejection.status)")

      // The status and the service's own explanation both survive into the
      // message: without the body, a 403 here is indistinguishable from a missing
      // dynamic-group policy, which is the single most common cause.
      let message = try #require(error?.errorDescription)
      #expect(message.contains("HTTP \(rejection.status)"), "HTTP \(rejection.status)")
      if !rejection.body.isEmpty {
        #expect(message.contains(rejection.body), "HTTP \(rejection.status)")
      }
    }
  }

  @Test("a transport failure during federation reports federationFailed with status -1")
  func federationTransportFailure() async throws {
    let (service, _) = try makeFakeService()
    let signer = makeSignerOverTransport(
      transportOverridingFederation(service) { _ in throw FederationTransportFailure() }
    )

    let error = await #expect(throws: InstancePrincipalError.self) {
      try await signer.refresh()
    }
    guard case .federationFailed(let status, let message) = try #require(error) else {
      Issue.record("expected federationFailed, got \(String(describing: error))")
      return
    }
    // -1 marks "never got an HTTP status back", distinct from any real status.
    #expect(status == -1)
    #expect(message.contains("FederationTransportFailure"))
  }

  @Test("a federation reply that is not an HTTP response reports federationFailed")
  func federationNonHTTPResponse() async throws {
    let (service, _) = try makeFakeService()
    let signer = makeSignerOverTransport(
      transportOverridingFederation(service) { request in
        let url = request.url ?? URL(string: "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")!
        return (Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
      }
    )

    let error = await #expect(throws: InstancePrincipalError.self) {
      try await signer.refresh()
    }
    #expect(error == .federationFailed(status: -1, message: "Non-HTTP response"))
  }

  @Test("fromMetadata fails fast when the very first federation exchange is rejected")
  func fromMetadataFailsFast() async throws {
    let (service, _) = try makeFakeService()
    service.setFederationResponse(.status(403, body: #"{"code":"NotAuthorizedOrNotFound"}"#))

    // The point of the eager exchange: a misconfigured instance fails at
    // construction, not at the first service call somewhere else in the program.
    let error = await #expect(throws: InstancePrincipalError.self) {
      _ = try await InstancePrincipalSigner.fromMetadata(
        transport: service.transport(),
        logger: Logger(label: "test"),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
    }
    #expect(error == .federationFailed(status: 403, message: #"{"code":"NotAuthorizedOrNotFound"}"#))
    #expect(service.federationCount == 1)
  }

  // MARK: malformedFederationResponse

  @Test("a 2xx federation body with no usable token reports malformedFederationResponse carrying the body")
  func malformedFederationResponses() async throws {
    let bodies: [(String, String)] = [
      ("not JSON at all", "<<not-a-document>>"),
      ("JSON, but not an object", "[]"),
      ("an object with no token", #"{"expiresIn": 3600}"#),
      ("a token that is present but empty", #"{"token": ""}"#),
      ("a token that is not a string", #"{"token": 12345}"#),
      ("an empty body", ""),
    ]

    for (label, body) in bodies {
      let (service, _) = try makeFakeService()
      service.setFederationResponse(.body(body))
      let signer = makeSigner(service: service)

      let error = await #expect(throws: InstancePrincipalError.self) {
        try await signer.refresh()
      }
      // A 2xx that carries no token is a *response* problem, never reported as a
      // certificate or metadata failure — and the body is quoted verbatim, since
      // it is the only evidence of what the Auth Service actually said.
      #expect(error == .malformedFederationResponse(body), "\(label)")
      #expect(service.federationCount == 1, "\(label)")
      if !body.isEmpty {
        #expect(error?.errorDescription?.contains(body) == true, "\(label)")
      }
    }
  }

  // MARK: A failure must not wedge the signer

  @Test("a failed exchange releases the single-flight gate, so the next refresh recovers")
  func failedExchangeDoesNotWedgeTheSigner() async throws {
    let (service, _) = try makeFakeService()
    service.enqueueFederationResponses([.status(500, body: "boom")])
    let signer = makeSigner(service: service)

    let error = await #expect(throws: InstancePrincipalError.self) {
      try await signer.refresh()
    }
    #expect(error == .federationFailed(status: 500, message: "boom"))

    // The exchange is finished on the failure path too, so a retry can start a new
    // one rather than joining a dead task or spinning.
    try await signer.refresh()
    #expect(service.federationCount == 2)

    var req = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
    req.httpMethod = "GET"
    try await signer.sign(&req)
    #expect(req.value(forHTTPHeaderField: "Authorization")?.contains("ST$\(service.token)") == true)
    // The recovered token is cached: signing did not federate a third time.
    #expect(service.federationCount == 2)
  }

  @Test("every joiner of a failing exchange observes the same failure, and the signer still recovers")
  func concurrentJoinersObserveTheFailure() async throws {
    let (service, _) = try makeFakeService()
    service.setFederationResponse(.status(503, body: "service unavailable"))
    let gate = ExchangeGate()
    let signer = makeSignerOverTransport(transportGatingCertificateFetch(service, on: gate))

    let errors = await withTaskGroup(of: InstancePrincipalError?.self) { group -> [InstancePrincipalError?] in
      group.addTask { await refreshError(of: signer) }
      // Only dispatch the joiners once that exchange is provably in flight: it is
      // parked on the gated certificate read and cannot finish until `open()`.
      while await gate.arrivals < 1 {
        await Task.yield()
      }
      for _ in 0..<19 {
        group.addTask {
          await gate.noteJoinerDispatched()
          return await refreshError(of: signer)
        }
      }
      // …and only release it once all nineteen have actually started running.
      // No sleep is involved: the exchange stays parked for as long as this takes,
      // so a slow runner makes the test slower, never flakier.
      while await gate.dispatchedJoiners < 19 {
        await Task.yield()
      }
      await gate.open()
      var collected: [InstancePrincipalError?] = []
      for await error in group {
        collected.append(error)
      }
      return collected
    }

    #expect(errors.count == 20)
    // The failure is propagated to every joiner rather than swallowed by the
    // coalescing — a joiner that saw `nil` would go on to sign with no token.
    #expect(errors.allSatisfy { $0 == .federationFailed(status: 503, message: "service unavailable") })
    #expect(service.federationCount == 1)

    // And the signer is not poisoned by the failed exchange.
    service.setFederationResponse(nil)
    try await signer.refresh()
    #expect(service.federationCount == 2)
  }
}
