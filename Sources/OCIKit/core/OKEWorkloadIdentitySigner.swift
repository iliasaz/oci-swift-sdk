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
// Implements OCI **OKE Workload Identity** authentication, mirroring
// `oci/auth/signers/oke_workload_identity_resource_principal_signer.py`
// (`OkeWorkloadIdentityResourcePrincipalSigner`) from the Python SDK.
//
// OKE Workload Identity lets a pod running in an OCI Kubernetes Engine (OKE)
// cluster authenticate to OCI services using the pod's Kubernetes service
// account — no API key, no config file. Unlike Resource Principals v2.2
// (Functions / Container Instances), where the hosting service injects a ready
// RPST + private key into the container's environment, OKE performs a **runtime
// token exchange**:
//
//   1. The SDK generates an ephemeral RSA keypair.
//   2. It POSTs the public key (`{"podKey": <SPKI>}`) to the in-cluster
//      "proxymux" endpoint — `https://$KUBERNETES_SERVICE_HOST:12250/resourcePrincipalSessionTokens`
//      — authenticated with the pod's service-account bearer token.
//   3. The endpoint returns a base64-wrapped `{"token":"ST$<rpst>"}`.
//   4. Requests are then signed with keyId `ST$<rpst>` and the ephemeral key,
//      exactly like every other `SecurityTokenSigner`.
//
// The ephemeral key is regenerated on every refresh, and the service-account
// token is re-read from disk each time so a rotated token is picked up.
//
// ## Concurrency
//
// The token exchange is a network round-trip. This signer is an `actor`, so its
// cached RPST + ephemeral key are protected by actor isolation rather than a
// lock:
//
//   - ``fromEnvironment(transport:logger:environment:)`` is `async` and performs
//     the first exchange eagerly, so the returned signer is ready to sign.
//   - ``refresh()`` / ``refreshIfNeeded()`` are `async` and perform the exchange.
//     Concurrent refreshes are coalesced into a single in-flight exchange.
//   - ``sign(_:)`` refreshes inline when the cached RPST is missing or past its
//     half-life (`await refreshIfNeeded()`), then signs.
//
// Long-running servers may still call ``refreshIfNeeded()`` at the start of each
// logical operation (see the `swift-oke` example) to warm the token ahead of a
// latency-sensitive request.
//
// ## TLS to the proxymux
//
// The proxymux TLS certificate is signed by the **in-cluster Kubernetes CA**
// (`/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`, override
// `OCI_KUBERNETES_SERVICE_ACCOUNT_CERT_PATH`), not a public CA. `URLSession`
// cannot pin a custom CA in-process (no API on Linux; needs the forbidden
// `Security` framework on Apple), so this signer takes an **injected transport**
// and leaves the CA-pinning transport to the caller.
//
// The batteries-included path is the **`OCIKitWorkloadIdentity`** product:
// `OKEWorkloadIdentitySigner.fromWorkloadIdentity()` builds an AsyncHTTPClient +
// NIOSSL (BoringSSL) transport that pins ``caCertPath`` in-process — matching
// exactly what the Java/Python/Go SDKs do (no OS-trust-store install, no cluster
// step). That transport lives in the opt-in `OCIKitWorkloadIdentity` product so
// non-OKE consumers never pull the swift-nio dependency graph. Advanced callers
// can instead pass any ``HTTPClient`` to
// ``fromEnvironment(transport:logger:environment:)`` (e.g. ``HTTPClient/live``
// when the cluster CA is already in the OS trust store).
//

import Crypto
import Foundation
import Logging
import RegexBuilder
import _CryptoExtras

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Errors

/// Errors raised while constructing or using an ``OKEWorkloadIdentitySigner``.
public enum OKEWorkloadIdentityError: Error, LocalizedError, Equatable {
  /// `KUBERNETES_SERVICE_HOST` is not set — the code is not running in a pod.
  case serviceHostNotDefined
  /// The service-account token file could not be read from disk.
  case serviceAccountTokenReadFailed(String)
  /// The service-account token has no `exp` claim or has already expired.
  case serviceAccountTokenExpired
  /// The proxymux returned a non-2xx status. `403` typically means the cluster
  /// is not an *enhanced* OKE cluster (a prerequisite for workload identity).
  case tokenExchangeFailed(status: Int, message: String)
  /// The proxymux response could not be base64/JSON-decoded into an RPST.
  case malformedTokenResponse(String)
  /// The signer has no cached token yet. Provably unreachable in the current
  /// implementation: the private `credentials()` accessor that ``sign(_:)``
  /// calls always refreshes inline via ``refreshIfNeeded()`` before reading the
  /// cache, and ``performRefresh()`` assigns the RPST and ephemeral key together
  /// in one non-suspending step — so a non-throwing refresh always leaves both
  /// set. Retained as a defensive guard rather than a force-unwrap, so a future
  /// refactor that decouples those two invariants fails with a thrown error
  /// instead of a crash.
  case notPrimed
  /// The freshly generated ephemeral key could not be produced.
  case keyGenerationFailed

  public var errorDescription: String? {
    switch self {
    case .serviceHostNotDefined:
      return
        "KUBERNETES_SERVICE_HOST is not defined. OKE Workload Identity authentication can only be used inside an OKE pod."
    case .serviceAccountTokenReadFailed(let path):
      return "Failed to read the Kubernetes service account token from: \(path)"
    case .serviceAccountTokenExpired:
      return "The Kubernetes service account token is missing an exp claim or has expired."
    case .tokenExchangeFailed(let status, let message):
      if status == 403 {
        return
          "OKE Workload Identity token exchange failed (HTTP 403). Please ensure the cluster type is enhanced. \(message)"
      }
      return "OKE Workload Identity token exchange failed (HTTP \(status)). \(message)"
    case .malformedTokenResponse(let detail):
      return "The proxymux response could not be decoded into a resource principal session token: \(detail)"
    case .notPrimed:
      return "The OKE Workload Identity signer has no cached token yet; call refresh() before signing."
    case .keyGenerationFailed:
      return "Failed to generate the ephemeral session key for OKE Workload Identity."
    }
  }
}

// MARK: - Environment variable names & defaults

/// The exact environment-variable names and default paths for OKE Workload Identity.
enum OKEWorkloadIdentityEnv {
  /// Standard Kubernetes-injected host of the API server / proxymux.
  static let serviceHost = "KUBERNETES_SERVICE_HOST"
  /// Optional override for the CA cert path used to verify the proxymux TLS cert.
  static let serviceAccountCertPath = "OCI_KUBERNETES_SERVICE_ACCOUNT_CERT_PATH"
  /// Region id — shared with Resource Principals v2.2.
  static let region = "OCI_RESOURCE_PRINCIPAL_REGION"

  /// Fixed proxymux service port.
  static let proxymuxPort = "12250"
  /// Default in-pod service-account token path.
  static let defaultServiceAccountTokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  /// Default in-pod cluster CA cert path.
  static let defaultServiceAccountCertPath = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
}

// MARK: - Service-account token source

/// Where the Kubernetes service-account (SA) token comes from.
///
/// The default OKE deployment mounts the SA token at a well-known path; the
/// token is re-read from disk on every refresh so a rotated token is picked up.
/// A literal token can be supplied instead (re-validated, but never re-read).
enum ServiceAccountTokenSource: Equatable, Sendable {
  /// Read the token from this file path on each refresh.
  case file(String)
  /// Use this literal token value.
  case value(String)
}

// MARK: - OKEWorkloadIdentitySigner

/// A ``RefreshableSigner`` that authenticates using OCI OKE Workload Identity.
///
/// The batteries-included entry point is `fromWorkloadIdentity()` in the
/// `OCIKitWorkloadIdentity` product, which supplies an in-process CA-pinning
/// transport for the proxymux exchange. This core type takes an **injected**
/// transport; see ``fromEnvironment(transport:logger:environment:)`` for
/// advanced use.
///
/// ## Example
/// ```swift
/// // Inside an OKE pod whose service account is mapped to an OCI dynamic group:
/// import OCIKit
/// import OCIKitWorkloadIdentity
///
/// let signer = try await OKEWorkloadIdentitySigner.fromWorkloadIdentity()
/// let client = try ObjectStorageClient(region: .fra, signer: signer)
///
/// // In a long-running server, keep the token fresh per request:
/// try await signer.refreshIfNeeded()
/// let data = try await client.getObject(namespaceName: ns, bucketName: b, objectName: o)
/// ```
public actor OKEWorkloadIdentitySigner: RefreshableSigner {
  /// The full proxymux token-exchange endpoint.
  public nonisolated let proxymuxEndpoint: URL
  /// Where the SA token is read from.
  let saTokenSource: ServiceAccountTokenSource
  /// The CA cert path used to verify the proxymux TLS cert. Stored for callers
  /// that inject a CA-pinning transport; the default `URLSession` transport
  /// cannot pin it in-process and relies on the OS trust store instead.
  public nonisolated let caCertPath: String
  /// The region id reported by `OCI_RESOURCE_PRINCIPAL_REGION`, if any.
  public nonisolated let region: String?

  private let transport: HTTPClient
  private let logger: Logger

  // Actor-isolated cache.
  private var token: String?
  private var key: _RSA.Signing.PrivateKey?
  private var issuedAt: Int?
  private var expiry: Int?
  /// When the cached RPST was obtained; the staleness bound for a token that
  /// carries no readable `exp` claim.
  private var obtainedAt: Int?
  /// Bookkeeping for the single-flight exchange; see ``SingleFlightExchange``.
  private var exchange = SingleFlightExchange()

  // MARK: Designated init

  init(
    proxymuxEndpoint: URL,
    saTokenSource: ServiceAccountTokenSource,
    caCertPath: String,
    region: String?,
    transport: HTTPClient,
    logger: Logger
  ) {
    self.proxymuxEndpoint = proxymuxEndpoint
    self.saTokenSource = saTokenSource
    self.caCertPath = caCertPath
    self.region = region
    self.transport = transport
    self.logger = logger
  }

  // MARK: Public constructors

  /// Builds a signer from the OKE Workload Identity environment and performs the
  /// first token exchange so the returned signer is immediately usable.
  ///
  /// The `transport` is **required** and must be able to verify the proxymux TLS
  /// certificate against the cluster CA. For the batteries-included, in-process
  /// CA-pinning transport, use `OKEWorkloadIdentitySigner.fromWorkloadIdentity()`
  /// from the `OCIKitWorkloadIdentity` product instead of calling this directly.
  ///
  /// - Parameters:
  ///   - transport: The HTTP transport used for the proxymux exchange. Pass a
  ///     CA-pinning transport (see ``caCertPath``), or ``HTTPClient/live``
  ///     (`URLSession`) only when the cluster CA is already in the OS trust store.
  ///   - logger: Logger for diagnostics.
  ///   - environment: The environment to read (defaults to the process
  ///     environment). Injectable for testing.
  /// - Throws: ``OKEWorkloadIdentityError`` when required environment values are
  ///   absent or the initial exchange fails.
  public static func fromEnvironment(
    transport: HTTPClient,
    logger: Logger = Logger(label: "OKEWorkloadIdentitySigner"),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> OKEWorkloadIdentitySigner {
    let signer = try make(transport: transport, logger: logger, environment: environment)
    // Fail fast if the environment/cluster is misconfigured, rather than at first request.
    try await signer.refresh()
    return signer
  }

  /// Resolves the CA cert path used to verify the proxymux TLS certificate:
  /// `OCI_KUBERNETES_SERVICE_ACCOUNT_CERT_PATH` if set, else the standard
  /// in-pod path `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`.
  ///
  /// Exposed so a CA-pinning transport (e.g. in `OCIKitWorkloadIdentity`) can
  /// resolve the same path this signer reports via ``caCertPath``.
  public static func serviceAccountCertPath(
    fromEnvironment environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    environment[OKEWorkloadIdentityEnv.serviceAccountCertPath].flatMap { $0.isEmpty ? nil : $0 }
      ?? OKEWorkloadIdentityEnv.defaultServiceAccountCertPath
  }

  /// Builds a signer from the environment **without** performing the initial
  /// exchange. Useful when the caller wants to control when the first network
  /// call happens. Call ``refresh()`` before the first ``sign(_:)``.
  static func make(
    transport: HTTPClient,
    logger: Logger = Logger(label: "OKEWorkloadIdentitySigner"),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> OKEWorkloadIdentitySigner {
    guard let host = environment[OKEWorkloadIdentityEnv.serviceHost], !host.isEmpty else {
      throw OKEWorkloadIdentityError.serviceHostNotDefined
    }

    guard let endpoint = Self.makeProxymuxEndpoint(host: host) else {
      throw OKEWorkloadIdentityError.serviceHostNotDefined
    }

    return OKEWorkloadIdentitySigner(
      proxymuxEndpoint: endpoint,
      saTokenSource: .file(OKEWorkloadIdentityEnv.defaultServiceAccountTokenPath),
      caCertPath: serviceAccountCertPath(fromEnvironment: environment),
      region: environment[OKEWorkloadIdentityEnv.region].flatMap { $0.isEmpty ? nil : $0 },
      transport: transport,
      logger: logger
    )
  }

  /// Composes the proxymux endpoint URL from the Kubernetes service host.
  static func makeProxymuxEndpoint(host: String) -> URL? {
    URL(string: "https://\(host):\(OKEWorkloadIdentityEnv.proxymuxPort)/resourcePrincipalSessionTokens")
  }

  // MARK: Signer

  /// Signs `req` with the cached RPST, exchanging inline when the cache is empty
  /// or past its half-life.
  ///
  /// Deliberately `nonisolated`, so that only the credential snapshot is
  /// actor-isolated and the signing work (RSA signature + request-body SHA-256)
  /// provably stays off this actor's executor, regardless of whether the
  /// `nonisolated async` callee follows SE-0338 or SE-0461 semantics. See
  /// ``InstancePrincipalSigner/sign(_:)`` for the full rationale.
  public nonisolated func sign(_ req: inout URLRequest) async throws {
    let (token, key) = try await credentials()
    try await SecurityTokenSigner(securityToken: token, privateKey: key).sign(&req)
  }

  /// Returns a currently-valid RPST + key pair, exchanging inline when the cache
  /// is empty or past its half-life. Isolated, so the two values are snapshotted
  /// together and always belong to the same exchange.
  private func credentials() async throws -> (String, _RSA.Signing.PrivateKey) {
    try await refreshIfNeeded()
    guard let token, let key else { throw OKEWorkloadIdentityError.notPrimed }
    return (token, key)
  }

  // MARK: Refresh

  /// Invalidates the cache and re-exchanges so the next ``sign(_:)`` uses fresh
  /// credentials. Called by ``HTTPClient/send(_:signer:retry:logger:)`` after a
  /// `401`; because it is `async`, the caller's immediate retry re-signs with the
  /// recovered token.
  public func forceRefresh() async throws {
    expiry = 0  // invalidate any concurrently-observed cached token
    // Deliberately refuses to join an exchange that began *before* this call. Such
    // an exchange read its credential material before the `401`, so it can only
    // hand back what the service just rejected — and the retry, which gets only
    // one shot, would re-sign with it and fail again. Concurrent `forceRefresh()`
    // calls still coalesce onto one post-`401` exchange, so a certificate rotation
    // that rejects N in-flight requests triggers one exchange, not N.
    let startedBefore = exchange.started
    while true {
      // Joinable when the running exchange read its material after a `401` (it is
      // itself forced, i.e. part of this same rejection wave) or simply began
      // after this call. Either way its result cannot be the rejected credentials.
      if let running = exchange.running, exchange.kind == .forced || exchange.started > startedBefore {
        try await running.value
        return
      }
      // A routine exchange that predates this call: wait it out so two exchanges
      // never overlap, but discard its result rather than adopting it.
      if let running = exchange.running {
        _ = try? await running.value
        continue
      }
      try await startExchange(kind: .forced)
      return
    }
  }

  /// Refreshes the token only if the cache is empty or past its half-life.
  public func refreshIfNeeded() async throws {
    let now = Int(Date().timeIntervalSince1970)
    if isValid(now: now) { return }
    try await refresh()
  }

  /// Performs (or joins an in-flight) token exchange with the proxymux and
  /// updates the cached RPST + ephemeral key. Concurrent callers coalesce onto
  /// one exchange.
  public func refresh() async throws {
    if let running = exchange.running {
      try await running.value
      return
    }
    try await startExchange(kind: .routine)
  }

  /// Starts a new exchange and awaits it. The caller must have established that
  /// nothing acceptable is already in flight.
  private func startExchange(kind: SingleFlightExchange.Kind) async throws {
    let task = Task { try await self.performRefresh() }
    exchange.begin(task, kind: kind)
    try await task.value
  }

  private func performRefresh() async throws {
    // Marks the exchange finished on both success and failure. Runs as this
    // actor-isolated body returns — strictly before any `await task.value`
    // awaiter is resumed — so a caller waiting an exchange out always observes it
    // as finished when it wakes, and cannot spin.
    defer { exchange.finish() }

    // 1. Fresh ephemeral RSA-2048 keypair on every refresh (matches Python).
    //    Generated off this actor — see ``makeEphemeralKey()``.
    let key: _RSA.Signing.PrivateKey
    do {
      key = try await makeEphemeralKey()
    }
    catch {
      throw OKEWorkloadIdentityError.keyGenerationFailed
    }
    let podKey = Self.sanitizedPodKey(fromSPKIPEM: key.publicKey.pemRepresentation)

    // 2. Read + validate the SA token (re-read from disk each refresh).
    let saToken = try resolveServiceAccountToken()

    // 3. Build and send the exchange request through the injected transport.
    let request = Self.buildTokenExchangeRequest(
      endpoint: proxymuxEndpoint,
      podKey: podKey,
      saToken: saToken,
      opcRequestId: Self.generateOpcRequestId()
    )
    logger.debug("OKE workload identity: exchanging pod key at \(proxymuxEndpoint.absoluteString)")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport.data(request)
    }
    catch {
      throw OKEWorkloadIdentityError.tokenExchangeFailed(status: -1, message: String(describing: error))
    }

    // 4. Check status, decode RPST, and cache.
    guard let http = response as? HTTPURLResponse else {
      throw OKEWorkloadIdentityError.tokenExchangeFailed(status: -1, message: "Non-HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw OKEWorkloadIdentityError.tokenExchangeFailed(status: http.statusCode, message: body)
    }

    let rpst = try Self.decodeRPST(fromResponseBody: data)
    let claims = TokenClaims.issuedAndExpiry(of: rpst)

    self.token = rpst
    self.key = key
    self.issuedAt = claims.issuedAt
    self.expiry = claims.expiry
    self.obtainedAt = Int(Date().timeIntervalSince1970)
    logger.debug("OKE workload identity: obtained RPST (exp=\(claims.expiry.map(String.init) ?? "nil"))")
  }

  /// Generates the ephemeral RSA-2048 keypair.
  ///
  /// Marked `@concurrent` so this runs on the concurrent executor rather than the
  /// signer's actor. RSA-2048 key generation is a synchronous CPU burst (measured
  /// 45-220ms) with no suspension point, so generating it inline would hold the
  /// actor for that whole window and stall every concurrent ``sign(_:)`` on its
  /// credential snapshot. See ``InstancePrincipalSigner`` for the full rationale
  /// on `@concurrent` over a detached task or a bare `nonisolated async` function.
  @concurrent
  private nonisolated func makeEphemeralKey() async throws -> _RSA.Signing.PrivateKey {
    try _RSA.Signing.PrivateKey(keySize: .bits2048)
  }

  /// Reads and validates the service-account token, re-reading files each call.
  private func resolveServiceAccountToken() throws -> String {
    let raw: String
    switch saTokenSource {
    case .value(let v):
      raw = v
    case .file(let path):
      guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw OKEWorkloadIdentityError.serviceAccountTokenReadFailed(path)
      }
      raw = contents
    }
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else {
      throw OKEWorkloadIdentityError.serviceAccountTokenReadFailed(String(describing: saTokenSource))
    }
    guard TokenClaims.isUnexpired(token, now: Int(Date().timeIntervalSince1970)) else {
      throw OKEWorkloadIdentityError.serviceAccountTokenExpired
    }
    return token
  }

  /// Whether the cached token is present and still within its half-life.
  private func isValid(now: Int) -> Bool {
    guard token != nil, key != nil, let obtainedAt else { return false }
    return TokenRefreshPolicy.isFreshAtHalfLife(
      issuedAt: issuedAt,
      expiry: expiry,
      obtainedAt: obtainedAt,
      now: now
    )
  }
}

// MARK: - Wire helpers (pure, testable)

extension OKEWorkloadIdentitySigner {
  /// Serializes an SPKI PEM public key into the single-line `podKey` value the
  /// proxymux expects: header/footer lines removed and all newlines stripped.
  static func sanitizedPodKey(fromSPKIPEM pem: String) -> String {
    pem
      .replacing("-----BEGIN PUBLIC KEY-----", with: "")
      .replacing("-----END PUBLIC KEY-----", with: "")
      .replacing("-----BEGIN CERTIFICATE-----", with: "")
      .replacing("-----END CERTIFICATE-----", with: "")
      // Matches any newline *sequence*. A plain `.replacing("\r", …)` cannot:
      // `replacing(_:with:)` is grapheme-based, and CRLF is a single grapheme
      // cluster, so neither "\r" nor "\n" matches inside it and a CRLF-wrapped
      // PEM survives unchanged. A `/[\r\n]/` class is worse still — under grapheme
      // semantics it holds the one CRLF grapheme, so it strips CRLF but misses a
      // lone CR or LF. `.newlineSequence` covers CR, LF, CRLF and U+2028/U+2029.
      .replacing(CharacterClass.newlineSequence, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Builds the proxymux token-exchange request.
  static func buildTokenExchangeRequest(
    endpoint: URL,
    podKey: String,
    saToken: String,
    opcRequestId: String
  ) -> URLRequest {
    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    // JSONSerialization with a single string value is deterministic and avoids
    // depending on Encodable key ordering.
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["podKey": podKey])
    req.setValue("Bearer \(saToken)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-type")
    req.setValue(opcRequestId, forHTTPHeaderField: "opc-request-id")
    return req
  }

  /// Decodes the proxymux response body — base64 of `{"token":"ST$<rpst>"}` —
  /// into the bare RPST (with the `ST$` prefix removed).
  ///
  /// The base64 is decoded leniently (ignoring embedded newlines/whitespace, like
  /// Python's `base64.b64decode` and Go/Java) rather than with Foundation's strict
  /// `Data(base64Encoded:)`. A raw-JSON body (no base64 wrapper) is also accepted.
  static func decodeRPST(fromResponseBody data: Data) throws -> String {
    guard
      let raw = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      throw OKEWorkloadIdentityError.malformedTokenResponse("response body is not UTF-8")
    }

    // Prefer the documented base64-of-JSON form; fall back to a raw-JSON body.
    var candidateJSONs: [String] = []
    if let decoded = Data(base64Encoded: raw, options: .ignoreUnknownCharacters),
      let json = String(data: decoded, encoding: .utf8)
    {
      candidateJSONs.append(json)
    }
    candidateJSONs.append(raw)

    for json in candidateJSONs {
      guard json.contains("token"),
        let jsonData = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
        let tokenValue = object["token"] as? String
      else { continue }
      // The wire value is prefixed with "ST$"; the SecurityTokenSigner re-adds it.
      return tokenValue.hasPrefix("ST$") ? String(tokenValue.dropFirst(3)) : tokenValue
    }

    // Non-sensitive diagnostic: length + a short prefix (base64/JSON framing only).
    let prefix = String(raw.prefix(8))
    throw OKEWorkloadIdentityError.malformedTokenResponse(
      "no resource principal session token in the \(data.count)-byte response (prefix: \"\(prefix)\")"
    )
  }

  /// Generates an `opc-request-id`: three 16-byte random hex segments joined by
  /// `/`, matching the Python SDK's format.
  static func generateOpcRequestId() -> String {
    func segment() -> String {
      (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
    return "\(segment())/\(segment())/\(segment())"
  }
}
