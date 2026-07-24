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
// Shared, credential-free test scaffolding for `InstancePrincipalSigner`: an
// in-memory fake of the Instance Metadata Service (IMDS) + the Auth Service
// `/v1/x509` federation endpoint, exposed as an injectable `HTTPClient`, plus the
// PEM/JWT builders the suites feed it.
//
// Everything here is `internal` on purpose: several suites across the
// `OCIKitServiceTests` target drive the same fake, and the fake is the only place
// where "what the wire looks like" is described. Keep behaviour changes additive
// — every knob has a default that reproduces a healthy OCI compute instance, so
// an existing suite that does not mention a knob is unaffected by it.
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

// MARK: - Constants

/// The tenancy OCID embedded in every fake leaf certificate. Not a real OCID.
let fakeTenancy = "ocid1.tenancy.oc1..aaaaaaaaexampletenancy"

/// The IMDS base URL the fake answers on. Passed to the signer either directly
/// (``makeSigner(service:region:realm:endpoint:purpose:metadataBase:)``) or via
/// `OCI_METADATA_BASE_URL` in an injected environment.
let fakeMetadataBase = "http://imds.test/opc/v2"

// MARK: - PEM / JWT builders

/// Base64url-encodes without padding (JWT segment encoding).
///
/// Prefixed `ip` because `ResourcePrincipalTest.swift` and
/// `OKEWorkloadIdentityTest.swift` already declare file-private `base64URL` /
/// `makeJWT` in this same target, and a top-level `internal` declaration of the
/// same name collides with them rather than being shadowed.
func ipBase64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacing("+", with: "-")
    .replacing("/", with: "_")
    .replacing("=", with: "")
}

/// Builds an unsigned-but-well-formed JWT whose payload carries `claims`. The
/// signer never verifies the signature, so the segment is a placeholder.
func ipMakeJWT(claims: [String: Any]) -> String {
  let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
  let payload = try! JSONSerialization.data(withJSONObject: claims)
  return "\(ipBase64URL(header)).\(ipBase64URL(payload)).c2ln"
}

/// A federation security token valid for an hour.
///
/// - Parameter offset: An arbitrary marker claim, so two tokens minted in the
///   same second are still distinguishable strings.
func makeToken(offset: Int = 0) -> String {
  let now = Int(Date().timeIntervalSince1970)
  return ipMakeJWT(claims: ["iat": now, "exp": now + 3600, "marker": offset])
}

/// A federation security token with explicit `iat`/`exp` claims, for pinning the
/// half-life refresh rule from the signer side.
///
/// - Parameters:
///   - issuedAt: the `iat` claim; omit for a token with no `iat`.
///   - expiry: the `exp` claim; omit for a token with no readable expiry.
///   - marker: makes two otherwise identical tokens distinguishable.
func makeToken(issuedAt: Int?, expiry: Int?, marker: String = "") -> String {
  var claims: [String: Any] = ["marker": marker]
  if let issuedAt { claims["iat"] = issuedAt }
  if let expiry { claims["exp"] = expiry }
  return ipMakeJWT(claims: claims)
}

/// A real RSA private key PEM, so `_RSA.Signing.PrivateKey(pemRepresentation:)`
/// parses it and `RequestSigner` can sign the federation request with it.
func makeLeafKeyPEM() throws -> String {
  try _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation
}

/// Builds a fake leaf-certificate PEM whose DER body embeds an `opc-tenant:`
/// tagged value (so tenancy extraction works) plus a unique `marker` (so two
/// "rotations" produce distinct certificate strings). The body only has to be
/// valid base64 that contains the tag — it is never parsed as real X.509.
/// A leaf certificate PEM carrying **no** `opc-tenant:`/`opc-identity:` tag, so
/// tenancy resolution falls through to the IMDS `/instance/` document.
func makeUntaggedCertPEM(marker: String = "untagged") -> String {
  var der = Data([0x30, 0x82, 0x01, 0x10])
  der.append(Data("no-tenancy-here".utf8))
  der.append(Data([0x00]))
  der.append(Data("marker:\(marker)".utf8))
  return "-----BEGIN CERTIFICATE-----\n\(der.base64EncodedString())\n-----END CERTIFICATE-----"
}

func makeFakeCertPEM(tenancy: String, marker: String) -> String {
  var der = Data([0x30, 0x82, 0x01, 0x10])  // plausible DER SEQUENCE prefix
  der.append(Data("opc-tenant:\(tenancy)".utf8))
  der.append(Data([0x00]))  // terminator: 0x00 is not in [a-z0-9.-]
  der.append(Data("marker:\(marker)".utf8))
  let body = der.base64EncodedString()
  return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----"
}

/// A certificate PEM carrying **no** `opc-tenant:`/`opc-identity:` tag, so
/// tenancy resolution has to fall back to the IMDS `/instance/` document.
func makeCertPEMWithoutTenancy(marker: String = "no-tenancy") -> String {
  let body = Data("no tenancy here \(marker)".utf8).base64EncodedString()
  return "-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----"
}

func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
  HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

// MARK: - Canned responses

/// A canned reply for one fake endpoint, used to make an endpoint 404, return a
/// non-2xx status, or serve a body the signer cannot parse.
struct FakeEndpointResponse: Sendable, Equatable {
  var status: Int
  var body: String

  init(status: Int = 200, body: String = "") {
    self.status = status
    self.body = body
  }

  /// The endpoint is absent (older IMDS, or simply not on an instance).
  static let notFound = FakeEndpointResponse(status: 404, body: "")
  /// A 200 whose body is not a document the signer can decode.
  static let garbage = FakeEndpointResponse(status: 200, body: "<<not-a-document>>")
  /// An arbitrary status/body pair.
  static func status(_ status: Int, body: String = "") -> FakeEndpointResponse {
    FakeEndpointResponse(status: status, body: body)
  }
  /// A 200 (or given status) whose body is the supplied raw string, typically JSON.
  static func body(_ body: String, status: Int = 200) -> FakeEndpointResponse {
    FakeEndpointResponse(status: status, body: body)
  }
}

/// One request the fake observed, recorded in arrival order.
struct FakeRequestRecord: Sendable {
  var path: String
  var method: String?
  var authorization: String?
  var timeout: TimeInterval
}

// MARK: - FakeMetadataService

/// An in-memory fake of IMDS + the Auth Service federation endpoint, exposed as
/// an `HTTPClient`. Thread-safe via a `Mutex`, so it is safe to share across the
/// concurrent refreshes in the single-flight tests.
///
/// Mutate it mid-test either through the helpers (``rotate(certPEM:token:)``,
/// ``setCertFetchDelay(millis:)``, …) or directly under the lock:
/// `service.box.withLock { $0.token = "…" }`.
final class FakeMetadataService: Sendable {
  /// Everything the fake serves, plus everything it observed. Every field has a
  /// default describing a healthy instance; suites override only what they test.
  struct Config {
    // MARK: served identity material
    var leafCertPEM: String
    var leafKeyPEM: String
    var intermediatePEM: String?
    var token: String
    // MARK: regionInfo / region (nil region disables regionInfo → 404, forcing the fallback)
    var regionInfoRegion: String?
    var regionInfoRealm: String?
    var regionInfoRealmKey: String = "oc1"
    var regionInfoRegionKey: String = "PHX"
    var shortRegion: String?
    var tenantIdFallback: String?
    // MARK: observed traffic
    var federationCount = 0
    var certFetchCount = 0
    var keyFetchCount = 0
    var intermediateFetchCount = 0
    var regionInfoCount = 0
    var regionCount = 0
    var instanceDocumentCount = 0
    var lastRequestTimeout: TimeInterval?
    var lastFederationCertificate: String?
    var lastFederationIntermediates: [String]?
    var lastFederationPublicKey: String?
    var lastFederationPurpose: String?
    /// The `keyId` of the OCI signature on the federation request, i.e.
    /// `<tenancy>/fed-x509/<fingerprint>`.
    var lastFederationKeyId: String?
    var requests: [FakeRequestRecord] = []
    // MARK: behaviour toggles
    /// Whether federation rejects a certificate other than the current one.
    var rejectStaleCertificate = true
    /// Artificial latency on the cert.pem read, to widen the single-flight window.
    var certFetchDelayMillis = 0
    /// Artificial latency on the federation POST, to widen the single-flight window.
    var federationDelayMillis = 0
    // MARK: canned-response overrides (nil = behave normally)
    /// Sticky override for the federation POST: when set, the endpoint returns
    /// this instead of minting a token (the request is still recorded).
    var federationResponse: FakeEndpointResponse?
    /// One-shot federation replies, consumed front-first before
    /// ``federationResponse`` and before the normal behaviour. Lets a suite script
    /// "fail once, then succeed".
    var federationResponseQueue: [FakeEndpointResponse] = []
    /// Override for IMDS `/instance/regionInfo`.
    var regionInfoResponse: FakeEndpointResponse?
    /// Override for IMDS `/instance/region`.
    var regionResponse: FakeEndpointResponse?
    /// Override for IMDS `/identity/cert.pem`.
    var leafCertificateResponse: FakeEndpointResponse?
    /// Override for IMDS `/identity/key.pem`.
    var leafPrivateKeyResponse: FakeEndpointResponse?
    /// Override for IMDS `/identity/intermediate.pem`.
    var intermediateResponse: FakeEndpointResponse?
    /// Override for the IMDS `/instance/` document.
    var instanceDocumentResponse: FakeEndpointResponse?
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

  // MARK: Observed traffic

  var federationCount: Int { self.box.withLock { $0.federationCount } }
  var certFetchCount: Int { self.box.withLock { $0.certFetchCount } }
  var keyFetchCount: Int { self.box.withLock { $0.keyFetchCount } }
  var intermediateFetchCount: Int { self.box.withLock { $0.intermediateFetchCount } }
  var regionInfoCount: Int { self.box.withLock { $0.regionInfoCount } }
  var regionCount: Int { self.box.withLock { $0.regionCount } }
  var instanceDocumentCount: Int { self.box.withLock { $0.instanceDocumentCount } }
  var lastRequestTimeout: TimeInterval? { self.box.withLock { $0.lastRequestTimeout } }
  var lastFederationCertificate: String? { self.box.withLock { $0.lastFederationCertificate } }
  var lastFederationIntermediates: [String]? { self.box.withLock { $0.lastFederationIntermediates } }
  var lastFederationPublicKey: String? { self.box.withLock { $0.lastFederationPublicKey } }
  var lastFederationPurpose: String? { self.box.withLock { $0.lastFederationPurpose } }
  var lastFederationKeyId: String? { self.box.withLock { $0.lastFederationKeyId } }
  /// Every request the fake observed, in arrival order.
  var requests: [FakeRequestRecord] { self.box.withLock { $0.requests } }
  /// The current token the federation endpoint hands out.
  var token: String { self.box.withLock { $0.token } }
  /// The certificate PEM IMDS currently serves.
  var leafCertPEM: String { self.box.withLock { $0.leafCertPEM } }

  // MARK: Mutators

  /// Adds artificial latency to the cert.pem read so a batch of concurrent
  /// refreshes reliably overlaps the single in-flight exchange.
  func setCertFetchDelay(millis: Int) { self.box.withLock { $0.certFetchDelayMillis = millis } }

  /// Adds artificial latency to the federation POST, widening the same window
  /// from the far end of the exchange.
  func setFederationDelay(millis: Int) { self.box.withLock { $0.federationDelayMillis = millis } }

  /// Simulates a certificate rotation: subsequent IMDS reads serve the new cert,
  /// and federation now returns `newToken` (and rejects the old cert).
  func rotate(certPEM: String, token newToken: String) {
    self.box.withLock {
      $0.leafCertPEM = certPEM
      $0.token = newToken
    }
  }

  /// Rotates only the certificate IMDS serves, leaving the token alone.
  func setLeafCertificate(_ pem: String) { self.box.withLock { $0.leafCertPEM = pem } }
  /// Replaces the private key IMDS serves (e.g. with unparseable material).
  func setLeafPrivateKey(_ pem: String) { self.box.withLock { $0.leafKeyPEM = pem } }
  /// Replaces the token the federation endpoint mints.
  func setToken(_ token: String) { self.box.withLock { $0.token = token } }
  /// Whether federation 401s a certificate other than the one IMDS currently serves.
  func setRejectStaleCertificate(_ reject: Bool) { self.box.withLock { $0.rejectStaleCertificate = reject } }
  /// Makes every federation POST return `response` until cleared with `nil`.
  func setFederationResponse(_ response: FakeEndpointResponse?) {
    self.box.withLock { $0.federationResponse = response }
  }
  /// Scripts the next federation replies; each is consumed once, front-first.
  func enqueueFederationResponses(_ responses: [FakeEndpointResponse]) {
    self.box.withLock { $0.federationResponseQueue.append(contentsOf: responses) }
  }

  // MARK: Transport

  func transport() -> HTTPClient {
    HTTPClient { [self] req in
      let url = req.url ?? URL(string: "http://imds.test/")!
      let path = url.path
      box.withLock {
        $0.lastRequestTimeout = req.timeoutInterval
        $0.requests.append(
          FakeRequestRecord(
            path: path,
            method: req.httpMethod,
            authorization: req.value(forHTTPHeaderField: "Authorization"),
            timeout: req.timeoutInterval
          )
        )
      }

      func text(_ string: String, _ status: Int = 200) -> (Data, URLResponse) {
        (Data(string.utf8), httpResponse(url, status))
      }
      func canned(_ response: FakeEndpointResponse) -> (Data, URLResponse) {
        text(response.body, response.status)
      }
      let notFound: (Data, URLResponse) = (Data(), httpResponse(url, 404))

      // Federation endpoint: .../v1/x509
      if path.hasSuffix("/v1/x509") {
        let outcome = self.box.withLock { config -> Result<(Data, URLResponse), any Error> in
          config.federationCount += 1
          let bodyObject = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
          let sentCert = bodyObject?["certificate"] as? String
          config.lastFederationCertificate = sentCert
          config.lastFederationKeyId = req.value(forHTTPHeaderField: "Authorization").flatMap { header in
            guard let start = header.range(of: "keyId=\"") else { return nil }
            let rest = header[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
          }
          config.lastFederationIntermediates = bodyObject?["intermediateCertificates"] as? [String]
          config.lastFederationPublicKey = bodyObject?["publicKey"] as? String
          config.lastFederationPurpose = bodyObject?["purpose"] as? String
          if !config.federationResponseQueue.isEmpty {
            return .success(canned(config.federationResponseQueue.removeFirst()))
          }
          if let scripted = config.federationResponse {
            return .success(canned(scripted))
          }
          let expected = InstancePrincipalSigner.sanitizePEM(config.leafCertPEM)
          if config.rejectStaleCertificate, sentCert != expected {
            return .success(text("stale certificate", 401))
          }
          do {
            let data = try JSONSerialization.data(withJSONObject: ["token": config.token])
            return .success((data, httpResponse(url, 200)))
          }
          catch {
            return .failure(error)
          }
        }
        let delay = self.box.withLock { $0.federationDelayMillis }
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        return try outcome.get()
      }

      // IMDS endpoints
      if path.hasSuffix("/instance/regionInfo") {
        return try self.box.withLock { config -> (Data, URLResponse) in
          config.regionInfoCount += 1
          if let scripted = config.regionInfoResponse { return canned(scripted) }
          guard let region = config.regionInfoRegion, let realm = config.regionInfoRealm else {
            return notFound
          }
          return (
            try JSONSerialization.data(withJSONObject: [
              "realmKey": config.regionInfoRealmKey,
              "realmDomainComponent": realm,
              "regionKey": config.regionInfoRegionKey,
              "regionIdentifier": region,
            ]),
            httpResponse(url, 200)
          )
        }
      }
      if path.hasSuffix("/instance/region") {
        return self.box.withLock { config -> (Data, URLResponse) in
          config.regionCount += 1
          if let scripted = config.regionResponse { return canned(scripted) }
          guard let short = config.shortRegion else { return notFound }
          return text(short)
        }
      }
      if path.hasSuffix("/identity/cert.pem") {
        let (result, delay) = self.box.withLock { config -> ((Data, URLResponse), Int) in
          config.certFetchCount += 1
          let response =
            config.leafCertificateResponse.map(canned) ?? text(config.leafCertPEM)
          return (response, config.certFetchDelayMillis)
        }
        if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
        return result
      }
      if path.hasSuffix("/identity/key.pem") {
        return self.box.withLock { config -> (Data, URLResponse) in
          config.keyFetchCount += 1
          if let scripted = config.leafPrivateKeyResponse { return canned(scripted) }
          return text(config.leafKeyPEM)
        }
      }
      if path.hasSuffix("/identity/intermediate.pem") {
        return self.box.withLock { config -> (Data, URLResponse) in
          config.intermediateFetchCount += 1
          if let scripted = config.intermediateResponse { return canned(scripted) }
          guard let inter = config.intermediatePEM else { return notFound }
          return text(inter)
        }
      }
      if path.hasSuffix("/instance/") || path.hasSuffix("/instance") {
        return try self.box.withLock { config -> (Data, URLResponse) in
          config.instanceDocumentCount += 1
          if let scripted = config.instanceDocumentResponse { return canned(scripted) }
          guard let tenant = config.tenantIdFallback else { return notFound }
          return (try JSONSerialization.data(withJSONObject: ["tenantId": tenant]), httpResponse(url, 200))
        }
      }
      return notFound
    }
  }
}

// MARK: - Builders

/// Builds a fake service pre-seeded with a valid cert/key/token.
///
/// - Parameters:
///   - regionInfoRegion: `regionIdentifier` served by `/instance/regionInfo`;
///     `nil` makes that endpoint 404 so discovery falls back to `/instance/region`.
///   - regionInfoRealm: `realmDomainComponent` served by `/instance/regionInfo`.
///   - shortRegion: the short code served by `/instance/region`; `nil` 404s it.
///   - intermediatePEM: intermediate certificate PEM; `nil` 404s that endpoint.
///   - tenantIdFallback: `tenantId` served by the `/instance/` document; `nil` 404s it.
///   - certMarker: makes two generated certificates distinguishable.
///   - tenancy: the tenancy OCID embedded in the generated certificate — pass a
///     different value to simulate a rotation that changes tenancy.
///   - leafCertPEM: an explicit certificate PEM, overriding `certMarker`/`tenancy`.
///   - leafKeyPEM: an explicit private key PEM; defaults to a fresh RSA-2048 key.
///   - token: the token federation mints; defaults to a one-hour JWT.
/// - Returns: the fake plus the leaf certificate PEM it is serving.
func makeFakeService(
  regionInfoRegion: String? = "us-phoenix-1",
  regionInfoRealm: String? = "oraclecloud.com",
  shortRegion: String? = "phx",
  intermediatePEM: String? = nil,
  tenantIdFallback: String? = nil,
  certMarker: String = "v1",
  tenancy: String = fakeTenancy,
  leafCertPEM: String? = nil,
  leafKeyPEM: String? = nil,
  token: String? = nil
) throws -> (service: FakeMetadataService, certPEM: String) {
  let certPEM = leafCertPEM ?? makeFakeCertPEM(tenancy: tenancy, marker: certMarker)
  let service = FakeMetadataService(
    leafCertPEM: certPEM,
    leafKeyPEM: try leafKeyPEM ?? makeLeafKeyPEM(),
    intermediatePEM: intermediatePEM,
    token: token ?? makeToken(),
    regionInfoRegion: regionInfoRegion,
    regionInfoRealm: regionInfoRealm,
    shortRegion: shortRegion,
    tenantIdFallback: tenantIdFallback
  )
  return (service, certPEM)
}

/// Directly constructs a signer against a fake transport with an explicit
/// region/realm/endpoint, skipping IMDS region discovery.
func makeSigner(
  service: FakeMetadataService,
  region: String? = "us-phoenix-1",
  realm: String? = "oraclecloud.com",
  endpoint: String = "https://auth.us-phoenix-1.oraclecloud.com/v1/x509",
  purpose: String? = nil,
  metadataBase: String = fakeMetadataBase
) -> InstancePrincipalSigner {
  InstancePrincipalSigner(
    region: region,
    realmDomainComponent: realm,
    federationEndpoint: URL(string: endpoint)!,
    metadata: InstanceMetadataURLs(base: metadataBase)!,
    purpose: purpose,
    transport: service.transport(),
    logger: Logger(label: "test")
  )
}
