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
// Hermetic (credential-free, offline) tests for `InstancePrincipalSigner`.
//
// These exercise the signer against an in-memory fake of the Instance Metadata
// Service (IMDS) + the Auth Service federation endpoint, injected as an
// `HTTPClient`. They reproduce the three filed bugs:
//
//   * #98 — the leaf certificate/key are re-read from IMDS on every refresh, so
//     the signer rides through a certificate rotation instead of caching the
//     original cert for the process lifetime.
//   * #99 — the actor's single-flight refresh coalesces concurrent callers onto
//     one federation exchange (no data race, no duplicate exchange).
//   * #100 — the region is exposed publicly and the federation host is derived
//     from the realm (`regionInfo.realmDomainComponent`), so non-commercial
//     realms work.
//
// The in-memory fake itself (`FakeMetadataService`) and the PEM/JWT builders live
// in `InstancePrincipalTestSupport.swift`, shared with the other suites that drive
// the same signer.
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

// MARK: - Pure helpers

struct InstancePrincipalHelperTests {
  @Test("sanitizePEM strips header/footer lines and newlines into one line")
  func sanitizePEM() {
    let pem = makeFakeCertPEM(tenancy: fakeTenancy, marker: "x")
    let sanitized = InstancePrincipalSigner.sanitizePEM(pem)
    #expect(!sanitized.contains("CERTIFICATE"))
    #expect(!sanitized.contains("-----"))
    #expect(!sanitized.contains("\n"))
    #expect(Data(base64Encoded: sanitized) != nil)
  }

  @Test("certificateFingerprintSHA1Hex is uppercase colon-separated hex over the DER")
  func fingerprint() throws {
    let pem = makeFakeCertPEM(tenancy: fakeTenancy, marker: "x")
    let fingerprint = try InstancePrincipalSigner.certificateFingerprintSHA1Hex(pem: pem)
    let segments = fingerprint.split(separator: ":")
    #expect(segments.count == 20)  // SHA-1 is 20 bytes
    for segment in segments {
      #expect(segment.count == 2)
      #expect(segment.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isUppercase) })
    }
  }

  @Test("tenancyId(fromCertificatePEM:) extracts the opc-tenant OCID")
  func tenancyExtraction() throws {
    let pem = makeFakeCertPEM(tenancy: fakeTenancy, marker: "x")
    #expect(try InstancePrincipalSigner.tenancyId(fromCertificatePEM: pem) == fakeTenancy)
  }

  @Test("issuedAndExpiry reads iat and exp; malformed tokens yield nils")
  func tokenClaims() {
    let token = ipMakeJWT(claims: ["iat": 1000, "exp": 5000])
    let claims = TokenClaims.issuedAndExpiry(of: token)
    #expect(claims.issuedAt == 1000)
    #expect(claims.expiry == 5000)

    let bad = TokenClaims.issuedAndExpiry(of: "not-a-jwt")
    #expect(bad.issuedAt == nil)
    #expect(bad.expiry == nil)
  }

  @Test("InstanceMetadataURLs composes the IMDS endpoints and tolerates a trailing slash")
  func metadataURLs() throws {
    let urls = try #require(InstanceMetadataURLs(base: "http://169.254.169.254/opc/v2/"))
    #expect(urls.region.absoluteString == "http://169.254.169.254/opc/v2/instance/region")
    #expect(urls.regionInfo.absoluteString == "http://169.254.169.254/opc/v2/instance/regionInfo")
    #expect(urls.leafCertificate.absoluteString == "http://169.254.169.254/opc/v2/identity/cert.pem")
    #expect(urls.leafPrivateKey.absoluteString == "http://169.254.169.254/opc/v2/identity/key.pem")
    #expect(urls.intermediateCertificate.absoluteString == "http://169.254.169.254/opc/v2/identity/intermediate.pem")
  }

  @Test("metadataBaseURL honors OCI_METADATA_BASE_URL, else the IPv4 default")
  func baseURL() {
    #expect(InstancePrincipalSigner.metadataBaseURL([:]) == "http://169.254.169.254/opc/v2")
    #expect(
      InstancePrincipalSigner.metadataBaseURL(["OCI_METADATA_BASE_URL": "http://custom/opc/v2"])
        == "http://custom/opc/v2"
    )
    // Whitespace-only is treated as unset.
    #expect(InstancePrincipalSigner.metadataBaseURL(["OCI_METADATA_BASE_URL": "  "]) == "http://169.254.169.254/opc/v2")
  }

  @Test("buildFederationRequest posts the certificate/publicKey and a fed-x509 keyId")
  func federationRequest() throws {
    let certPEM = makeFakeCertPEM(tenancy: fakeTenancy, marker: "x")
    let leafKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
    let sessionKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
    let req = try InstancePrincipalSigner.buildFederationRequest(
      endpoint: URL(string: "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")!,
      leafCertificatePEM: certPEM,
      intermediateCertificatePEM: nil,
      sessionKey: sessionKey,
      leafPrivateKey: leafKey,
      tenancyId: fakeTenancy,
      purpose: nil
    )
    #expect(req.httpMethod == "POST")
    let body = try #require(req.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["certificate"] as? String == InstancePrincipalSigner.sanitizePEM(certPEM))
    #expect(json["publicKey"] != nil)
    let fingerprint = try InstancePrincipalSigner.certificateFingerprintSHA1Hex(pem: certPEM)
    let auth = try #require(req.value(forHTTPHeaderField: "Authorization"))
    #expect(auth.contains("keyId=\"\(fakeTenancy)/fed-x509/\(fingerprint)\""))
  }
}

// MARK: - Region + realm (#100)

struct InstancePrincipalRegionRealmTests {
  @Test("region is exposed and the federation host is derived from the realm (non-commercial)")
  func nonCommercialRealm() async throws {
    let (service, _) = try makeFakeService(
      regionInfoRegion: "us-luke-1",
      regionInfoRealm: "oraclegovcloud.com"
    )
    let signer = try await InstancePrincipalSigner.make(
      federationEndpointOverride: nil,
      purpose: nil,
      transport: service.transport(),
      environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
    )
    #expect(signer.region == "us-luke-1")
    #expect(signer.realmDomainComponent == "oraclegovcloud.com")
    #expect(signer.federationEndpoint.absoluteString == "https://auth.us-luke-1.oraclegovcloud.com/v1/x509")
  }

  @Test("commercial realm derives the oraclecloud.com federation host")
  func commercialRealm() async throws {
    let (service, _) = try makeFakeService(regionInfoRegion: "us-ashburn-1", regionInfoRealm: "oraclecloud.com")
    let signer = try await InstancePrincipalSigner.make(
      federationEndpointOverride: nil,
      purpose: nil,
      transport: service.transport(),
      environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
    )
    #expect(signer.region == "us-ashburn-1")
    #expect(signer.federationEndpoint.absoluteString == "https://auth.us-ashburn-1.oraclecloud.com/v1/x509")
  }

  @Test("falls back to /instance/region + commercial realm when regionInfo is unavailable")
  func regionInfoFallback() async throws {
    let (service, _) = try makeFakeService(
      regionInfoRegion: nil,  // regionInfo returns 404
      regionInfoRealm: nil,
      shortRegion: "phx"
    )
    let signer = try await InstancePrincipalSigner.make(
      federationEndpointOverride: nil,
      purpose: nil,
      transport: service.transport(),
      environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
    )
    #expect(signer.region == "us-phoenix-1")  // short "phx" mapped to long form
    #expect(signer.realmDomainComponent == "oraclecloud.com")
    #expect(signer.federationEndpoint.absoluteString == "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")
  }

  @Test("an explicit federation endpoint override is honored")
  func endpointOverride() async throws {
    let (service, _) = try makeFakeService()
    let signer = try await InstancePrincipalSigner.make(
      federationEndpointOverride: "https://auth.custom.example.com/v1/x509",
      purpose: nil,
      transport: service.transport(),
      environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
    )
    #expect(signer.federationEndpoint.absoluteString == "https://auth.custom.example.com/v1/x509")
  }
}

// MARK: - Federation host validation (IMDS-supplied region/realm)

/// The region + realm read from IMDS are spliced into
/// `https://auth.<region>.<realm>/v1/x509`, and the request sent there carries the
/// instance leaf certificate signed with the leaf private key. These tests pin the
/// DNS-label validation that keeps a hostile IMDS value from re-pointing that host.
struct InstancePrincipalHostValidationTests {
  /// Guards the premise the validation exists for: `URL` really does read the part
  /// after `@` as the host, on macOS Foundation and swift-corelibs-foundation alike.
  @Test("Foundation parses an @ in the composed endpoint as a userinfo/host split")
  func urlUserInfoSplitIsReal() throws {
    let url = try #require(URL(string: "https://auth.us-phoenix-1.oraclecloud.com@evil.com/v1/x509"))
    #expect(url.host == "evil.com")
    #expect(url.user == "auth.us-phoenix-1.oraclecloud.com")
    // `/`, `#` and `?` truncate the host the same way.
    #expect(URL(string: "https://auth.us-phoenix-1.oraclecloud.com/x/.evil.com/v1/x509")?.host == "auth.us-phoenix-1.oraclecloud.com")
    #expect(URL(string: "https://auth.evil.com#.oraclecloud.com/v1/x509")?.host == "auth.evil.com")
    #expect(URL(string: "https://auth.evil.com?.oraclecloud.com/v1/x509")?.host == "auth.evil.com")
  }

  @Test("isValidHostComponent accepts DNS label sequences and rejects URL-significant characters")
  func hostComponentRule() {
    let accepted = [
      "oraclecloud.com",
      "oraclegovcloud.com",
      "oraclecloud.eu",
      "us-phoenix-1",
      "eu-frankfurt-1",
      "a",
      "1",
      String(repeating: "a", count: 63),
    ]
    for value in accepted {
      #expect(InstancePrincipalSigner.isValidHostComponent(value), "expected \(value) to be accepted")
    }

    let rejected = [
      "",  // empty
      "oraclecloud.com@evil.com",  // userinfo split
      "oraclecloud.com/x",  // path split
      "oraclecloud.com:8443",  // port
      "oraclecloud.com#x",  // fragment
      "oraclecloud.com?x",  // query
      "oraclecloud.com\\evil.com",  // backslash
      "oracle cloud.com",  // space
      "oraclecloud.com\n",  // control character
      "ORACLECLOUD.COM",  // not lower-cased by the caller
      "oracle_cloud.com",  // underscore is not a host label character
      "оraclecloud.com",  // Cyrillic homoglyph
      ".oraclecloud.com",  // leading dot
      "oraclecloud.com.",  // trailing dot
      "oraclecloud..com",  // consecutive dots
      ".",  // dot only
      "-phoenix-1",  // label starts with a hyphen
      "us-phoenix-",  // label ends with a hyphen
      String(repeating: "a", count: 64),  // label too long
    ]
    for value in rejected {
      #expect(!InstancePrincipalSigner.isValidHostComponent(value), "expected \(value) to be rejected")
    }
  }

  @Test("a realmDomainComponent carrying an @ is refused instead of re-pointing the federation host")
  func hostileRealmUserInfo() async throws {
    let (service, _) = try makeFakeService(
      regionInfoRegion: "us-phoenix-1",
      regionInfoRealm: "oraclecloud.com@evil.com"
    )
    await #expect(throws: InstancePrincipalError.invalidRegionMetadata(field: "realmDomainComponent", value: "oraclecloud.com@evil.com")) {
      try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: service.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
    }
  }

  @Test("a realmDomainComponent carrying a / is refused")
  func hostileRealmSlash() async throws {
    let (service, _) = try makeFakeService(regionInfoRealm: "evil.com/oraclecloud.com")
    await #expect(throws: InstancePrincipalError.invalidRegionMetadata(field: "realmDomainComponent", value: "evil.com/oraclecloud.com")) {
      try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: service.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
    }
  }

  /// `#` and `?` truncate the authority just like `@` does, so a value carrying
  /// either would re-point the federation host even though neither is a path
  /// separator. Covered end-to-end for both components, not just at unit level.
  @Test("a fragment or query character in either component is refused end-to-end")
  func hostileFragmentAndQuery() async throws {
    for hostile in ["evil.com#.oraclecloud.com", "evil.com?.oraclecloud.com"] {
      let (realmService, _) = try makeFakeService(regionInfoRealm: hostile)
      await #expect(
        throws: InstancePrincipalError.invalidRegionMetadata(field: "realmDomainComponent", value: hostile)
      ) {
        try await InstancePrincipalSigner.make(
          federationEndpointOverride: nil,
          purpose: nil,
          transport: realmService.transport(),
          environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
        )
      }

      let (regionService, _) = try makeFakeService(regionInfoRegion: hostile)
      await #expect(
        throws: InstancePrincipalError.invalidRegionMetadata(field: "regionIdentifier", value: hostile)
      ) {
        try await InstancePrincipalSigner.make(
          federationEndpointOverride: nil,
          purpose: nil,
          transport: regionService.transport(),
          environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
        )
      }
    }
  }

  /// A backslash is treated as a path separator by some URL parsers, and percent
  /// encoding can smuggle an encoded `@`. Neither is a host-label character.
  @Test("a backslash or percent-encoded character in the realm is refused")
  func hostileBackslashAndPercentEncoding() async throws {
    for hostile in ["evil.com\\.oraclecloud.com", "oraclecloud.com%40evil.com"] {
      let (service, _) = try makeFakeService(regionInfoRealm: hostile)
      await #expect(
        throws: InstancePrincipalError.invalidRegionMetadata(field: "realmDomainComponent", value: hostile)
      ) {
        try await InstancePrincipalSigner.make(
          federationEndpointOverride: nil,
          purpose: nil,
          transport: service.transport(),
          environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
        )
      }
    }
  }

  @Test("a regionIdentifier carrying an @ or a / is refused")
  func hostileRegion() async throws {
    for hostile in ["us-phoenix-1.oraclecloud.com@evil.com", "us-phoenix-1/x"] {
      let (service, _) = try makeFakeService(regionInfoRegion: hostile)
      await #expect(throws: InstancePrincipalError.invalidRegionMetadata(field: "regionIdentifier", value: hostile)) {
        try await InstancePrincipalSigner.make(
          federationEndpointOverride: nil,
          purpose: nil,
          transport: service.transport(),
          environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
        )
      }
    }
  }

  @Test("a hostile short region on the older-IMDS fallback path is refused too")
  func hostileFallbackRegion() async throws {
    let (service, _) = try makeFakeService(
      regionInfoRegion: nil,  // regionInfo returns 404 → fallback to /instance/region
      regionInfoRealm: nil,
      shortRegion: "phx.oraclecloud.com@evil.com"
    )
    await #expect(throws: InstancePrincipalError.invalidRegionMetadata(field: "region", value: "phx.oraclecloud.com@evil.com")) {
      try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: service.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
    }
  }

  @Test("uppercase regionInfo values are normalised to lower case, not rejected")
  func uppercaseIsNormalised() async throws {
    let (service, _) = try makeFakeService(
      regionInfoRegion: "US-PHOENIX-1",
      regionInfoRealm: "OracleCloud.Com"
    )
    let signer = try await InstancePrincipalSigner.make(
      federationEndpointOverride: nil,
      purpose: nil,
      transport: service.transport(),
      environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
    )
    #expect(signer.region == "us-phoenix-1")
    #expect(signer.realmDomainComponent == "oraclecloud.com")
    #expect(signer.federationEndpoint.absoluteString == "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")
  }

  @Test("an empty realmDomainComponent still falls back to the commercial realm")
  func emptyRealmFallsBack() async throws {
    let (service, _) = try makeFakeService(
      regionInfoRegion: "us-phoenix-1",
      regionInfoRealm: "",  // incomplete regionInfo, not a hostile one
      shortRegion: "phx"
    )
    let signer = try await InstancePrincipalSigner.make(
      federationEndpointOverride: nil,
      purpose: nil,
      transport: service.transport(),
      environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
    )
    #expect(signer.region == "us-phoenix-1")
    #expect(signer.realmDomainComponent == "oraclecloud.com")
    #expect(signer.federationEndpoint.absoluteString == "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")
  }

  @Test("valid commercial and non-commercial realms still compose the expected endpoint")
  func validRealmsStillWork() async throws {
    let expected = [
      ("us-ashburn-1", "oraclecloud.com"),
      ("us-luke-1", "oraclegovcloud.com"),
      ("uk-gov-london-1", "oraclegovcloud.uk"),
      ("eu-dcc-milan-1", "oraclecloud.eu"),
    ]
    for (region, realm) in expected {
      let (service, _) = try makeFakeService(regionInfoRegion: region, regionInfoRealm: realm)
      let signer = try await InstancePrincipalSigner.make(
        federationEndpointOverride: nil,
        purpose: nil,
        transport: service.transport(),
        environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
      )
      #expect(signer.region == region)
      #expect(signer.realmDomainComponent == realm)
      #expect(signer.federationEndpoint.absoluteString == "https://auth.\(region).\(realm)/v1/x509")
    }
  }

  @Test("an endpoint override survives hostile regionInfo, which is simply not exposed")
  func overrideSurvivesHostileMetadata() async throws {
    let (service, _) = try makeFakeService(regionInfoRealm: "oraclecloud.com@evil.com")
    let signer = try await InstancePrincipalSigner.make(
      federationEndpointOverride: "https://auth.us-phoenix-1.oraclecloud.com/v1/x509",
      purpose: nil,
      transport: service.transport(),
      environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
    )
    #expect(signer.federationEndpoint.absoluteString == "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")
    #expect(signer.realmDomainComponent == nil)
    #expect(signer.region == nil)
  }
}

// MARK: - forceRefresh vs. an in-flight exchange

/// `forceRefresh()` runs on the `401` retry path, which gets exactly one attempt.
/// It must not adopt the result of an exchange that read its credential material
/// *before* the rejection — that material is precisely what was rejected.
struct InstancePrincipalForceRefreshTests {
  @Test("forceRefresh does not adopt a routine exchange that began before it was called")
  func declinesOlderRoutineExchange() async throws {
    let (service, _) = try makeFakeService()
    let signer = makeSigner(service: service)
    try await signer.refresh()  // exchange #1 (prime)
    #expect(service.federationCount == 1)

    service.setCertFetchDelay(millis: 300)  // widen exchange #2's window

    async let routine: Void = signer.refresh()  // exchange #2 (routine) begins

    // Proceed only once exchange #2 is provably in flight: the cert read has been
    // counted and is now sitting inside the artificial delay. No sleep-and-hope.
    while service.certFetchCount < 2 { await Task.yield() }

    // The 401 lands here. Exchange #2 read its certificate before this point, so
    // adopting its token would re-sign the retry with the rejected credentials.
    try await signer.forceRefresh()  // must be its own exchange #3

    try await routine
    #expect(service.federationCount == 3)
  }

  @Test("concurrent forceRefresh calls coalesce onto a single post-401 exchange")
  func concurrentForceRefreshesCoalesce() async throws {
    let (service, _) = try makeFakeService()
    let signer = makeSigner(service: service)
    try await signer.refresh()
    #expect(service.federationCount == 1)

    // A certificate rotation rejects every in-flight request at once. They must
    // not each trigger their own exchange — that is the #99 herd all over again.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<20 { group.addTask { try await signer.forceRefresh() } }
      try await group.waitForAll()
    }
    #expect(service.federationCount == 2)
  }

  @Test("a routine refresh may still join an exchange forced by a sibling 401")
  func routineJoinsForcedExchange() async throws {
    let (service, _) = try makeFakeService()
    let signer = makeSigner(service: service)
    try await signer.refresh()
    service.setCertFetchDelay(millis: 300)

    async let forced: Void = signer.forceRefresh()  // exchange #2 (forced)
    while service.certFetchCount < 2 { await Task.yield() }

    // A routine refresh has no freshness requirement beyond "currently valid", so
    // joining the in-flight forced exchange is correct and avoids a second one.
    try await signer.refresh()
    try await forced
    #expect(service.federationCount == 2)
  }
}

// MARK: - Request timeouts and best-effort discovery cost

/// Every outbound request gets an explicit timeout: IMDS reads because a
/// link-local service that is slow is effectively absent, and the federation POST
/// because it sits inside the `401` retry path where `URLRequest`'s 60s default
/// is paid by an in-flight service call.
struct InstancePrincipalTimeoutTests {
  @Test("the federation POST carries an explicit timeout rather than the 60s default")
  func federationRequestHasExplicitTimeout() throws {
    let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
    let req = try InstancePrincipalSigner.buildFederationRequest(
      endpoint: URL(string: "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")!,
      leafCertificatePEM: makeFakeCertPEM(tenancy: fakeTenancy, marker: "t"),
      intermediateCertificatePEM: nil,
      sessionKey: key,
      leafPrivateKey: key,
      tenancyId: fakeTenancy,
      purpose: nil
    )
    #expect(req.timeoutInterval == InstancePrincipalSigner.federationTimeoutSeconds)
    #expect(req.timeoutInterval != 60)
  }

  @Test("IMDS reads carry the metadata timeout, and the best-effort path a shorter one")
  func metadataTimeouts() async throws {
    let (service, _) = try makeFakeService()

    // Normal discovery: the full metadata timeout.
    _ = try await InstancePrincipalSigner.discoverRegionAndRealm(
      metadata: InstanceMetadataURLs(base: fakeMetadataBase)!,
      transport: service.transport(),
      logger: Logger(label: "test")
    )
    #expect(
      service.box.withLock { $0.lastRequestTimeout } == InstancePrincipalSigner.metadataTimeoutSeconds
    )

    // Best-effort discovery behind an override: the shorter timeout, so being off
    // an instance costs seconds rather than tens of seconds.
    _ = try await InstancePrincipalSigner.make(
      federationEndpointOverride: "https://auth.us-phoenix-1.oraclecloud.com/v1/x509",
      purpose: nil,
      transport: service.transport(),
      environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
    )
    #expect(
      service.box.withLock { $0.lastRequestTimeout }
        == InstancePrincipalSigner.bestEffortMetadataTimeoutSeconds
    )
    #expect(InstancePrincipalSigner.bestEffortMetadataTimeoutSeconds < InstancePrincipalSigner.metadataTimeoutSeconds)
  }

  @Test("discoverRegion: false with an override makes no IMDS calls at all")
  func discoveryCanBeSkipped() async throws {
    let (service, _) = try makeFakeService()
    let signer = try await InstancePrincipalSigner.make(
      federationEndpointOverride: "https://auth.us-phoenix-1.oraclecloud.com/v1/x509",
      purpose: nil,
      transport: service.transport(),
      discoverRegion: false,
      environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
    )
    // No IMDS traffic: the caller pinned the endpoint and opted out of the lookup.
    #expect(service.box.withLock { $0.regionInfoCount } == 0)
    #expect(service.box.withLock { $0.certFetchCount } == 0)
    #expect(signer.federationEndpoint.absoluteString == "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")
    #expect(signer.region == nil)
    #expect(signer.realmDomainComponent == nil)
  }

  @Test("the default override path still populates region, at the shorter timeout")
  func discoveryStillDefaultsOn() async throws {
    let (service, _) = try makeFakeService()
    let signer = try await InstancePrincipalSigner.make(
      federationEndpointOverride: "https://auth.us-phoenix-1.oraclecloud.com/v1/x509",
      purpose: nil,
      transport: service.transport(),
      environment: ["OCI_METADATA_BASE_URL": fakeMetadataBase]
    )
    #expect(service.box.withLock { $0.regionInfoCount } == 1)
    #expect(signer.region == "us-phoenix-1")
    #expect(signer.realmDomainComponent == "oraclecloud.com")
  }
}

// MARK: - Certificate decode errors

/// The leaf certificate PEM always comes from IMDS `/identity/cert.pem`, never
/// from the federation response, so a decode failure must not be reported as a
/// federation-response problem — that sent anyone debugging a live instance to
/// the wrong end of the exchange.
struct InstancePrincipalCertificateErrorTests {
  @Test("a leaf certificate that is not valid PEM reports an IMDS certificate error")
  func malformedCertificatePEM() {
    let malformed = "-----BEGIN CERTIFICATE-----\nnot!valid!base64!\n-----END CERTIFICATE-----"
    #expect(throws: InstancePrincipalError.invalidCertificate("the PEM body is not valid base64")) {
      try InstancePrincipalSigner.derFromPEM(malformed)
    }
    #expect(throws: InstancePrincipalError.invalidCertificate("the PEM body is not valid base64")) {
      try InstancePrincipalSigner.tenancyId(fromCertificatePEM: malformed)
    }
    #expect(throws: InstancePrincipalError.invalidCertificate("the PEM body is not valid base64")) {
      try InstancePrincipalSigner.certificateFingerprintSHA1Hex(pem: malformed)
    }
  }

  /// A PEM whose body is wrapped with CRLF must sanitize to the same single blob as
  /// an LF-wrapped one. The strip has to match a newline *sequence*: CRLF is one
  /// grapheme cluster, so the grapheme-based `replacing("\r", …)` never matched
  /// inside it and a CRLF certificate failed to decode.
  @Test("a CRLF-wrapped certificate sanitizes and decodes identically to an LF-wrapped one")
  func crlfWrappedCertificate() throws {
    let body = "MIIBCgKCAQEAtEST\nMIIBCgKCAQEAtEST\nMIIBCgKCAQEAtEST"
    let lf = "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----"
    let crlf = lf.replacing("\n", with: "\r\n")
    // Guard the fixture: it must really contain CRLF, and be multi-line, or the
    // trimming at the ends would mask the bug (an earlier draft did exactly that).
    #expect(crlf.unicodeScalars.contains("\r"))
    #expect(crlf.split(separator: "\r\n").count == 5)

    #expect(InstancePrincipalSigner.sanitizePEM(crlf) == InstancePrincipalSigner.sanitizePEM(lf))
    #expect(!InstancePrincipalSigner.sanitizePEM(crlf).unicodeScalars.contains("\r"))
    #expect(try InstancePrincipalSigner.derFromPEM(crlf) == (try InstancePrincipalSigner.derFromPEM(lf)))
  }

  /// A lone CR and a lone LF must be stripped too — a `/[\r\n]/` class would strip
  /// the CRLF grapheme but silently miss these.
  @Test("lone CR and lone LF line endings are stripped as well")
  func loneCarriageReturnAndLineFeed() throws {
    let body = "MIIBCgKCAQEAtEST"
    let reference = InstancePrincipalSigner.sanitizePEM(
      "-----BEGIN CERTIFICATE-----\n\(body)\n\(body)\n-----END CERTIFICATE-----")
    for terminator in ["\n", "\r", "\r\n"] {
      let pem = "-----BEGIN CERTIFICATE-----\(terminator)\(body)\(terminator)\(body)\(terminator)-----END CERTIFICATE-----"
      #expect(InstancePrincipalSigner.sanitizePEM(pem) == reference, "terminator \(terminator.debugDescription)")
    }
  }

  @Test("the certificate decode message names IMDS, not the federation response")
  func messageBlamesIMDS() {
    let message =
      InstancePrincipalError.invalidCertificate("the PEM body is not valid base64")
      .errorDescription ?? ""
    #expect(message.contains("IMDS"))
    #expect(message.contains("leaf certificate"))
    // The regression: this used to render as a federation-response decode failure.
    #expect(!message.lowercased().contains("federation"))
    #expect(!message.lowercased().contains("security token"))
  }
}

// MARK: - Tenancy from the IMDS instance document

struct InstancePrincipalTenancyFallbackTests {
  /// A blank `tenantId` must not become the tenancy OCID. Untrimmed, it passed the
  /// emptiness check and was spliced into the federation `keyId` as
  /// `"   /fed-x509/<fingerprint>"`, and the leaf certificate was POSTed under it.
  @Test("a whitespace-only tenantId is refused rather than used as the tenancy")
  func whitespaceOnlyTenantIdIsRefused() async throws {
    for blank in ["   ", "\t", "\n", " \r\n "] {
      // A certificate with no tenancy tag forces the IMDS instance-document path.
      let (service, _) = try makeFakeService(tenantIdFallback: blank)
      service.box.withLock { $0.leafCertPEM = makeUntaggedCertPEM() }
      let signer = makeSigner(service: service)
      await #expect(throws: InstancePrincipalError.tenancyNotFound) {
        try await signer.refresh()
      }
      // Nothing was signed or sent under a blank tenancy.
      #expect(service.federationCount == 0, "blank \(blank.debugDescription) reached the Auth Service")
    }
  }

  @Test("a tenantId with surrounding whitespace is trimmed and used")
  func paddedTenantIdIsTrimmed() async throws {
    let (service, _) = try makeFakeService(tenantIdFallback: "  \(fakeTenancy)\n")
    service.box.withLock { $0.leafCertPEM = makeUntaggedCertPEM() }
    let signer = makeSigner(service: service)
    try await signer.refresh()
    #expect(service.federationCount == 1)
    #expect(service.box.withLock { $0.lastFederationKeyId }?.hasPrefix("\(fakeTenancy)/fed-x509/") == true)
  }
}

// MARK: - Opaque (non-JWT) token handling

/// The Auth Service returns JWTs today, but a token with no readable `exp` used
/// to be cached for the process lifetime. `TokenRefreshPolicy` now bounds it with
/// a TTL measured from when it was obtained; these pin the signer-side wiring of
/// that (the rule itself is covered by `TokenRefreshPolicyTests`).
struct InstancePrincipalOpaqueTokenTests {
  @Test("an opaque token with no exp claim is still cached, not re-federated per sign")
  func opaqueTokenIsCached() async throws {
    let (service, _) = try makeFakeService()
    service.box.withLock { $0.token = "an-opaque-token-that-is-not-a-jwt" }
    let signer = makeSigner(service: service)

    for _ in 0..<3 {
      var req = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
      req.httpMethod = "GET"
      try await signer.sign(&req)
      #expect(req.value(forHTTPHeaderField: "Authorization")?.contains("ST$an-opaque-token") == true)
    }
    // One exchange for all three signs: the token is cached under the TTL rather
    // than re-fetched, and it is not rejected outright for lacking claims.
    #expect(service.federationCount == 1)
  }

  @Test("forceRefresh still invalidates a cached opaque token")
  func forceRefreshInvalidatesOpaqueToken() async throws {
    let (service, _) = try makeFakeService()
    service.box.withLock { $0.token = "an-opaque-token-that-is-not-a-jwt" }
    let signer = makeSigner(service: service)
    try await signer.refresh()
    #expect(service.federationCount == 1)

    try await signer.forceRefresh()
    #expect(service.federationCount == 2)
  }
}

// MARK: - Refresh: rotation (#98), single-flight (#99), self-priming

/// A head-count rendezvous, so a single-flight test can rest on an observed state
/// instead of on the exchange happening to outlast task startup.
///
/// Each caller calls ``arrive()`` immediately before the call under test; the fake
/// calls ``waitForAll(timeoutSeconds:)`` inside the response it wants to hold
/// open. The wait polls and yields, so it never occupies the thread the callers it
/// is waiting for need — and it is bounded only so a genuine bug surfaces as a
/// failed expectation rather than as a hung test run.
private final class ConcurrentCallerBarrier: Sendable {
  private struct State {
    var arrived = 0
    var releasedOnHeadCount = false
  }

  private let state = Mutex(State())
  private let expected: Int

  init(expected: Int) { self.expected = expected }

  /// Records that one caller has started.
  func arrive() { state.withLock { $0.arrived += 1 } }

  /// Whether the wait ended because every caller arrived, rather than by timing out.
  var releasedOnHeadCount: Bool { state.withLock { $0.releasedOnHeadCount } }

  /// Suspends until `expected` callers have arrived, or `timeoutSeconds` elapses.
  ///
  /// Spelled in seconds rather than a `Duration` because `OCIKit` exports its own
  /// `Duration` model type, which shadows `Swift.Duration` under `@testable import`.
  func waitForAll(timeoutSeconds: Double) async {
    let deadline = ContinuousClock.now.advanced(by: Swift.Duration.seconds(timeoutSeconds))
    while true {
      let reached = state.withLock { state -> Bool in
        guard state.arrived >= self.expected else { return false }
        state.releasedOnHeadCount = true
        return true
      }
      if reached || ContinuousClock.now >= deadline { return }
      await Task.yield()
    }
  }
}

struct InstancePrincipalRefreshTests {
  @Test("sign() self-primes: it federates once, then signs with ST$<token>")
  func signSelfPrimes() async throws {
    let (service, _) = try makeFakeService()
    let signer = makeSigner(service: service)

    var req = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
    req.httpMethod = "GET"
    try await signer.sign(&req)

    #expect(service.federationCount == 1)
    let token = service.box.withLock { $0.token }
    let auth = try #require(req.value(forHTTPHeaderField: "Authorization"))
    #expect(auth.contains("keyId=\"ST$\(token)\""))
  }

  @Test("refresh re-reads the rotated leaf certificate from IMDS (issue #98)")
  func certificateRotation() async throws {
    let (service, certV1) = try makeFakeService(certMarker: "v1")
    let signer = makeSigner(service: service)

    // Prime with cert v1.
    try await signer.refresh()
    #expect(service.federationCount == 1)
    #expect(service.lastFederationCertificate == InstancePrincipalSigner.sanitizePEM(certV1))
    let certFetchesAfterPrime = service.certFetchCount
    #expect(certFetchesAfterPrime >= 1)

    // Rotate the instance certificate. The federation endpoint now accepts only
    // cert v2 and returns a new token; a signer that cached cert v1 would keep
    // presenting it and get a 401.
    let certV2 = makeFakeCertPEM(tenancy: fakeTenancy, marker: "v2")
    let tokenV2 = makeToken(offset: 1)
    service.rotate(certPEM: certV2, token: tokenV2)

    try await signer.forceRefresh()

    #expect(service.federationCount == 2)
    // The refresh federated with the *new* certificate, i.e. it was re-fetched.
    #expect(service.lastFederationCertificate == InstancePrincipalSigner.sanitizePEM(certV2))
    #expect(service.certFetchCount > certFetchesAfterPrime)

    // And the signer now signs with the rotated token.
    var req = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
    req.httpMethod = "GET"
    try await signer.sign(&req)
    let auth = try #require(req.value(forHTTPHeaderField: "Authorization"))
    #expect(auth.contains("keyId=\"ST$\(tokenV2)\""))
  }

  @Test("concurrent refreshes coalesce onto a single federation exchange (issue #99)")
  func singleFlightRefresh() async throws {
    let (service, _) = try makeFakeService()

    // Nothing suspends between `refresh()` reading `exchange.running` and
    // `startExchange` calling `exchange.begin` — a same-actor async call does not
    // hop, and `Task { }` creation does not suspend its creator — so the check and
    // the claim are atomic and at most one exchange can start *at a time*. That is
    // not the whole story, though: `refresh()` is unconditional (unlike
    // `refreshIfNeeded()` it never consults the cached token), so a straggler that
    // only reached the actor after the first exchange had already finished would
    // legitimately open a second one, and the count below would fail for a reason
    // that has nothing to do with #99.
    //
    // So instead of widening the exchange with a sleep and hoping every caller
    // fits inside it, the fake holds its first IMDS certificate read open until it
    // has *observed* all 50 callers start. Everything after that read — the key
    // read, tenancy resolution, the fresh RSA-2048 session keygen, the federation
    // POST — then provably runs with all 50 in flight. Please keep it a rendezvous
    // on a counter; don't reintroduce a duration.
    let barrier = ConcurrentCallerBarrier(expected: 50)
    let imds = service.transport()
    let gated = HTTPClient { request in
      if request.url?.path.hasSuffix("/identity/cert.pem") == true {
        await barrier.waitForAll(timeoutSeconds: 60)
      }
      return try await imds.data(request)
    }
    let signer = InstancePrincipalSigner(
      region: "us-phoenix-1",
      realmDomainComponent: "oraclecloud.com",
      federationEndpoint: URL(string: "https://auth.us-phoenix-1.oraclecloud.com/v1/x509")!,
      metadata: InstanceMetadataURLs(base: fakeMetadataBase)!,
      purpose: nil,
      transport: gated,
      logger: Logger(label: "test")
    )

    // 50 concurrent refreshes on an unprimed signer must federate exactly once.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask {
          barrier.arrive()
          try await signer.refresh()
        }
      }
      try await group.waitForAll()
    }

    // Guards the premise: the read was released by the head count, not by the
    // timeout. Without this a future regression could quietly turn the assertion
    // below into a statement about one caller.
    #expect(barrier.releasedOnHeadCount, "the exchange did not overlap all 50 callers, so the count below proves nothing")
    #expect(service.federationCount == 1)
  }

  @Test("concurrent sign() calls are data-race-free and share one exchange")
  func concurrentSignsAreSafe() async throws {
    let (service, _) = try makeFakeService()
    let signer = makeSigner(service: service)
    let token = service.box.withLock { $0.token }

    let auths = try await withThrowingTaskGroup(of: String?.self) { group -> [String?] in
      for _ in 0..<50 {
        group.addTask {
          var req = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
          req.httpMethod = "GET"
          try await signer.sign(&req)
          return req.value(forHTTPHeaderField: "Authorization")
        }
      }
      var collected: [String?] = []
      for try await auth in group { collected.append(auth) }
      return collected
    }

    #expect(service.federationCount == 1)
    #expect(auths.count == 50)
    #expect(auths.allSatisfy { $0?.contains("keyId=\"ST$\(token)\"") == true })
  }

  @Test("an intermediate certificate is included in the federation payload when present")
  func intermediateIncluded() async throws {
    let intermediate = makeFakeCertPEM(tenancy: fakeTenancy, marker: "intermediate")
    let (service, _) = try makeFakeService(intermediatePEM: intermediate)
    let signer = makeSigner(service: service)

    try await signer.refresh()

    #expect(service.federationCount == 1)
    #expect(service.lastFederationIntermediates == [InstancePrincipalSigner.sanitizePEM(intermediate)])
  }

  @Test("tenancy falls back to the IMDS instance document when the cert lacks it")
  func tenancyFallback() async throws {
    // A cert body with no opc-tenant/opc-identity tag forces the /instance/ read.
    let certNoTenant =
      "-----BEGIN CERTIFICATE-----\n\(Data("no tenancy here".utf8).base64EncodedString())\n-----END CERTIFICATE-----"
    let service = FakeMetadataService(
      leafCertPEM: certNoTenant,
      leafKeyPEM: try makeLeafKeyPEM(),
      token: makeToken(),
      tenantIdFallback: fakeTenancy
    )
    let signer = makeSigner(service: service)
    // refresh() must succeed: the tenancy is read from the /instance/ document.
    try await signer.refresh()
    #expect(service.federationCount == 1)
  }
}
