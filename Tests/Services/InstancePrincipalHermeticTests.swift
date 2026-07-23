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
private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacing("+", with: "-")
    .replacing("/", with: "_")
    .replacing("=", with: "")
}

/// Builds an unsigned-but-well-formed JWT whose payload carries `claims`. The
/// signer never verifies the signature, so the segment is a placeholder.
private func makeJWT(claims: [String: Any]) -> String {
  let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
  let payload = try! JSONSerialization.data(withJSONObject: claims)
  return "\(base64URL(header)).\(base64URL(payload)).c2ln"
}

/// A federation security token valid for an hour.
private func makeToken(offset: Int = 0) -> String {
  let now = Int(Date().timeIntervalSince1970)
  return makeJWT(claims: ["iat": now, "exp": now + 3600, "marker": offset])
}

/// A real RSA private key PEM, so `_RSA.Signing.PrivateKey(pemRepresentation:)`
/// parses it and `RequestSigner` can sign the federation request with it.
private func makeLeafKeyPEM() throws -> String {
  try _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation
}

/// Builds a fake leaf-certificate PEM whose DER body embeds an `opc-tenant:`
/// tagged value (so tenancy extraction works) plus a unique `marker` (so two
/// "rotations" produce distinct certificate strings). The body only has to be
/// valid base64 that contains the tag — it is never parsed as real X.509.
private func makeFakeCertPEM(tenancy: String, marker: String) -> String {
  var der = Data([0x30, 0x82, 0x01, 0x10])  // plausible DER SEQUENCE prefix
  der.append(Data("opc-tenant:\(tenancy)".utf8))
  der.append(Data([0x00]))  // terminator: 0x00 is not in [a-z0-9.-]
  der.append(Data("marker:\(marker)".utf8))
  let body = der.base64EncodedString()
  return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----"
}

private func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
  HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

private let fakeTenancy = "ocid1.tenancy.oc1..aaaaaaaaexampletenancy"
private let fakeMetadataBase = "http://imds.test/opc/v2"

/// An in-memory fake of IMDS + the Auth Service federation endpoint, exposed as
/// an `HTTPClient`. Thread-safe via a `Mutex`, so it is safe to share across the
/// concurrent refreshes in the single-flight test.
private final class FakeMetadataService: Sendable {
  struct Config {
    var leafCertPEM: String
    var leafKeyPEM: String
    var intermediatePEM: String?
    var token: String
    // regionInfo (nil region disables the endpoint → 404, forcing the fallback)
    var regionInfoRegion: String?
    var regionInfoRealm: String?
    var shortRegion: String?
    var tenantIdFallback: String?
    // observed traffic
    var federationCount = 0
    var certFetchCount = 0
    var regionInfoCount = 0
    var lastFederationCertificate: String?
    var lastFederationIntermediates: [String]?
    // whether federation rejects a certificate other than the current one
    var rejectStaleCertificate = true
    // artificial latency on the cert.pem read, to widen the single-flight window
    var certFetchDelayMillis = 0
  }

  let box: Mutex<Config>

  init(
    leafCertPEM: String,
    leafKeyPEM: String,
    intermediatePEM: String? = nil,
    token: String,
    regionInfoRegion: String? = "us-phoenix-1",
    regionInfoRealm: String? = "oraclecloud.com",
    shortRegion: String? = "phx",
    tenantIdFallback: String? = nil
  ) {
    box = Mutex(
      Config(
        leafCertPEM: leafCertPEM,
        leafKeyPEM: leafKeyPEM,
        intermediatePEM: intermediatePEM,
        token: token,
        regionInfoRegion: regionInfoRegion,
        regionInfoRealm: regionInfoRealm,
        shortRegion: shortRegion,
        tenantIdFallback: tenantIdFallback
      )
    )
  }

  var federationCount: Int { self.box.withLock { $0.federationCount } }
  var certFetchCount: Int { self.box.withLock { $0.certFetchCount } }
  var regionInfoCount: Int { self.box.withLock { $0.regionInfoCount } }
  var lastFederationCertificate: String? { self.box.withLock { $0.lastFederationCertificate } }
  var lastFederationIntermediates: [String]? { self.box.withLock { $0.lastFederationIntermediates } }

  /// Adds artificial latency to the cert.pem read so a batch of concurrent
  /// refreshes reliably overlaps the single in-flight exchange.
  func setCertFetchDelay(millis: Int) { self.box.withLock { $0.certFetchDelayMillis = millis } }

  /// Simulates a certificate rotation: subsequent IMDS reads serve the new cert,
  /// and federation now returns `newToken` (and rejects the old cert).
  func rotate(certPEM: String, token newToken: String) {
    self.box.withLock {
      $0.leafCertPEM = certPEM
      $0.token = newToken
    }
  }

  func transport() -> HTTPClient {
    HTTPClient { [self] req in
      let url = req.url ?? URL(string: "http://imds.test/")!
      let path = url.path

      func json(_ object: [String: Any], _ status: Int = 200) throws -> (Data, URLResponse) {
        (try JSONSerialization.data(withJSONObject: object), httpResponse(url, status))
      }
      func text(_ string: String, _ status: Int = 200) -> (Data, URLResponse) {
        (Data(string.utf8), httpResponse(url, status))
      }
      let notFound: (Data, URLResponse) = (Data(), httpResponse(url, 404))

      // Federation endpoint: .../v1/x509
      if path.hasSuffix("/v1/x509") {
        return try self.box.withLock { config -> (Data, URLResponse) in
          config.federationCount += 1
          let bodyObject = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
          let sentCert = bodyObject?["certificate"] as? String
          config.lastFederationCertificate = sentCert
          config.lastFederationIntermediates = bodyObject?["intermediateCertificates"] as? [String]
          let expected = InstancePrincipalSigner.sanitizePEM(config.leafCertPEM)
          if config.rejectStaleCertificate, sentCert != expected {
            return (Data("stale certificate".utf8), httpResponse(url, 401))
          }
          return (try JSONSerialization.data(withJSONObject: ["token": config.token]), httpResponse(url, 200))
        }
      }

      // IMDS endpoints
      if path.hasSuffix("/instance/regionInfo") {
        return try self.box.withLock { config -> (Data, URLResponse) in
          config.regionInfoCount += 1
          guard let region = config.regionInfoRegion, let realm = config.regionInfoRealm else {
            return notFound
          }
          return (
            try JSONSerialization.data(withJSONObject: [
              "realmKey": "oc1",
              "realmDomainComponent": realm,
              "regionKey": "PHX",
              "regionIdentifier": region,
            ]),
            httpResponse(url, 200)
          )
        }
      }
      if path.hasSuffix("/instance/region") {
        guard let short = self.box.withLock({ $0.shortRegion }) else { return notFound }
        return text(short)
      }
      if path.hasSuffix("/identity/cert.pem") {
        let (pem, delay) = self.box.withLock { config -> (String, Int) in
          config.certFetchCount += 1
          return (config.leafCertPEM, config.certFetchDelayMillis)
        }
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        return text(pem)
      }
      if path.hasSuffix("/identity/key.pem") {
        return text(self.box.withLock { $0.leafKeyPEM })
      }
      if path.hasSuffix("/identity/intermediate.pem") {
        guard let inter = self.box.withLock({ $0.intermediatePEM }) else { return notFound }
        return text(inter)
      }
      if path.hasSuffix("/instance/") || path.hasSuffix("/instance") {
        guard let tenant = self.box.withLock({ $0.tenantIdFallback }) else { return notFound }
        return try json(["tenantId": tenant])
      }
      return notFound
    }
  }
}

/// Builds a fake service pre-seeded with a valid cert/key/token.
private func makeFakeService(
  regionInfoRegion: String? = "us-phoenix-1",
  regionInfoRealm: String? = "oraclecloud.com",
  shortRegion: String? = "phx",
  intermediatePEM: String? = nil,
  tenantIdFallback: String? = nil,
  certMarker: String = "v1"
) throws -> (service: FakeMetadataService, certPEM: String) {
  let certPEM = makeFakeCertPEM(tenancy: fakeTenancy, marker: certMarker)
  let service = FakeMetadataService(
    leafCertPEM: certPEM,
    leafKeyPEM: try makeLeafKeyPEM(),
    intermediatePEM: intermediatePEM,
    token: makeToken(),
    regionInfoRegion: regionInfoRegion,
    regionInfoRealm: regionInfoRealm,
    shortRegion: shortRegion,
    tenantIdFallback: tenantIdFallback
  )
  return (service, certPEM)
}

/// Directly constructs a signer against a fake transport with an explicit
/// region/realm/endpoint, skipping IMDS region discovery.
private func makeSigner(
  service: FakeMetadataService,
  region: String? = "us-phoenix-1",
  realm: String? = "oraclecloud.com",
  endpoint: String = "https://auth.us-phoenix-1.oraclecloud.com/v1/x509",
  purpose: String? = nil
) -> InstancePrincipalSigner {
  InstancePrincipalSigner(
    region: region,
    realmDomainComponent: realm,
    federationEndpoint: URL(string: endpoint)!,
    metadata: InstanceMetadataURLs(base: fakeMetadataBase)!,
    purpose: purpose,
    transport: service.transport(),
    logger: Logger(label: "test")
  )
}

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
    let token = makeJWT(claims: ["iat": 1000, "exp": 5000])
    let claims = InstancePrincipalToken.issuedAndExpiry(of: token)
    #expect(claims.issuedAt == 1000)
    #expect(claims.expiry == 5000)

    let bad = InstancePrincipalToken.issuedAndExpiry(of: "not-a-jwt")
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

// MARK: - Refresh: rotation (#98), single-flight (#99), self-priming

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
    // Widen the in-flight window so all 50 callers reliably overlap it.
    service.setCertFetchDelay(millis: 100)
    let signer = makeSigner(service: service)

    // 50 concurrent refreshes on an unprimed signer must federate exactly once.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask { try await signer.refresh() }
      }
      try await group.waitForAll()
    }

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
