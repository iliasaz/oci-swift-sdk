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
// Adversarial, credential-free tests for `InstancePrincipalSigner`.
//
// Everything here feeds the signer input a real IMDS or Auth Service could
// plausibly emit when something upstream is broken — a proxy returning an HTML
// error page with HTTP 200, a truncated PEM, a half-populated `regionInfo`
// document, a security token that is not a JWT, an oversized error body — or that
// an attacker with partial control of those responses could induce.
//
// The two invariants most of these pin:
//
//   * **Nothing degenerate is put on the wire.** A certificate the signer cannot
//     decode, or a tenancy it cannot resolve, must fail locally: the fake's
//     `federationCount` stays at 0, so the instance leaf certificate is never
//     POSTed anywhere on the strength of unparseable metadata.
//   * **Nothing degenerate becomes a hostname.** Region/realm values are spliced
//     into `https://auth.<region>.<realm>/v1/x509`, so a 200-with-HTML or an
//     8 KiB body must be refused rather than interpolated.
//
// The fake IMDS + federation endpoint (`FakeMetadataService`) and the PEM/JWT
// builders live in `InstancePrincipalTestSupport.swift`.
//

import Foundation
import Synchronization
import Testing

@testable import OCIKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct InstancePrincipalAdversarialTests {

  /// A request to a service endpoint, for asserting on what `sign(_:)` produced.
  private func serviceRequest() -> URLRequest {
    var req = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
    req.httpMethod = "GET"
    return req
  }

  /// A certificate PEM whose base64 body is wrapped at 64 columns, the way a real
  /// `cert.pem` arrives.
  ///
  /// The wrapping is load-bearing for the two line-ending tests below. The shared
  /// `makeFakeCertPEM` emits the whole body on one line, so any line break in
  /// *that* fixture sits immediately after the `BEGIN` line or before the `END`
  /// line — exactly where `sanitizePEM`'s trailing
  /// `trimmingCharacters(in: .whitespacesAndNewlines)` removes it regardless of
  /// whether the explicit `\r`/`\n` strips did anything. A line-ending test built
  /// on the single-line form therefore passes even with those strips deleted, and
  /// proves nothing. Wrapping puts the line breaks in the *middle* of the base64
  /// body, where only the explicit strips can remove them.
  private func wrappedCertPEM(tenancy: String = fakeTenancy, marker: String) -> String {
    let body = InstancePrincipalSigner.sanitizePEM(makeFakeCertPEM(tenancy: tenancy, marker: marker))
    let lines = stride(from: 0, to: body.count, by: 64).map { start -> String in
      let lower = body.index(body.startIndex, offsetBy: start)
      let upper = body.index(lower, offsetBy: min(64, body.count - start))
      return String(body[lower..<upper])
    }
    return (["-----BEGIN CERTIFICATE-----"] + lines + ["-----END CERTIFICATE-----"]).joined(separator: "\n")
  }

  // MARK: - Degenerate identity material from IMDS

  /// An empty (or whitespace-only) `cert.pem` is the classic half-provisioned
  /// instance. Base64-decoding an empty string *succeeds* — it yields empty DER —
  /// so nothing in the PEM path rejects it; what stops the refresh is that no
  /// tenancy can be derived from an empty certificate and the instance document is
  /// unavailable too. Hence the specific case pinned here is
  /// ``InstancePrincipalError/tenancyNotFound``, which is where the failure
  /// actually lands rather than the `invalidCertificate` one might expect. If an
  /// explicit empty-certificate check is ever added, this expectation moves to
  /// `.invalidCertificate` — deliberately a compile-green/test-red change, so the
  /// diagnostic that reaches the operator stays pinned instead of drifting.
  ///
  /// A weaker `#expect(throws: InstancePrincipalError.self)` would be no test at
  /// all here: with the tenancy guard removed the signer federates and the fake
  /// answers `401 stale certificate`, which is still an `InstancePrincipalError`.
  /// Only the specific case plus `federationCount == 0` catches that.
  @Test("an empty or whitespace-only cert.pem is refused without contacting the Auth Service")
  func emptyCertificateBody() async throws {
    for body in ["", "   \n\t  \n"] {
      let (service, _) = try makeFakeService()
      service.box.withLock { $0.leafCertificateResponse = .body(body) }
      let signer = makeSigner(service: service)

      await #expect(throws: InstancePrincipalError.tenancyNotFound) {
        try await signer.refresh()
      }
      #expect(service.federationCount == 0, "an empty leaf certificate must never be POSTed to /v1/x509")
    }
  }

  /// A PEM truncated mid-base64-quad, and a proxy error page served with HTTP 200,
  /// both fail `Data(base64Encoded:)`. The blame must land on IMDS: the leaf
  /// certificate only ever comes from `/identity/cert.pem`, never from the
  /// federation response.
  @Test("a truncated or HTML cert.pem surfaces invalidCertificate, never a federation error")
  func undecodableCertificateBody() async throws {
    let bodies = [
      "-----BEGIN CERTIFICATE-----\nMIIDazCCAlOgAwIBAgIUA\n",  // truncated mid-quad, no END line
      "<html><body><h1>404 Not Found</h1></body></html>",  // proxy page served as 200
      "-----BEGIN CERTIFICATE-----\n!!!not base64!!!\n-----END CERTIFICATE-----",
    ]
    for body in bodies {
      // A tenancy *is* available from the instance document, so the refresh gets
      // past tenancy resolution and fails where the certificate is fingerprinted —
      // still before any network call.
      let (service, _) = try makeFakeService(tenantIdFallback: fakeTenancy)
      service.box.withLock { $0.leafCertificateResponse = .body(body) }
      let signer = makeSigner(service: service)

      await #expect(throws: InstancePrincipalError.invalidCertificate("the PEM body is not valid base64")) {
        try await signer.refresh()
      }
      #expect(service.federationCount == 0, "an undecodable certificate must not be POSTed to /v1/x509")
    }
  }

  @Test("an unparseable leaf private key fails as invalidPrivateKey before any federation attempt")
  func undecodablePrivateKey() async throws {
    let bodies = [
      "",
      "   \n  ",
      "<html><body><h1>500 Internal Server Error</h1></body></html>",
      "-----BEGIN RSA PRIVATE KEY-----\nnot!base64!\n-----END RSA PRIVATE KEY-----",
      // A well-formed PEM of the wrong kind: a certificate where a key belongs.
      makeFakeCertPEM(tenancy: fakeTenancy, marker: "wrong-pem-type"),
    ]
    for body in bodies {
      let (service, _) = try makeFakeService()
      service.box.withLock { $0.leafPrivateKeyResponse = .body(body) }
      let signer = makeSigner(service: service)

      await #expect(throws: InstancePrincipalError.invalidPrivateKey) {
        try await signer.refresh()
      }
      #expect(service.federationCount == 0, "an unusable leaf key must not be federated with")
    }
  }

  /// IMDS `/identity/cert.pem` is a text endpoint, and a real PEM wraps its base64
  /// body at 64 columns. Trailing blank lines and stray whitespace are plausible
  /// variance, and must sanitize to exactly the same single-line blob as the
  /// canonical form — otherwise the certificate presented to the Auth Service is
  /// not the one that was issued.
  @Test("a multi-line cert.pem with trailing blank lines federates as one canonical blob")
  func wrappedCertificatePEMFederatesCanonically() async throws {
    let canonical = wrappedCertPEM(marker: "wrapped")
    #expect(canonical.split(separator: "\n").count > 3, "the fixture must wrap, or line handling is untested")
    let served = "\n" + canonical + "\n\n  \n"
    let (service, _) = try makeFakeService(leafCertPEM: served)
    let signer = makeSigner(service: service)

    try await signer.refresh()

    #expect(service.federationCount == 1)
    let sent = try #require(service.lastFederationCertificate)
    #expect(!sent.contains("\n"), "line breaks must not survive into the federated certificate")
    #expect(sent == InstancePrincipalSigner.sanitizePEM(canonical))
    // Belt and braces: what is sent must still be the certificate's base64 body,
    // not merely equal to some other mangling of it.
    #expect(Data(base64Encoded: sent) == (try InstancePrincipalSigner.derFromPEM(canonical)))
  }

  /// The same PEM with **CRLF** line endings is a different story, and this test
  /// exists to stop that difference from being papered over.
  ///
  /// `sanitizePEM`/`derFromPEM` strip line breaks with `.replacing("\r", with: "")`
  /// followed by `.replacing("\n", with: "")`. In Swift a CRLF pair is a *single*
  /// extended grapheme cluster, so neither pattern matches it: a `String` holding
  /// `"AAAA\r\nBBBB"` answers `false` to both `contains("\r")` and `contains("\n")`,
  /// and both `replacing` calls leave it untouched (verified on this toolchain).
  /// The carriage returns therefore survive inside the base64 body and
  /// `Data(base64Encoded:)` rejects it.
  ///
  /// A CRLF `cert.pem` consequently does **not** federate — contrary to what one
  /// would want, and contrary to what a test written against the single-line
  /// `makeFakeCertPEM` fixture appears to show (there the CRLFs land only next to
  /// the BEGIN/END lines, where `trimmingCharacters(in: .whitespacesAndNewlines)`
  /// removes them, so the missing strip is invisible).
  ///
  /// What is pinned here is the safety half of that, which is genuinely correct:
  /// the signer **fails closed**. It reports the blame against IMDS
  /// (`invalidCertificate`) and never POSTs a mangled certificate. When the
  /// line-break stripping is fixed — e.g. by normalising `\r\n` to `\n` first, or
  /// by filtering unicode scalars instead of characters — this expectation must
  /// flip to the behaviour asserted in
  /// ``wrappedCertificatePEMFederatesCanonically()``.
  /// This test previously pinned the opposite behaviour. A CRLF-wrapped certificate
  /// used to fail closed with `invalidCertificate`, because the PEM strip was
  /// grapheme-based (`replacing("\r", …)`) and CRLF is a single grapheme cluster,
  /// so neither "\r" nor "\n" ever matched inside it. That is now stripped with
  /// `CharacterClass.newlineSequence`, so a CRLF certificate is handled rather
  /// than rejected — which is what a real IMDS serving CRLF would need.
  @Test("a CRLF-wrapped cert.pem federates identically to the canonical LF form")
  func crlfCertificatePEMIsHandled() async throws {
    let canonical = wrappedCertPEM(marker: "crlf")
    let crlf = canonical.replacing("\n", with: "\r\n") + "\r\n\r\n"
    // Premise, so this test cannot silently become vacuous: the fixture really is
    // multi-line and really does carry CRLF pairs inside the body.
    #expect(crlf.unicodeScalars.contains("\r"))
    #expect(crlf.split(separator: "\r\n").count > 3)
    // Sanitisation now yields the identical single blob for both line endings.
    #expect(!InstancePrincipalSigner.sanitizePEM(crlf).unicodeScalars.contains("\r"))
    #expect(InstancePrincipalSigner.sanitizePEM(crlf) == InstancePrincipalSigner.sanitizePEM(canonical))

    let (service, _) = try makeFakeService(tenantIdFallback: fakeTenancy, leafCertPEM: crlf)
    let signer = makeSigner(service: service)
    try await signer.refresh()

    // It federated, and what went on the wire is the canonical blob — not a
    // mangled one carrying embedded line endings.
    #expect(service.federationCount == 1)
    #expect(service.lastFederationCertificate == InstancePrincipalSigner.sanitizePEM(canonical))
  }

  /// The intermediate certificate is genuinely optional — read with `try?` — so a
  /// broken or absent endpoint must not fail the whole refresh, and must not
  /// forward a placeholder in its place.
  @Test("an intermediate certificate endpoint that errors is tolerated, and forwards nothing")
  func intermediateIsOptional() async throws {
    for response: FakeEndpointResponse in [.status(500, body: "boom"), .notFound, .status(403)] {
      let (service, _) = try makeFakeService(intermediatePEM: makeFakeCertPEM(tenancy: fakeTenancy, marker: "int"))
      service.box.withLock { $0.intermediateResponse = response }
      let signer = makeSigner(service: service)

      try await signer.refresh()

      #expect(service.federationCount == 1)
      #expect(service.intermediateFetchCount == 1)
      #expect(service.lastFederationIntermediates == nil, "a failed optional read must not be forwarded")
    }
  }

  // MARK: - Degenerate tenancy resolution

  /// With a certificate that carries no `opc-tenant:` tag, the tenancy has to come
  /// from the IMDS instance document. An empty string, a number, a JSON null, an
  /// absent key and a non-JSON body must all count as "no tenancy" — never as a
  /// tenancy OCID that then goes into the federation request's `keyId`.
  ///
  /// A **whitespace-only** `tenantId` is deliberately absent from this list: it is
  /// currently accepted as a tenancy and federated with, because the guard is
  /// `!tenancyId.isEmpty` without a trim — unlike the region/realm values, which
  /// are trimmed before their emptiness check. That is reported as a defect rather
  /// than pinned here in either direction.
  @Test("an instance document with an empty, absent, or non-string tenantId yields no tenancy")
  func degenerateTenantIdDocuments() async throws {
    let documents = [
      #"{"tenantId":""}"#,
      #"{"tenantId":12345}"#,
      #"{"tenantId":null}"#,
      "{}",
      "[]",
      "<html><body>not json</body></html>",
      "",
    ]
    for document in documents {
      let (service, _) = try makeFakeService(leafCertPEM: makeCertPEMWithoutTenancy())
      service.box.withLock { $0.instanceDocumentResponse = .body(document) }
      let signer = makeSigner(service: service)

      await #expect(throws: InstancePrincipalError.tenancyNotFound) {
        try await signer.refresh()
      }
      #expect(service.federationCount == 0, "no tenancy means no federation attempt (document: \(document))")
    }
  }

  // MARK: - Degenerate region metadata (it becomes a hostname)

  /// A transparent proxy or a captive portal answering IMDS with an error *page*
  /// and status 200 is the realistic way a non-hostname reaches the region
  /// discovery path. It must be refused, not interpolated into `auth.<region>.…`.
  @Test("IMDS answering 200 with an HTML error page never becomes the federation hostname")
  func htmlErrorPageIsNotAHostname() async throws {
    let page = "<html><body><h1>503 Service Unavailable</h1></body></html>"
    let (service, _) = try makeFakeService()
    service.box.withLock {
      $0.regionInfoResponse = .body(page)  // not JSON → discovery falls through
      $0.regionResponse = .body(page)  // …onto a text endpoint serving the same page
    }

    await #expect(
      throws: InstancePrincipalError.invalidRegionMetadata(field: "region", value: page.lowercased())
    ) {
      try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: service.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
    }
  }

  /// `regionInfo` is treated as all-or-nothing: a document missing either field —
  /// or carrying a null/wrong-typed one — is "incomplete", so discovery falls
  /// through to the older-IMDS `/instance/region` path. The alternative would be a
  /// host with an empty label (`https://auth.us-phoenix-1./v1/x509`).
  @Test("a partial or malformed regionInfo document falls back instead of composing an empty label")
  func partialRegionInfoFallsBack() async throws {
    let documents = [
      #"{"realmDomainComponent":"oraclecloud.com"}"#,  // no regionIdentifier
      #"{"regionIdentifier":"us-phoenix-1"}"#,  // no realmDomainComponent
      #"{"regionIdentifier":"us-phoenix-1","realmDomainComponent":null}"#,
      #"{"regionIdentifier":null,"realmDomainComponent":"oraclecloud.com"}"#,
      #"{"regionIdentifier":12345,"realmDomainComponent":"oraclecloud.com"}"#,
      #"{"regionIdentifier":"us-phoenix-1","realmDomainComponent":["oraclecloud.com"]}"#,
      "{}",
      "[]",
      "",
    ]
    for document in documents {
      let (service, _) = try makeFakeService(shortRegion: "phx")
      service.box.withLock { $0.regionInfoResponse = .body(document) }

      let signer = try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: service.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )

      #expect(service.regionCount == 1, "the older-IMDS fallback must have been taken for \(document)")
      #expect(signer.region == "us-phoenix-1")
      #expect(signer.realmDomainComponent == "oraclecloud.com")
      #expect(signer.federationEndpoint.absoluteString == "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")
      #expect(!signer.federationEndpoint.absoluteString.contains(".."))
    }
  }

  @Test("an enormous region value is refused rather than spliced into the federation host")
  func enormousRegionValue() async throws {
    // 300 characters: over the 253-character whole-component limit, so it cannot
    // be a DNS name however plausible its characters are.
    let longRegion = String(repeating: "a", count: 300)
    let (viaRegionInfo, _) = try makeFakeService()
    viaRegionInfo.box.withLock {
      $0.regionInfoResponse = .body(#"{"regionIdentifier":"\#(longRegion)","realmDomainComponent":"oraclecloud.com"}"#)
    }
    await #expect(
      throws: InstancePrincipalError.invalidRegionMetadata(field: "regionIdentifier", value: longRegion)
    ) {
      try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: viaRegionInfo.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
    }

    // And an 8 KiB body on the older-IMDS text endpoint, which has no structure at
    // all to constrain it.
    let (viaShortRegion, _) = try makeFakeService()
    viaShortRegion.box.withLock {
      $0.regionInfoResponse = .notFound
      $0.regionResponse = .body(String(repeating: "a", count: 8192))
    }
    do {
      _ = try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: viaShortRegion.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
      Issue.record("expected an 8 KiB region value to be refused")
    }
    catch let error as InstancePrincipalError {
      guard case .invalidRegionMetadata(let field, let value) = error else {
        Issue.record("expected invalidRegionMetadata, got \(error)")
        return
      }
      #expect(field == "region")
      #expect(value == String(repeating: "a", count: 8192))
    }
  }

  // MARK: - Degenerate federation responses

  /// The token is read out of the response by hand, so every shape the Auth
  /// Service could return other than a non-empty string must be rejected — not
  /// silently cached as `""` and then signed with.
  @Test("a federation 200 whose token is empty, absent, or not a string is refused as malformed")
  func malformedFederationTokens() async throws {
    let bodies = [
      #"{"token":""}"#,
      #"{"token":12345}"#,
      #"{"token":null}"#,
      #"{"token":{"value":"nested"}}"#,
      #"{"refreshed":true}"#,
      "[]",
      "",
      "<html><body><h1>502 Bad Gateway</h1></body></html>",
    ]
    for body in bodies {
      let (service, _) = try makeFakeService()
      service.setFederationResponse(.body(body))
      let signer = makeSigner(service: service)

      await #expect(throws: InstancePrincipalError.malformedFederationResponse(body)) {
        try await signer.refresh()
      }
      #expect(service.federationCount == 1)
    }
  }

  @Test("an enormous federation error body is surfaced intact rather than truncated or dropped")
  func enormousFederationErrorBody() async throws {
    let body = String(repeating: "x", count: 64 * 1024)
    let (service, _) = try makeFakeService()
    service.setFederationResponse(.status(502, body: body))
    let signer = makeSigner(service: service)

    do {
      try await signer.refresh()
      Issue.record("expected a 502 to surface as federationFailed")
    }
    catch let error as InstancePrincipalError {
      guard case .federationFailed(let status, let message) = error else {
        Issue.record("expected federationFailed, got \(error)")
        return
      }
      #expect(status == 502)
      #expect(message == body, "the error body must be surfaced whole, not truncated")
    }
  }

  /// The single-flight exchange is marked finished from `performRefresh()`'s own
  /// `defer`, so it runs on the failure path too. If it did not, the completed
  /// task would still read as "running" and every later caller would join it and
  /// re-throw the original error forever — one bad federation would take the
  /// signer down for the life of the process.
  @Test("a failed federation exchange does not wedge the single-flight state")
  func failedExchangeDoesNotWedge() async throws {
    let (service, _) = try makeFakeService()
    service.enqueueFederationResponses([.status(503, body: "upstream unavailable")])
    let signer = makeSigner(service: service)

    await #expect(throws: InstancePrincipalError.federationFailed(status: 503, message: "upstream unavailable")) {
      try await signer.refresh()
    }
    #expect(service.federationCount == 1)

    // The queue is exhausted, so this one succeeds — provided the failed exchange
    // released the single-flight slot.
    try await signer.refresh()
    #expect(service.federationCount == 2)

    var req = serviceRequest()
    try await signer.sign(&req)
    #expect(req.value(forHTTPHeaderField: "Authorization")?.contains("keyId=\"ST$") == true)
    #expect(service.federationCount == 2, "the recovered token is cached, not re-federated per sign")
  }

  // MARK: - Degenerate security tokens

  /// The Auth Service returns JWTs today, but a token the SDK cannot parse claims
  /// out of must be *used*, not rejected — it is still a valid bearer credential.
  /// Its staleness is then bounded by the no-`exp` TTL rather than by claims.
  @Test("a security token that is not a readable JWT is accepted and cached, not rejected")
  func nonJWTTokensAreAccepted() async throws {
    let now = Int(Date().timeIntervalSince1970)
    let tokens = [
      "an-opaque-token-with-no-dots",
      "aaa.bbb.ccc",  // JWT-shaped, but the payload segment is not JSON
      "..",  // three empty segments
      ipMakeJWT(claims: ["iat": now, "exp": "\(now + 3600)"]),  // exp encoded as a string
      ipMakeJWT(claims: ["sub": "instance"]),  // a JWT carrying neither iat nor exp
    ]
    for token in tokens {
      // Premise: none of these yields a readable expiry, so the TTL rule governs.
      #expect(TokenClaims.issuedAndExpiry(of: token).expiry == nil, "premise failed for \(token)")

      let (service, _) = try makeFakeService(token: token)
      let signer = makeSigner(service: service)

      for _ in 0..<3 {
        var req = serviceRequest()
        try await signer.sign(&req)
        #expect(req.value(forHTTPHeaderField: "Authorization")?.contains("keyId=\"ST$\(token)\"") == true)
      }
      #expect(service.federationCount == 1, "the token is cached under the TTL, not re-federated per sign")
    }
  }

  /// A token whose `exp` precedes its `iat` is a degenerate validity window: the
  /// midpoint of `[iat, exp]` lies *after* `exp`, so computing a half-life from it
  /// would keep the token in use long past its actual expiry. The policy must fall
  /// back to the fixed jitter before `exp` instead.
  @Test("a token whose exp precedes its iat is treated as stale, not trusted past its expiry")
  func degenerateValidityWindow() async throws {
    let now = Int(Date().timeIntervalSince1970)

    // exp is 30s away; iat claims issuance two hours from now. A naive midpoint
    // would be ~exp + 3585, i.e. an hour of use past expiry.
    let (service, _) = try makeFakeService(
      token: makeToken(issuedAt: now + 7200, expiry: now + 30, marker: "degenerate")
    )
    let signer = makeSigner(service: service)
    try await signer.refresh()
    #expect(service.federationCount == 1)

    try await signer.refreshIfNeeded()
    #expect(service.federationCount == 2, "exp <= iat must fall back to the jitter rule, which is already past")

    // Control, so the assertion above is not simply "refreshIfNeeded always
    // refreshes": a healthy window is left alone.
    let (healthy, _) = try makeFakeService(
      token: makeToken(issuedAt: now, expiry: now + 3600, marker: "healthy")
    )
    let healthySigner = makeSigner(service: healthy)
    try await healthySigner.refresh()
    try await healthySigner.refreshIfNeeded()
    #expect(healthy.federationCount == 1)
  }

  @Test("an enormous opaque token still round-trips intact into the signed Authorization header")
  func enormousToken() async throws {
    let token = String(repeating: "T", count: 64 * 1024)
    let (service, _) = try makeFakeService(token: token)
    let signer = makeSigner(service: service)

    var req = serviceRequest()
    try await signer.sign(&req)

    let auth = try #require(req.value(forHTTPHeaderField: "Authorization"))
    #expect(auth.contains("keyId=\"ST$\(token)\""))
    #expect(service.federationCount == 1)
  }
}
