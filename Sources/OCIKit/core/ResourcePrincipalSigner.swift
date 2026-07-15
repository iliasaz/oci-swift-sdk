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
/// let signer = try ResourcePrincipalSigner.fromEnvironment()
/// let client = try ObjectStorageClient(region: .fra, signer: signer)
/// ```
public final class ResourcePrincipalSigner: Signer, @unchecked Sendable {
  private let rpstSource: ResourcePrincipalSource
  private let keySource: ResourcePrincipalSource

  /// The region id reported by `OCI_RESOURCE_PRINCIPAL_REGION`, if any.
  /// Used by callers to select a service endpoint; not part of signing.
  public let region: String?

  /// Seconds before the RPST `exp` at which the token is treated as expired.
  private static let expiryJitterSeconds = 60

  private let lock = NSLock()
  private var cachedToken: String?
  private var cachedKey: _RSA.Signing.PrivateKey?
  private var cachedExpiry: Int?

  // MARK: Designated init

  init(rpstSource: ResourcePrincipalSource, keySource: ResourcePrincipalSource, region: String?) {
    self.rpstSource = rpstSource
    self.keySource = keySource
    self.region = region
  }

  // MARK: Public constructors

  /// Builds a signer from the Resource Principals environment variables.
  ///
  /// - Parameter environment: The environment to read (defaults to the process
  ///   environment). Injectable for testing.
  /// - Throws: ``ResourcePrincipalError`` when the version is missing/unsupported
  ///   or required values are absent.
  public static func fromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> ResourcePrincipalSigner {
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
    try signer.forceRefresh()
    return signer
  }

  /// Builds a signer from an in-memory RPST and PEM private key (no file access).
  ///
  /// - Parameters:
  ///   - sessionToken: The raw RPST value.
  ///   - privateKeyPEM: The private key in PEM format.
  ///   - region: Optional region id.
  public convenience init(sessionToken: String, privateKeyPEM: String, region: String? = nil) {
    self.init(rpstSource: .value(sessionToken), keySource: .pem(privateKeyPEM), region: region)
  }

  // MARK: Signer

  public func sign(_ req: inout URLRequest) throws {
    let (token, key) = try current()
    try SecurityTokenSigner(securityToken: token, privateKey: key).sign(&req)
  }

  // MARK: Refresh

  /// Forces a reload of the RPST and private key from their sources, regardless
  /// of the cached token's remaining lifetime. Call this after receiving a `401`.
  public func forceRefresh() throws {
    lock.lock()
    defer { lock.unlock() }
    try refreshLocked()
  }

  /// Returns a currently-valid token/key pair, refreshing if the cache is empty
  /// or the cached token is within the expiry jitter of its `exp`.
  private func current() throws -> (String, _RSA.Signing.PrivateKey) {
    lock.lock()
    defer { lock.unlock() }

    if let token = cachedToken, let key = cachedKey {
      if let exp = cachedExpiry {
        let now = Int(Date().timeIntervalSince1970)
        if now <= exp - Self.expiryJitterSeconds {
          return (token, key)
        }
        // Token is within the jitter window — fall through and refresh.
      } else {
        // No exp claim to evaluate; keep the cached material.
        return (token, key)
      }
    }

    try refreshLocked()
    return (cachedToken!, cachedKey!)
  }

  /// Reloads token + key from their sources. Caller must hold `lock`.
  private func refreshLocked() throws {
    let token = try rpstSource.resolve().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw ResourcePrincipalError.missingSessionToken }

    let pem = try keySource.resolve()
    guard let key = try? _RSA.Signing.PrivateKey(pemRepresentation: pem) else {
      throw ResourcePrincipalError.invalidPrivateKey
    }

    cachedToken = token
    cachedKey = key
    cachedExpiry = ResourcePrincipalToken.expiry(of: token)
  }
}

// MARK: - Convenience source for in-memory PEM

extension ResourcePrincipalSource {
  /// A literal PEM value. Alias for `.value` that reads clearly at call sites.
  static func pem(_ pem: String) -> ResourcePrincipalSource { .value(pem) }
}

// MARK: - RPST JWT parsing (no signature verification)

/// Minimal RPST (JWT) reader. The RPST is a signed JWT, but — exactly like the
/// Python SDK — the SDK only needs the `exp` claim and does **not** verify the
/// signature (no key is required to read claims).
enum ResourcePrincipalToken {
  /// Returns the `exp` claim (epoch seconds) from a JWT, or `nil` if absent/unparseable.
  static func expiry(of token: String) -> Int? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2,
      let payload = base64URLDecode(String(parts[1])),
      let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    else {
      return nil
    }
    if let exp = object["exp"] as? Int { return exp }
    if let exp = object["exp"] as? Double { return Int(exp) }
    return nil
  }

  /// Decodes a base64url segment (JWT payloads use base64url without padding).
  static func base64URLDecode(_ string: String) -> Data? {
    var base64 =
      string
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 {
      base64 += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: base64)
  }
}
