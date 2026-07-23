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
// Implements OCI **Instance Principals** authentication, mirroring
// `oci/auth/signers/instance_principals_security_token_signer.py`
// (`InstancePrincipalsSecurityTokenSigner`) + `oci/auth/federation_client.py`
// (`X509FederationClient`) from the Python SDK.
//
// Instance principals let a workload running on an OCI compute instance
// authenticate to OCI services with no API key and no config file. The signer:
//
//   1. Reads the instance's leaf certificate, its private key, and any
//      intermediate certificate from the Instance Metadata Service (IMDS,
//      `http://169.254.169.254/opc/v2/identity/...`).
//   2. Generates an ephemeral RSA session keypair.
//   3. POSTs the leaf certificate + session public key to the regional Auth
//      Service `/v1/x509` federation endpoint, signing the request with the
//      leaf key. The endpoint returns a short-lived security token.
//   4. Signs subsequent service requests with keyId `ST$<token>` and the
//      ephemeral session key, exactly like every other `SecurityTokenSigner`.
//
// OCI rotates the instance leaf certificate periodically, so the leaf cert, key,
// and intermediate are **re-read from IMDS on every refresh** (not cached for
// the process lifetime); the ephemeral session key is likewise regenerated each
// refresh. This is what lets a long-running daemon ride through a certificate
// rotation without a restart.
//
// ## Concurrency
//
// The signer is an `actor`, so its cached token + session key are protected by
// actor isolation rather than a lock:
//
//   - ``sign(_:)`` refreshes inline when the cached token is missing or past its
//     half-life (`await refreshIfNeeded()`), then signs — so a freshly built
//     signer is usable without a separate priming step.
//   - ``refresh()`` performs the federation exchange; concurrent callers coalesce
//     onto a single in-flight exchange (single-flight), so a burst of requests
//     arriving after a token expiry federates once, not N times.
//   - ``fromMetadata(federationEndpointOverride:purpose:transport:logger:_:)``
//     builds the signer and performs the first exchange eagerly, so it fails fast
//     off an OCI instance instead of at first request.
//

import Crypto
import Foundation
import Logging
import _CryptoExtras

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Errors

/// Errors raised while constructing or using an ``InstancePrincipalSigner``.
public enum InstancePrincipalError: Error, LocalizedError, Equatable {
  /// An IMDS endpoint could not be reached or returned a non-2xx status. Almost
  /// always means the code is not running on an OCI compute instance.
  case metadataUnavailable(String)
  /// The instance region could not be determined from IMDS.
  case regionUnavailable
  /// The federation endpoint string (override or realm-derived) is not a valid URL.
  case invalidFederationEndpoint(String)
  /// The leaf private key read from IMDS could not be parsed as an RSA PEM key.
  case invalidPrivateKey
  /// The tenancy OCID could not be derived from the leaf certificate or IMDS.
  case tenancyNotFound
  /// A certificate rotation unexpectedly changed the tenancy OCID.
  case tenancyChanged(previous: String, updated: String)
  /// The ephemeral session key could not be generated.
  case keyGenerationFailed
  /// The Auth Service federation endpoint returned a non-2xx status.
  case federationFailed(status: Int, message: String)
  /// The federation response could not be decoded into a security token.
  case malformedFederationResponse(String)
  /// The signer has no cached token yet — should not occur because ``sign(_:)``
  /// refreshes inline; retained as a defensive guard.
  case notPrimed

  private static let usageHint =
    "Instance principals authentication can only be used on OCI compute instances. "
    + "Please confirm this code is running on an OCI compute instance."

  public var errorDescription: String? {
    switch self {
    case .metadataUnavailable(let detail):
      return "Failed to read instance metadata from IMDS (\(detail)). \(Self.usageHint)"
    case .regionUnavailable:
      return "The instance region could not be determined from IMDS. \(Self.usageHint)"
    case .invalidFederationEndpoint(let endpoint):
      return "The Auth Service federation endpoint is not a valid URL: \(endpoint)"
    case .invalidPrivateKey:
      return "The instance leaf private key from IMDS is not a valid RSA PEM key."
    case .tenancyNotFound:
      return "The tenancy OCID could not be derived from the instance leaf certificate or IMDS."
    case .tenancyChanged(let previous, let updated):
      return
        "Unexpected update of the tenancy OCID in the leaf certificate. Previous: \(previous), updated: \(updated)."
    case .keyGenerationFailed:
      return "Failed to generate the ephemeral session key for instance principals."
    case .federationFailed(let status, let message):
      return "Instance principal federation failed (HTTP \(status)). \(message)"
    case .malformedFederationResponse(let detail):
      return "The Auth Service federation response could not be decoded into a security token: \(detail)"
    case .notPrimed:
      return "The instance principal signer has no cached token yet; call refresh() before signing."
    }
  }
}

// MARK: - IMDS endpoints

/// The Instance Metadata Service (IMDS) endpoints this signer reads.
struct InstanceMetadataURLs: Sendable {
  let region: URL
  let regionInfo: URL
  let leafCertificate: URL
  let leafPrivateKey: URL
  let intermediateCertificate: URL
  let instance: URL

  /// Builds the endpoint set from an IMDS base URL (e.g.
  /// `http://169.254.169.254/opc/v2`). Returns `nil` if the base does not form
  /// valid URLs.
  init?(base: String) {
    let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
    guard
      let region = URL(string: "\(trimmed)/instance/region"),
      let regionInfo = URL(string: "\(trimmed)/instance/regionInfo"),
      let leafCertificate = URL(string: "\(trimmed)/identity/cert.pem"),
      let leafPrivateKey = URL(string: "\(trimmed)/identity/key.pem"),
      let intermediateCertificate = URL(string: "\(trimmed)/identity/intermediate.pem"),
      let instance = URL(string: "\(trimmed)/instance/")
    else { return nil }
    self.region = region
    self.regionInfo = regionInfo
    self.leafCertificate = leafCertificate
    self.leafPrivateKey = leafPrivateKey
    self.intermediateCertificate = intermediateCertificate
    self.instance = instance
  }
}

// MARK: - InstancePrincipalSigner

/// A ``RefreshableSigner`` that authenticates using OCI Instance Principals.
///
/// ## Example
/// ```swift
/// // On an OCI compute instance whose dynamic group is mapped to an IAM policy:
/// let signer = try await InstancePrincipalSigner.fromMetadata()
/// let region = Region.from(regionId: signer.region ?? "") ?? .iad
/// let client = try ObjectStorageClient(region: region, signer: signer)
///
/// // In a long-running server, keep the token fresh per operation:
/// try await signer.refreshIfNeeded()
/// let namespace = try await client.getNamespace()
/// ```
public actor InstancePrincipalSigner: RefreshableSigner {
  /// The instance region id in long form (e.g. `us-phoenix-1`), discovered from
  /// IMDS. Exposed so callers can select a service endpoint without re-querying
  /// IMDS themselves.
  public nonisolated let region: String?
  /// The realm's DNS domain component (e.g. `oraclecloud.com`,
  /// `oraclegovcloud.com`), discovered from IMDS `regionInfo`. The federation
  /// host is derived from this, so instance principals work in non-commercial
  /// realms (OC2/OC3/…), not just the commercial one.
  public nonisolated let realmDomainComponent: String?
  /// The regional Auth Service `/v1/x509` federation endpoint.
  public nonisolated let federationEndpoint: URL

  let metadata: InstanceMetadataURLs
  private let purpose: String?
  private let transport: HTTPClient
  private let logger: Logger

  /// Seconds before `exp` used as the refresh threshold when the token carries no
  /// `iat` claim (so a half-life cannot be computed).
  private static let fallbackJitterSeconds = 60
  static let metadataAuthHeader = "Bearer Oracle"

  // Actor-isolated cache. The leaf certificate material lives in IMDS and is
  // re-read on every refresh, so only the derived/negotiated values are cached.
  private var token: String?
  private var sessionKey: _RSA.Signing.PrivateKey?
  private var tenancyId: String?
  private var issuedAt: Int?
  private var expiry: Int?
  /// The in-flight refresh, if any; used to coalesce concurrent refreshes.
  private var inFlight: Task<Void, Error>?

  // MARK: Designated init

  init(
    region: String?,
    realmDomainComponent: String?,
    federationEndpoint: URL,
    metadata: InstanceMetadataURLs,
    purpose: String?,
    transport: HTTPClient,
    logger: Logger
  ) {
    self.region = region
    self.realmDomainComponent = realmDomainComponent
    self.federationEndpoint = federationEndpoint
    self.metadata = metadata
    self.purpose = purpose
    self.transport = transport
    self.logger = logger
  }

  // MARK: Public constructors

  /// Builds a signer by discovering the instance identity from IMDS and performs
  /// the first federation exchange, so the returned signer is immediately usable.
  ///
  /// - Parameters:
  ///   - federationEndpointOverride: An explicit Auth Service `/v1/x509`
  ///     endpoint. When omitted, it is derived from the instance's region and
  ///     realm (`https://auth.<region>.<realmDomainComponent>/v1/x509`).
  ///   - purpose: An optional federation "purpose"; leave `nil` for the standard
  ///     instance-principal flow.
  ///   - transport: The HTTP transport used for IMDS and federation calls.
  ///     Defaults to ``HTTPClient/live`` (`URLSession`); injectable for testing.
  ///   - logger: Logger for diagnostics.
  ///   - environment: The environment to read (`OCI_METADATA_BASE_URL`), defaults
  ///     to the process environment. Injectable for testing.
  /// - Throws: ``InstancePrincipalError`` when IMDS is unreachable (not on an OCI
  ///   instance) or the initial federation exchange fails.
  public static func fromMetadata(
    federationEndpointOverride: String? = nil,
    purpose: String? = nil,
    transport: HTTPClient = .live,
    logger: Logger = Logger(label: "InstancePrincipalSigner"),
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> InstancePrincipalSigner {
    let signer = try await make(
      federationEndpointOverride: federationEndpointOverride,
      purpose: purpose,
      transport: transport,
      logger: logger,
      environment: environment
    )
    // Fail fast if the instance/environment is misconfigured, rather than at
    // first request.
    try await signer.refresh()
    return signer
  }

  /// Builds a signer from IMDS **without** performing the initial exchange.
  /// Discovers region + realm (needed for the federation endpoint) but does not
  /// federate. Call ``refresh()`` before the first ``sign(_:)`` — or just call
  /// ``sign(_:)``, which refreshes inline.
  static func make(
    federationEndpointOverride: String?,
    purpose: String?,
    transport: HTTPClient,
    logger: Logger = Logger(label: "InstancePrincipalSigner"),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> InstancePrincipalSigner {
    guard let metadata = InstanceMetadataURLs(base: metadataBaseURL(environment)) else {
      throw InstancePrincipalError.metadataUnavailable("invalid OCI_METADATA_BASE_URL")
    }

    let region: String?
    let realm: String?
    let endpoint: URL

    if let override = federationEndpointOverride, !override.isEmpty {
      guard let url = URL(string: override) else {
        throw InstancePrincipalError.invalidFederationEndpoint(override)
      }
      endpoint = url
      // Best-effort region discovery for the public `region` accessor; the
      // override already pins the endpoint, so a discovery failure is tolerable.
      let discovered = try? await discoverRegionAndRealm(metadata: metadata, transport: transport, logger: logger)
      region = discovered?.region
      realm = discovered?.realm
    }
    else {
      let discovered = try await discoverRegionAndRealm(metadata: metadata, transport: transport, logger: logger)
      region = discovered.region
      realm = discovered.realm
      let composed = "https://auth.\(discovered.region).\(discovered.realm)/v1/x509"
      guard let url = URL(string: composed) else {
        throw InstancePrincipalError.invalidFederationEndpoint(composed)
      }
      endpoint = url
    }

    logger.debug("Instance principal federation endpoint: \(endpoint.absoluteString)")
    return InstancePrincipalSigner(
      region: region,
      realmDomainComponent: realm,
      federationEndpoint: endpoint,
      metadata: metadata,
      purpose: purpose,
      transport: transport,
      logger: logger
    )
  }

  /// Resolves the IMDS base URL: `OCI_METADATA_BASE_URL` if set (whitespace-only
  /// treated as unset), else the default IPv4 endpoint.
  static func metadataBaseURL(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let value = environment["OCI_METADATA_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    {
      return value
    }
    return "http://169.254.169.254/opc/v2"
  }

  // MARK: Signer

  public func sign(_ req: inout URLRequest) async throws {
    try await refreshIfNeeded()
    guard let token, let sessionKey else { throw InstancePrincipalError.notPrimed }
    try await SecurityTokenSigner(securityToken: token, privateKey: sessionKey).sign(&req)
  }

  // MARK: Refresh

  /// Invalidates the cache and re-federates so the next ``sign(_:)`` uses fresh
  /// credentials. Called by ``HTTPClient/send(_:signer:retry:logger:)`` after a
  /// `401`; because it is `async`, the caller's immediate retry re-signs with the
  /// recovered token.
  public func forceRefresh() async throws {
    expiry = 0  // invalidate any concurrently-observed cached token
    try await refresh()
  }

  /// Refreshes the token only if the cache is empty or past its half-life.
  public func refreshIfNeeded() async throws {
    let now = Int(Date().timeIntervalSince1970)
    if isValid(now: now) { return }
    try await refresh()
  }

  /// Performs (or joins an in-flight) federation exchange and updates the cached
  /// token + ephemeral session key. Concurrent callers coalesce onto one
  /// exchange.
  public func refresh() async throws {
    if let existing = inFlight {
      try await existing.value
      return
    }
    let task = Task { try await self.performRefresh() }
    inFlight = task
    defer { inFlight = nil }
    try await task.value
  }

  private func performRefresh() async throws {
    // 1. Re-read the leaf certificate, private key, and intermediate from IMDS on
    //    every refresh, so a rotated instance certificate is picked up.
    let leafCertPEM = try await Self.fetchText(metadata.leafCertificate, transport: transport)
    let leafKeyPEM = try await Self.fetchText(metadata.leafPrivateKey, transport: transport)
    let intermediatePEM = try? await Self.fetchText(metadata.intermediateCertificate, transport: transport)

    guard let leafKey = try? _RSA.Signing.PrivateKey(pemRepresentation: leafKeyPEM) else {
      throw InstancePrincipalError.invalidPrivateKey
    }

    // 2. Derive the tenancy from the fresh certificate and verify it did not
    //    change across a rotation (matches the Python SDK's consistency check).
    let derivedTenancy = try await resolveTenancyId(fromCertificatePEM: leafCertPEM)
    if let previous = tenancyId, previous != derivedTenancy {
      throw InstancePrincipalError.tenancyChanged(previous: previous, updated: derivedTenancy)
    }

    // 3. Fresh ephemeral RSA-2048 session keypair on every refresh (matches
    //    Python); the returned token is bound to this key's public half.
    guard let newSessionKey = try? _RSA.Signing.PrivateKey(keySize: .bits2048) else {
      throw InstancePrincipalError.keyGenerationFailed
    }

    // 4. Build the federation request, signed with the leaf key, and send it.
    let request = try Self.buildFederationRequest(
      endpoint: federationEndpoint,
      leafCertificatePEM: leafCertPEM,
      intermediateCertificatePEM: intermediatePEM,
      sessionKey: newSessionKey,
      leafPrivateKey: leafKey,
      tenancyId: derivedTenancy,
      purpose: purpose
    )

    logger.debug("Instance principal: federating at \(federationEndpoint.absoluteString)")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport.data(request)
    }
    catch {
      throw InstancePrincipalError.federationFailed(status: -1, message: String(describing: error))
    }

    guard let http = response as? HTTPURLResponse else {
      throw InstancePrincipalError.federationFailed(status: -1, message: "Non-HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw InstancePrincipalError.federationFailed(status: http.statusCode, message: body)
    }

    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let newToken = object["token"] as? String,
      !newToken.isEmpty
    else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw InstancePrincipalError.malformedFederationResponse(body)
    }

    let claims = InstancePrincipalToken.issuedAndExpiry(of: newToken)
    token = newToken
    sessionKey = newSessionKey
    tenancyId = derivedTenancy
    issuedAt = claims.issuedAt
    expiry = claims.expiry
    logger.debug("Instance principal: obtained security token (exp=\(claims.expiry.map(String.init) ?? "nil"))")
  }

  /// Derives the tenancy OCID from the leaf certificate, falling back to the IMDS
  /// `/instance/` document's `tenantId`.
  private func resolveTenancyId(fromCertificatePEM pem: String) async throws -> String {
    if let tenancyId = try? Self.tenancyId(fromCertificatePEM: pem) {
      return tenancyId
    }
    if let json = try? await Self.fetchJSON(metadata.instance, transport: transport),
      let tenancyId = json["tenantId"] as? String,
      !tenancyId.isEmpty
    {
      return tenancyId
    }
    throw InstancePrincipalError.tenancyNotFound
  }

  /// Whether the cached token is present and still within its half-life.
  private func isValid(now: Int) -> Bool {
    guard token != nil, sessionKey != nil else { return false }
    guard let exp = expiry else { return true }  // no exp to evaluate: keep it
    let threshold: Int
    if let iat = issuedAt, exp > iat {
      threshold = exp - (exp - iat) / 2  // midpoint of the validity window
    }
    else {
      threshold = exp - Self.fallbackJitterSeconds
    }
    return now < threshold
  }
}

// MARK: - IMDS + federation wire helpers

extension InstancePrincipalSigner {
  /// Discovers the instance's region id (long form) and realm domain component.
  ///
  /// Prefers IMDS `regionInfo` (which carries `realmDomainComponent`, so
  /// non-commercial realms work); falls back to the short `region` code mapped
  /// through the ``Region`` enum with the commercial realm when `regionInfo` is
  /// unavailable (older IMDS).
  static func discoverRegionAndRealm(
    metadata: InstanceMetadataURLs,
    transport: HTTPClient,
    logger: Logger
  ) async throws -> (region: String, realm: String) {
    if let info = try? await fetchJSON(metadata.regionInfo, transport: transport),
      let regionId = (info["regionIdentifier"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !regionId.isEmpty,
      let realm = (info["realmDomainComponent"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !realm.isEmpty
    {
      return (regionId, realm)
    }

    // Fallback: older IMDS without `regionInfo` — short region code, commercial realm.
    let short = try await fetchText(metadata.region, transport: transport).lowercased()
    guard !short.isEmpty else { throw InstancePrincipalError.regionUnavailable }
    let regionId = Region(rawValue: short)?.urlPart ?? short
    logger.debug("IMDS regionInfo unavailable; using region=\(regionId) with commercial realm oraclecloud.com")
    return (regionId, "oraclecloud.com")
  }

  /// Builds the Auth Service `/v1/x509` federation request: a JSON body carrying
  /// the leaf certificate, the session public key, and any intermediate, signed
  /// with the leaf private key under keyId `<tenancy>/fed-x509/<fingerprint>`.
  static func buildFederationRequest(
    endpoint: URL,
    leafCertificatePEM: String,
    intermediateCertificatePEM: String?,
    sessionKey: _RSA.Signing.PrivateKey,
    leafPrivateKey: _RSA.Signing.PrivateKey,
    tenancyId: String,
    purpose: String?
  ) throws -> URLRequest {
    var payload: [String: Any] = [
      "certificate": sanitizePEM(leafCertificatePEM),
      "publicKey": sanitizePEM(sessionKey.publicKey.pemRepresentation),
    ]
    if let intermediateCertificatePEM {
      payload["intermediateCertificates"] = [sanitizePEM(intermediateCertificatePEM)]
    }
    if let purpose {
      payload["purpose"] = purpose
    }
    let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let fingerprint = try certificateFingerprintSHA1Hex(pem: leafCertificatePEM)

    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    req.httpBody = body
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.setValue("application/json", forHTTPHeaderField: "accept")

    let keyId = "\(tenancyId)/fed-x509/\(fingerprint)"
    try RequestSigner.sign(&req, with: leafPrivateKey, keyId: keyId, includeBodyForVerbs: ["post", "put", "patch"])
    return req
  }

  /// GETs an IMDS text endpoint with the `Bearer Oracle` header.
  static func fetchText(_ url: URL, transport: HTTPClient) async throws -> String {
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue(metadataAuthHeader, forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 10
    let (data, resp) = try await transport.data(req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw InstancePrincipalError.metadataUnavailable(url.path)
    }
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// GETs an IMDS JSON endpoint with the `Bearer Oracle` header.
  static func fetchJSON(_ url: URL, transport: HTTPClient) async throws -> [String: Any] {
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue(metadataAuthHeader, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 10
    let (data, resp) = try await transport.data(req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw InstancePrincipalError.metadataUnavailable(url.path)
    }
    guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw InstancePrincipalError.metadataUnavailable(url.path)
    }
    return dict
  }
}

// MARK: - PEM / certificate helpers (pure, testable)

extension InstancePrincipalSigner {
  /// Strips PEM header/footer lines and all newlines into a single-line base64
  /// blob, as the federation endpoint expects.
  static func sanitizePEM(_ pem: String) -> String {
    pem
      .replacing("-----BEGIN CERTIFICATE-----", with: "")
      .replacing("-----END CERTIFICATE-----", with: "")
      .replacing("-----BEGIN PUBLIC KEY-----", with: "")
      .replacing("-----END PUBLIC KEY-----", with: "")
      .replacing("\r", with: "")
      .replacing("\n", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// SHA-1 fingerprint (uppercase, colon-separated hex) over the certificate DER.
  static func certificateFingerprintSHA1Hex(pem: String) throws -> String {
    let der = try derFromPEM(pem)
    let digest = Insecure.SHA1.hash(data: der)
    return Array(digest).map { String(format: "%02X", $0) }.joined(separator: ":")
  }

  /// Decodes the base64 body of a certificate PEM into DER bytes.
  static func derFromPEM(_ pem: String) throws -> Data {
    let trimmed =
      pem
      .replacing("-----BEGIN CERTIFICATE-----", with: "")
      .replacing("-----END CERTIFICATE-----", with: "")
      .replacing("\r", with: "")
      .replacing("\n", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let der = Data(base64Encoded: trimmed) else {
      throw InstancePrincipalError.malformedFederationResponse("invalid certificate PEM")
    }
    return der
  }

  /// Extracts the tenancy OCID embedded in the instance leaf certificate's
  /// subject (`opc-tenant:` or `opc-identity:` tagged value).
  static func tenancyId(fromCertificatePEM pem: String) throws -> String {
    let der = try derFromPEM(pem)
    if let tid = extractTaggedValue(in: der, tag: "opc-tenant:") {
      return tid
    }
    if let tid = extractTaggedValue(in: der, tag: "opc-identity:") {
      return tid
    }
    throw InstancePrincipalError.tenancyNotFound
  }

  static func extractTaggedValue(in data: Data, tag: String) -> String? {
    let tagBytes = Array(tag.utf8)
    let bytes = [UInt8](data)
    guard bytes.count >= tagBytes.count else { return nil }
    var i = 0
    while i <= bytes.count - tagBytes.count {
      if Array(bytes[i..<(i + tagBytes.count)]) == tagBytes {
        let start = i + tagBytes.count
        var end = start
        while end < bytes.count {
          let c = bytes[end]
          let isLower = c >= 0x61 && c <= 0x7A
          let isDigit = c >= 0x30 && c <= 0x39
          let isDot = c == 0x2E
          let isDash = c == 0x2D
          if isLower || isDigit || isDot || isDash {
            end += 1
          }
          else {
            break
          }
        }
        var sliceEnd = end
        if sliceEnd > start {
          // If the last collected character is '0' and the next byte looks like a DER tag/length boundary,
          // drop the trailing '0' which is actually the DER SEQUENCE (0x30) byte misread as ASCII.
          if bytes[sliceEnd - 1] == 0x30 {
            if end < bytes.count {
              let next = bytes[end]
              if next >= 0x80 || next == 0x30 || next == 0x31 || next == 0x06 || next == 0x0C || next == 0x13 || next == 0x16 || next == 0x17 || next == 0x18 {
                sliceEnd -= 1
              }
            }
          }
        }
        if sliceEnd > start, let s = String(bytes: bytes[start..<sliceEnd], encoding: .utf8), !s.isEmpty {
          return s
        }
      }
      i += 1
    }
    return nil
  }
}

// MARK: - Security token (JWT) parsing (no signature verification)

/// Minimal JWT reader for the instance-principal security token. Like the Python
/// SDK, the SDK only needs `iat`/`exp` and does **not** verify the signature.
enum InstancePrincipalToken {
  /// Returns `(iat, exp)` epoch-second claims, either `nil` if absent/unparseable.
  static func issuedAndExpiry(of token: String) -> (issuedAt: Int?, expiry: Int?) {
    guard let claims = payload(of: token) else { return (nil, nil) }
    return (intClaim(claims["iat"]), intClaim(claims["exp"]))
  }

  private static func intClaim(_ value: Any?) -> Int? {
    if let i = value as? Int { return i }
    if let d = value as? Double { return Int(d) }
    return nil
  }

  private static func payload(of token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2,
      let data = base64URLDecode(String(parts[1])),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return nil
    }
    return object
  }

  /// Decodes a base64url JWT segment (base64url, no padding).
  static func base64URLDecode(_ string: String) -> Data? {
    var base64 =
      string
      .replacing("-", with: "+")
      .replacing("_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 {
      base64 += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: base64)
  }
}
