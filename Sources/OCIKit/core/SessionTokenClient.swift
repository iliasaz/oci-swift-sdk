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
// The wire calls behind an OCI **user session** (UPST):
//
//   * `POST {auth}/v1/authentication/refresh` — exchanges a still-valid session
//     token for a fresh one. This is what `oci session refresh` performs.
//   * `POST {auth}/v1/token/upst/actions/GenerateUpst` — the Identity Data Plane
//     `GenerateUserSecurityToken` operation, which mints a session token bound to
//     a caller-supplied public key. This is the non-interactive half of
//     `oci session authenticate` (the browser login flow is a CLI concern and is
//     deliberately not implemented here).
//   * `GET {identity}/20160918/regions` — the cheap authenticated call
//     `oci session validate` uses to ask the service whether a session is still
//     accepted.
//
// All three go through the injectable ``HTTPClient`` seam, so they can be
// exercised offline in hermetic tests.
//

import Crypto
import Foundation
import Logging
import _CryptoExtras

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A client for the session-token operations of the OCI Auth Service and
/// Identity Data Plane.
///
/// ## Example
/// ```swift
/// let client = try SessionTokenClient(region: "us-phoenix-1")
/// let refreshed = try await client.refreshSecurityToken(
///   currentToken: token,
///   privateKey: privateKey
/// )
/// ```
public struct SessionTokenClient: Sendable {
  /// The Auth Service base endpoint, including the `/v1` base path
  /// (e.g. `https://auth.us-phoenix-1.oraclecloud.com/v1`).
  public let authEndpoint: URL
  /// The Identity control-plane endpoint used for remote session validation
  /// (e.g. `https://identity.us-phoenix-1.oci.oraclecloud.com`).
  public let identityEndpoint: URL

  private let transport: HTTPClient
  private let logger: Logger

  /// The default realm domain component (the commercial realm, OC1).
  public static let defaultRealmDomainComponent = "oraclecloud.com"
  /// Shortest session the Auth Service accepts, in minutes.
  public static let minimumSessionMinutes = 5
  /// Longest session the Auth Service accepts, in minutes.
  public static let maximumSessionMinutes = 60
  /// Default session duration when the caller does not choose one, matching the
  /// service default.
  public static let defaultSessionMinutes = 60
  /// Timeout for session calls. Set explicitly rather than inheriting
  /// `URLRequest`'s 60s default, because a refresh can sit in front of an
  /// in-flight service call.
  public static let timeoutSeconds: TimeInterval = 30

  // MARK: Construction

  /// Builds a client for `region` in `realmDomainComponent`.
  ///
  /// - Parameters:
  ///   - region: A region id in long (`us-phoenix-1`) or short (`phx`) form.
  ///   - realmDomainComponent: The realm's DNS domain component; defaults to the
  ///     commercial realm, so OC2/OC3/… tenancies pass their own.
  ///   - transport: The HTTP transport. Defaults to ``HTTPClient/live``;
  ///     injectable for testing.
  ///   - logger: Logger for diagnostics.
  /// - Throws: ``SessionTokenError/invalidHostComponent(field:value:)`` when the
  ///   region or realm is not a plausible DNS name component, and
  ///   ``SessionTokenError/invalidEndpoint(_:)`` when the composed URL does not
  ///   parse.
  public init(
    region: String,
    realmDomainComponent: String = SessionTokenClient.defaultRealmDomainComponent,
    transport: HTTPClient = .live,
    logger: Logger = Logger(label: "SessionTokenClient")
  ) throws {
    let resolvedRegion = Self.canonicalRegionId(region)
    let realm = realmDomainComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Both components are spliced into a host that receives a request signed with
    // the user's session key, so they are validated exactly as the instance
    // principal federation host is — a value carrying `@`, `/`, `#` or `?`
    // silently re-points the request at another host.
    guard InstancePrincipalSigner.isValidHostComponent(resolvedRegion) else {
      throw SessionTokenError.invalidHostComponent(field: "region", value: region)
    }
    guard InstancePrincipalSigner.isValidHostComponent(realm) else {
      throw SessionTokenError.invalidHostComponent(field: "realmDomainComponent", value: realmDomainComponent)
    }
    let auth = "https://auth.\(resolvedRegion).\(realm)/v1"
    let identity = "https://identity.\(resolvedRegion).oci.\(realm)"
    guard let authURL = URL(string: auth) else { throw SessionTokenError.invalidEndpoint(auth) }
    guard let identityURL = URL(string: identity) else { throw SessionTokenError.invalidEndpoint(identity) }
    self.init(authEndpoint: authURL, identityEndpoint: identityURL, transport: transport, logger: logger)
  }

  /// Builds a client against explicit endpoints, for realms or test doubles the
  /// region/realm composition does not cover.
  ///
  /// - Parameters:
  ///   - authEndpoint: The Auth Service base URL **including** its `/v1` base
  ///     path; operation paths are appended to it.
  ///   - identityEndpoint: The Identity control-plane base URL.
  public init(
    authEndpoint: URL,
    identityEndpoint: URL,
    transport: HTTPClient = .live,
    logger: Logger = Logger(label: "SessionTokenClient")
  ) {
    self.authEndpoint = authEndpoint
    self.identityEndpoint = identityEndpoint
    self.transport = transport
    self.logger = logger
  }

  /// Normalises a region to its long form: short codes (`phx`) map through
  /// ``Region``, anything else is lower-cased and passed through, so regions
  /// newer than this SDK still work.
  static func canonicalRegionId(_ region: String) -> String {
    let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return Region(rawValue: trimmed)?.urlPart ?? trimmed
  }

  // MARK: Refresh

  /// Exchanges a still-valid session token for a fresh one.
  ///
  /// Equivalent to `oci session refresh`: the request is signed with the
  /// *current* token, so the session must not have expired yet. This performs
  /// only the wire call — see ``SessionTokenManager/refresh()`` for the variant
  /// that also writes the new token back to the profile's
  /// `security_token_file`.
  ///
  /// - Parameters:
  ///   - currentToken: The session token to exchange.
  ///   - privateKey: The session's private key (the profile's `key_file`).
  /// - Returns: The refreshed session token.
  /// - Throws: ``SessionTokenError/refreshRejected`` when the service answers
  ///   `401` — the user session is over and a new one must be created —
  ///   ``SessionTokenError/refreshFailed(status:message:)`` for any other
  ///   non-2xx, and ``SessionTokenError/malformedResponse(_:)`` when the body
  ///   carries no token.
  public func refreshSecurityToken(
    currentToken: String,
    privateKey: _RSA.Signing.PrivateKey
  ) async throws -> String {
    var request = URLRequest(url: authEndpoint.appending(path: "authentication/refresh"))
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(
      withJSONObject: ["currentToken": currentToken],
      options: [.sortedKeys]
    )
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.timeoutInterval = Self.timeoutSeconds
    try await SecurityTokenSigner(securityToken: currentToken, privateKey: privateKey).sign(&request)

    logger.debug("Session: refreshing token at \(authEndpoint.absoluteString)/authentication/refresh")
    let (data, status) = try await send(request) { status, message in
      status == 401 ? .refreshRejected : .refreshFailed(status: status, message: message)
    }
    logger.debug("Session: refresh succeeded (HTTP \(status))")
    return try Self.token(fromResponseBody: data)
  }

  // MARK: Generate (the non-interactive half of `session authenticate`)

  /// Mints a new user session token (UPST) bound to `publicKeyPEM`.
  ///
  /// This is the Identity Data Plane `GenerateUserSecurityToken` operation, and
  /// the non-interactive path of `oci session authenticate --no-browser`: the
  /// call is authenticated with credentials the caller *already* has (typically
  /// an ``APIKeySigner``), and returns a short-lived token for the same user.
  /// The browser login flow is a CLI concern and is not part of this SDK.
  ///
  /// - Parameters:
  ///   - publicKeyPEM: SubjectPublicKeyInfo PEM of the session public key — see
  ///     ``SessionKeyPair/publicKeyPEM``. The issued token is bound to it, so the
  ///     matching private key must sign every request made with the token.
  ///   - sessionExpirationInMinutes: Requested session lifetime, 5–60 minutes.
  ///   - signer: The signer authenticating this call (an API key signer, or an
  ///     unexpired session signer to start a new session from an old one).
  ///   - requestId: Optional `opc-request-id` for support correlation.
  /// - Returns: The issued session token.
  /// - Throws: ``SessionTokenError/invalidSessionDuration(minutes:)`` when the
  ///   duration is out of range, and
  ///   ``SessionTokenError/tokenGenerationFailed(status:message:)`` when the
  ///   service refuses the request.
  public func generateUserSecurityToken(
    publicKeyPEM: String,
    sessionExpirationInMinutes: Int = SessionTokenClient.defaultSessionMinutes,
    signer: Signer,
    requestId: String? = nil
  ) async throws -> String {
    guard (Self.minimumSessionMinutes...Self.maximumSessionMinutes).contains(sessionExpirationInMinutes) else {
      throw SessionTokenError.invalidSessionDuration(minutes: sessionExpirationInMinutes)
    }
    var request = URLRequest(url: authEndpoint.appending(path: "token/upst/actions/GenerateUpst"))
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(
      withJSONObject: [
        "publicKey": publicKeyPEM,
        "sessionExpirationInMinutes": sessionExpirationInMinutes,
      ],
      options: [.sortedKeys]
    )
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("application/json", forHTTPHeaderField: "accept")
    if let requestId { request.setValue(requestId, forHTTPHeaderField: "opc-request-id") }
    request.timeoutInterval = Self.timeoutSeconds
    try await signer.sign(&request)

    logger.debug("Session: requesting a \(sessionExpirationInMinutes)-minute user security token")
    let (data, _) = try await send(request) { status, message in
      .tokenGenerationFailed(status: status, message: message)
    }
    return try Self.token(fromResponseBody: data)
  }

  // MARK: Remote validation

  /// Asks the service whether a session token is still accepted, by making one
  /// cheap authenticated call (`ListRegions`) with it.
  ///
  /// This is what `oci session validate` does without `--local`. A locally
  /// unexpired token can still be rejected — the session may have been
  /// terminated — so this is the authoritative check.
  ///
  /// - Throws: ``SessionTokenError/rejectedByService`` on `401`, and
  ///   ``SessionTokenError/validationFailed(status:message:)`` on any other
  ///   non-2xx status.
  public func validateWithService(token: String, privateKey: _RSA.Signing.PrivateKey) async throws {
    var request = URLRequest(url: identityEndpoint.appending(path: "20160918/regions"))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "accept")
    request.timeoutInterval = Self.timeoutSeconds
    try await SecurityTokenSigner(securityToken: token, privateKey: privateKey).sign(&request)

    _ = try await send(request) { status, message in
      status == 401 ? .rejectedByService : .validationFailed(status: status, message: message)
    }
  }

  // MARK: Wire helpers

  /// Sends `request`, mapping transport failures and non-2xx statuses through
  /// `failure` so each operation reports its own error case.
  private func send(
    _ request: URLRequest,
    failure: (_ status: Int, _ message: String) -> SessionTokenError
  ) async throws -> (Data, Int) {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport.data(request)
    }
    catch {
      throw failure(-1, String(describing: error))
    }
    guard let http = response as? HTTPURLResponse else {
      throw failure(-1, "Non-HTTP response")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw failure(http.statusCode, Self.diagnostic(fromErrorBody: data))
    }
    return (data, http.statusCode)
  }

  /// Reads the `token` field out of an Auth Service response body.
  static func token(fromResponseBody data: Data) throws -> String {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let token = (object["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else {
      throw SessionTokenError.malformedResponse(Self.shape(ofSuccessBody: data))
    }
    return token
  }

  // MARK: Diagnostics

  /// How much of an error body is carried into a thrown error.
  static let maximumDiagnosticCharacters = 1024

  /// The text of a **non-2xx** body, bounded in length.
  ///
  /// An error body from these endpoints is an OCI `code`/`message` envelope, which
  /// is exactly what an operator needs, so it is carried verbatim — but bounded,
  /// so a proxy's HTML error page or a truncated stream cannot paste kilobytes
  /// into a log line.
  static func diagnostic(fromErrorBody data: Data) -> String {
    let text = String(data: data, encoding: .utf8) ?? "\(data.count) bytes that are not UTF-8"
    guard text.count > maximumDiagnosticCharacters else { return text }
    return String(text.prefix(maximumDiagnosticCharacters)) + "… (\(text.count) characters total, truncated)"
  }

  /// Describes the *shape* of a 2xx body that carried no usable token, without
  /// reproducing any of its values.
  ///
  /// The only way to reach this is a success body the SDK did not understand — and
  /// on these two endpoints a success body is a **credential**. If the service ever
  /// wrapped the token in an envelope, interpolating the body would paste a live
  /// session token into a thrown error, and from there into whatever logs the
  /// caller keeps. So the diagnostic names the keys and sizes and nothing else:
  /// enough to see *why* parsing failed, never enough to be a credential.
  static func shape(ofSuccessBody data: Data) -> String {
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
      return "\(data.count) bytes that are not JSON"
    }
    switch json {
    case let object as [String: Any]:
      let keys = object.keys.sorted().joined(separator: ", ")
      return "a JSON object of \(data.count) bytes with keys [\(keys)] and no usable token field"
    case let array as [Any]:
      return "a JSON array of \(array.count) elements (\(data.count) bytes), not an object"
    default:
      return "\(data.count) bytes of JSON that are neither an object nor an array"
    }
  }
}
