//
//  ResourcePrincipalSigner.swift
//  OCIKit
//
//  Implements OCI Resource Principals **v2.2** authentication, mirroring
//  `oci/auth/signers/ephemeral_resource_principals_signer.py`
//  (`EphemeralResourcePrincipalSigner`) from the Python SDK.
//
//  Resource Principals let workloads that run inside certain OCI services
//  (Functions, **Container Instances**, Data Science, etc.) authenticate to
//  other OCI services without an API key. For v2.2 the hosting service injects
//  the session token (RPST) and its matching private key into the container's
//  environment; the SDK simply signs requests with keyId `ST$<rpst>` using that
//  key — there is **no** network round-trip at construction or sign time.
//
//  Environment variables (read by ``ResourcePrincipalSigner/fromEnvironment(_:)``):
//    - `OCI_RESOURCE_PRINCIPAL_VERSION`               — must be `"2.2"`.
//    - `OCI_RESOURCE_PRINCIPAL_RPST`                  — the RPST, either the raw
//      token value or an **absolute path** to a file containing it.
//    - `OCI_RESOURCE_PRINCIPAL_PRIVATE_PEM`           — the private key, either a
//      raw PEM string or an **absolute path** to a PEM file.
//    - `OCI_RESOURCE_PRINCIPAL_PRIVATE_PEM_PASSPHRASE`— optional passphrase.
//      Encrypted keys are not supported by swift-crypto; see note below.
//    - `OCI_RESOURCE_PRINCIPAL_REGION`                — optional region id.
//
//  As in the Python SDK, whether a value is a literal or a file path is decided
//  purely by whether the string is an absolute path (begins with `/`). File-based
//  values are re-read on refresh so that a rotated RPST/key on disk is picked up.
//

import Crypto
import Foundation
import _CryptoExtras

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Errors

/// Errors raised while constructing or using a ``ResourcePrincipalSigner``.
public enum ResourcePrincipalError: Error, LocalizedError, Equatable {
  /// `OCI_RESOURCE_PRINCIPAL_VERSION` is not set in the environment.
  case versionNotDefined
  /// `OCI_RESOURCE_PRINCIPAL_VERSION` is set to a value this SDK does not support.
  case unsupportedVersion(String)
  /// `OCI_RESOURCE_PRINCIPAL_RPST` is missing or resolved to an empty token.
  case missingSessionToken
  /// `OCI_RESOURCE_PRINCIPAL_PRIVATE_PEM` is missing.
  case missingPrivateKey
  /// The resolved private key could not be parsed as an RSA PEM key.
  case invalidPrivateKey
  /// A file referenced by an RP environment variable could not be read.
  case fileReadFailed(String)

  public var errorDescription: String? {
    switch self {
    case .versionNotDefined:
      return "OCI_RESOURCE_PRINCIPAL_VERSION is not defined"
    case .unsupportedVersion(let v):
      return "Unsupported OCI_RESOURCE_PRINCIPAL_VERSION: \(v)"
    case .missingSessionToken:
      return "OCI_RESOURCE_PRINCIPAL_RPST was not provided. Resource principals authentication can only be used in certain OCI services."
    case .missingPrivateKey:
      return "OCI_RESOURCE_PRINCIPAL_PRIVATE_PEM must be provided. Resource principals authentication can only be used in certain OCI services."
    case .invalidPrivateKey:
      return "The resource principal private key is not a valid RSA PEM key (encrypted keys are not supported)"
    case .fileReadFailed(let path):
      return "Failed to read resource principal material from file: \(path)"
    }
  }
}

// MARK: - Environment variable names

/// The exact environment-variable names read for Resource Principals v2.2.
enum ResourcePrincipalEnv {
  static let version = "OCI_RESOURCE_PRINCIPAL_VERSION"
  static let rpst = "OCI_RESOURCE_PRINCIPAL_RPST"
  static let privatePem = "OCI_RESOURCE_PRINCIPAL_PRIVATE_PEM"
  static let passphrase = "OCI_RESOURCE_PRINCIPAL_PRIVATE_PEM_PASSPHRASE"
  static let region = "OCI_RESOURCE_PRINCIPAL_REGION"

  /// The only Resource Principal version this signer implements.
  static let supportedVersion = "2.2"
}

// MARK: - Value sources (literal vs. file path)

/// A string-valued RP input that is either a literal value or an absolute file path.
///
/// Matches the Python SDK's `os.path.isabs(...)` decision: any value beginning
/// with `/` is treated as a filesystem path, everything else as a literal.
enum ResourcePrincipalSource: Equatable {
  case value(String)
  case file(String)

  /// Classifies a raw environment value into a literal or a file path.
  static func detect(_ raw: String) -> ResourcePrincipalSource {
    raw.hasPrefix("/") ? .file(raw) : .value(raw)
  }

  /// Resolves the source to its current string contents, reading the file each
  /// time so that rotated on-disk material is picked up on refresh.
  func resolve() throws -> String {
    switch self {
    case .value(let v):
      return v
    case .file(let path):
      guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw ResourcePrincipalError.fileReadFailed(path)
      }
      return contents
    }
  }
}

// MARK: - ResourcePrincipalSigner

/// A ``Signer`` that authenticates using OCI Resource Principals v2.2.
///
/// The signer caches the current RPST and private key and, before signing,
/// transparently refreshes them once the token is within 60 seconds of its JWT
/// `exp` (matching the Python SDK's default jitter). When the RPST or key were
/// supplied as file paths, refresh re-reads them from disk.
///
/// ## Example
/// ```swift
/// // Inside a Container Instance / Function where OCI injects the RP env vars:
/// let signer = try await ResourcePrincipalSigner.fromEnvironment()
/// let client = try ObjectStorageClient(region: .fra, signer: signer)
/// ```
///
/// ## Concurrency
///
/// The signer is an `actor`: its cached RPST/key are actor-isolated (no lock),
/// and ``sign(_:)`` reloads inline when the token is within its expiry jitter.
/// Unlike the network-based principals, refresh here is cheap (a re-read of the
/// injected env value or on-disk file), so there is no background/single-flight
/// machinery.
public actor ResourcePrincipalSigner: RefreshableSigner {
  private let rpstSource: ResourcePrincipalSource
  private let keySource: ResourcePrincipalSource

  /// The region id reported by `OCI_RESOURCE_PRINCIPAL_REGION`, if any.
  /// Used by callers to select a service endpoint; not part of signing.
  public nonisolated let region: String?


  private var cachedToken: String?
  private var cachedKey: _RSA.Signing.PrivateKey?
  private var cachedExpiry: Int?
  /// When the cached token was loaded; the staleness bound for a token that
  /// carries no readable `exp` claim.
  private var cachedObtainedAt: Int?

  // MARK: Designated init

  init(rpstSource: ResourcePrincipalSource, keySource: ResourcePrincipalSource, region: String?) {
    self.rpstSource = rpstSource
    self.keySource = keySource
    self.region = region
  }

  // MARK: Public constructors

  /// Builds a signer from the Resource Principals environment variables and
  /// eagerly loads the RPST + key so the returned signer is immediately usable.
  ///
  /// - Parameter environment: The environment to read (defaults to the process
  ///   environment). Injectable for testing.
  /// - Throws: ``ResourcePrincipalError`` when the version is missing/unsupported
  ///   or required values are absent/invalid.
  public static func fromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> ResourcePrincipalSigner {
    guard let version = environment[ResourcePrincipalEnv.version], !version.isEmpty else {
      throw ResourcePrincipalError.versionNotDefined
    }
    guard version == ResourcePrincipalEnv.supportedVersion else {
      throw ResourcePrincipalError.unsupportedVersion(version)
    }
    guard let rpstRaw = environment[ResourcePrincipalEnv.rpst], !rpstRaw.isEmpty else {
      throw ResourcePrincipalError.missingSessionToken
    }
    guard let pemRaw = environment[ResourcePrincipalEnv.privatePem], !pemRaw.isEmpty else {
      throw ResourcePrincipalError.missingPrivateKey
    }

    let signer = ResourcePrincipalSigner(
      rpstSource: .detect(rpstRaw),
      keySource: .detect(pemRaw),
      region: environment[ResourcePrincipalEnv.region]
    )
    // Fail fast if the injected material is invalid, rather than at first request.
    try await signer.refresh()
    return signer
  }

  /// Builds a signer from an in-memory RPST and PEM private key (no file access).
  ///
  /// - Parameters:
  ///   - sessionToken: The raw RPST value.
  ///   - privateKeyPEM: The private key in PEM format.
  ///   - region: Optional region id.
  public init(sessionToken: String, privateKeyPEM: String, region: String? = nil) {
    self.rpstSource = .value(sessionToken)
    self.keySource = .pem(privateKeyPEM)
    self.region = region
  }

  // MARK: Signer

  /// Signs `req` with the cached RPST, reloading inline when the token is within
  /// its expiry jitter.
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

  /// Returns a currently-valid token + key pair, reloading inline when the cache
  /// is empty or within the expiry jitter. Isolated, so the two values are
  /// snapshotted together and always come from the same reload.
  private func credentials() throws -> (String, _RSA.Signing.PrivateKey) {
    try current()
  }

  // MARK: Refresh

  /// Reloads the RPST and private key from their sources, regardless of the
  /// cached token's remaining lifetime. Called after a `401`.
  public func forceRefresh() async throws {
    try reload()
  }

  /// Reloads unconditionally. Alias of ``forceRefresh()`` for a uniform surface
  /// across the token signers.
  public func refresh() async throws {
    try reload()
  }

  /// Reloads only if the cache is empty or within the expiry jitter of its `exp`.
  public func refreshIfNeeded() async throws {
    _ = try current()
  }

  /// Returns a currently-valid token/key pair, reloading if the cache is empty
  /// or the cached token is within the expiry jitter of its `exp`.
  private func current() throws -> (String, _RSA.Signing.PrivateKey) {
    if let token = cachedToken, let key = cachedKey, let obtainedAt = cachedObtainedAt,
      TokenRefreshPolicy.isFreshWithinJitter(
        expiry: cachedExpiry,
        obtainedAt: obtainedAt,
        now: Int(Date().timeIntervalSince1970)
      )
    {
      return (token, key)
    }
    // Empty cache, inside the jitter window, or past the no-`exp` TTL — reload.
    return try reload()
  }

  /// Reloads token + key from their sources and caches them.
  ///
  /// Stays actor-isolated so the cache write is serialized: when the sources are
  /// files this performs synchronous I/O on the actor, but only on the reload
  /// path (an empty cache or a token inside the expiry jitter), not per signature.
  @discardableResult
  private func reload() throws -> (String, _RSA.Signing.PrivateKey) {
    let token = try rpstSource.resolve().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw ResourcePrincipalError.missingSessionToken }

    let pem = try keySource.resolve()
    guard let key = try? _RSA.Signing.PrivateKey(pemRepresentation: pem) else {
      throw ResourcePrincipalError.invalidPrivateKey
    }

    cachedToken = token
    cachedKey = key
    cachedExpiry = TokenClaims.expiry(of: token)
    cachedObtainedAt = Int(Date().timeIntervalSince1970)
    return (token, key)
  }
}

// MARK: - Convenience source for in-memory PEM

extension ResourcePrincipalSource {
  /// A literal PEM value. Alias for `.value` that reads clearly at call sites.
  static func pem(_ pem: String) -> ResourcePrincipalSource { .value(pem) }
}
