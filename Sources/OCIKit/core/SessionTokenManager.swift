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
// Profile-level session-token lifecycle, i.e. the SDK equivalents of:
//
//   oci session validate --profile <name> [--local]
//   oci session refresh  --profile <name>
//   oci session authenticate --profile-name <name> --region <region> --no-browser
//
// Each method composes the pieces that do the actual work — ``SecurityTokenContainer``
// (claims), ``SessionTokenClient`` (wire calls) and ``SessionTokenStore`` (files) —
// and adds the config-profile handling around them.
//
// The interactive browser login flow behind a plain `oci session authenticate`
// is intentionally absent: it needs a browser and a localhost callback listener,
// neither of which belongs in a cross-platform SDK. ``authenticate(using:region:profile:configFilePath:sessionsDirectory:sessionExpirationInMinutes:realmDomainComponent:transport:logger:)``
// covers the `--no-browser` path, which is what a program (as opposed to a
// person at a terminal) can actually use.
//

import Crypto
import Foundation
import Logging
import _CryptoExtras

/// The session-token lifecycle for one OCI config profile.
///
/// ## Example
/// ```swift
/// let session = SessionTokenManager(profile: "my-session-profile")
///
/// // Check the session the way `oci session validate` does — the service is
/// // asked whether it still accepts the token — then get a signer for it:
/// let container = try await session.validate()
/// logger.info("session valid until \(container.expiresAt)")
/// let signer = try session.signer()
///
/// // Or skip the network and only check the token's own expiry, i.e. `--local`:
/// try await session.validate(local: true)
///
/// // Extend the session in place — the new token is written back to the
/// // profile's security_token_file, so the CLI sees it too:
/// try await session.refresh()
/// ```
public struct SessionTokenManager: Sendable {
  /// The OCI config file holding the profile.
  public let configFilePath: String
  /// The profile name.
  public let profile: String
  /// The realm's DNS domain component; defaults to the commercial realm.
  public let realmDomainComponent: String

  private let transport: HTTPClient
  private let logger: Logger

  /// The profile state a session operation needs: the parsed credentials plus the
  /// literal token-file path, so a refreshed token can be written back.
  struct ProfileState {
    let token: String
    let privateKey: _RSA.Signing.PrivateKey
    let region: String
    let tokenFilePath: String
  }

  public init(
    configFilePath: String = SessionTokenStore.defaultConfigFilePath,
    profile: String = "DEFAULT",
    realmDomainComponent: String = SessionTokenClient.defaultRealmDomainComponent,
    transport: HTTPClient = .live,
    logger: Logger = Logger(label: "SessionTokenManager")
  ) {
    self.configFilePath = configFilePath
    self.profile = profile
    self.realmDomainComponent = realmDomainComponent
    self.transport = transport
    self.logger = logger
  }

  // MARK: Profile access

  /// Loads the profile's session credentials.
  ///
  /// The config file is parsed once: the literal `security_token_file` path comes
  /// straight from the parsed section, and the credentials come from
  /// ``SignerConfiguration/forSecurityToken(section:configName:)`` — the same
  /// resolution ``SecurityTokenSigner`` performs — applied to that same section.
  /// The section is read through ``SessionTokenStore/profileSection(configFilePath:profile:)``
  /// rather than by parsing here, so there is one place that maps a missing file
  /// and a missing profile onto ``ConfigErrors``.
  ///
  /// Errors are raised in ``SecurityTokenSigner``'s own order — `key_file` before
  /// `security_token_file` — so a profile broken in more than one way reports the
  /// same case either type reads it.
  ///
  /// - Throws: ``ConfigErrors/badConfigFileFormat`` when the config file cannot be
  ///   read or parsed, ``ConfigErrors/missingConfig`` when the profile is absent,
  ///   and ``ConfigErrors/missingKeyfile``, ``ConfigErrors/badKeyfile``,
  ///   ``ConfigErrors/notPemFormat``, ``ConfigErrors/missingSecurityTokenFile``,
  ///   ``ConfigErrors/badSecurityTokenFile`` or ``ConfigErrors/missingRegion``
  ///   for an incomplete or unreadable one — the same errors
  ///   ``SecurityTokenSigner`` reports for the same profile.
  func profileState() throws -> ProfileState {
    let section = try SessionTokenStore.profileSection(configFilePath: configFilePath, profile: profile)
    // Reuses the loader `SecurityTokenSigner` already uses, so a profile that
    // signs today resolves identically here — without re-parsing the file.
    let configuration = try SignerConfiguration.forSecurityToken(section: section, configName: profile)
    guard let tokenFilePath = section["security_token_file"] else {
      throw ConfigErrors.missingSecurityTokenFile
    }
    guard let token = configuration.securityToken else { throw ConfigErrors.badSecurityTokenFile }
    return ProfileState(
      token: token,
      privateKey: configuration.privateKey,
      region: configuration.region,
      tokenFilePath: tokenFilePath
    )
  }

  /// The parsed session token currently on disk for this profile.
  public func container() throws -> SecurityTokenContainer {
    try SecurityTokenContainer(token: profileState().token)
  }

  /// A signer for this profile's session token.
  ///
  /// Equivalent to `SecurityTokenSigner(configFilePath:configName:)`; offered here
  /// so a caller that validates or refreshes a session does not need a second
  /// entry point to then use it.
  public func signer() throws -> SecurityTokenSigner {
    try SecurityTokenSigner(
      configFilePath: SessionTokenStore.expandingTilde(configFilePath),
      configName: profile
    )
  }

  // MARK: Validate

  /// Tests whether the profile's session is still usable — the SDK equivalent of
  /// `oci session validate`.
  ///
  /// The defaults match the CLI: plain `oci session validate` contacts the
  /// service, and the offline-only check is the opt-in `--local`.
  ///
  /// - Parameter local: When `false` (the default, i.e. plain
  ///   `oci session validate`), the token's `exp` claim is checked *and* the token
  ///   is used to make one cheap authenticated call — the only way to detect a
  ///   session that was terminated before it expired. When `true` (the equivalent
  ///   of `oci session validate --local`), only the `exp` claim is checked and no
  ///   network call is made.
  /// - Returns: The parsed token, so the caller can report ``SecurityTokenContainer/expiresAt``.
  /// - Throws: ``SessionTokenError/sessionExpired(expiredAt:)`` when the token has
  ///   expired, ``SessionTokenError/rejectedByService`` when a non-local check is
  ///   refused, and ``ConfigErrors`` when the profile cannot be read.
  @discardableResult
  public func validate(local: Bool = false) async throws -> SecurityTokenContainer {
    let state = try profileState()
    let container = try SecurityTokenContainer(token: state.token)
    guard container.isValid() else {
      throw SessionTokenError.sessionExpired(expiredAt: container.expiresAt)
    }
    if !local {
      let client = try makeClient(region: state.region)
      try await client.validateWithService(token: state.token, privateKey: state.privateKey)
    }
    logger.debug("Session \(profile) is valid until \(container.expiresAt)")
    return container
  }

  // MARK: Refresh

  /// Refreshes the profile's session and writes the new token back to its
  /// `security_token_file` — the SDK equivalent of `oci session refresh`.
  ///
  /// The refresh call is signed with the current token, so an already-expired
  /// session cannot be refreshed; that case is reported as
  /// ``SessionTokenError/sessionExpired(expiredAt:)`` before any request is made, a
  /// session with too little of its window left to be worth an exchange as
  /// ``SessionTokenError/sessionTooCloseToExpiry(expiresAt:minimumRemaining:)`` (see
  /// `minimumRemaining`), and a session the service considers over as
  /// ``SessionTokenError/refreshRejected``. All three mean the same thing to a
  /// caller: a new session must be created.
  ///
  /// The token file keeps user-only permissions, and the refreshed token is
  /// picked up by anything reading the profile afterwards — including the CLI.
  ///
  /// Known limitation: there is no cross-process locking, so two concurrent
  /// refreshes of the same profile — this SDK racing `oci session refresh`, or two
  /// tasks in one program — are last-writer-wins on the token file, which is safe
  /// because neither issued token invalidates the other, and both are bound to the
  /// profile's unchanged keypair. That reasoning does *not* extend to
  /// ``authenticate(using:region:profile:configFilePath:sessionsDirectory:sessionExpirationInMinutes:realmDomainComponent:transport:logger:)``,
  /// which rotates the keypair; concurrent `authenticate` calls in one process are
  /// serialized by ``SessionTokenStore`` so a mismatched key/token pair cannot
  /// reach disk, but this SDK racing `oci session authenticate` still can.
  ///
  /// - Parameter minimumRemaining: How much of the current session's window must be
  ///   left for the exchange to be attempted at all, in seconds. Defaults to
  ///   ``SecurityTokenContainer/defaultExpiryJitterSeconds``, so a session in its
  ///   last moments fails locally as ``SessionTokenError/sessionTooCloseToExpiry(expiresAt:minimumRemaining:)``
  ///   instead of spending a round trip on a request that would very likely land
  ///   after `exp`. Pass `0` to attempt the refresh whenever the token has not
  ///   *already* expired — worth it if keeping this particular session alive matters
  ///   more than the latency of a probable failure.
  /// - Returns: The refreshed token, parsed.
  @discardableResult
  public func refresh(
    minimumRemaining: Int = SecurityTokenContainer.defaultExpiryJitterSeconds
  ) async throws -> SecurityTokenContainer {
    try await refresh(using: try profileState(), minimumRemaining: minimumRemaining)
  }

  /// The refresh exchange over an *already-read* profile.
  ///
  /// The seam behind ``refresh()``, so a caller that has just read the profile — the
  /// ``SessionTokenSigner``, which needs the private key to cache next to the token
  /// it gets back — refreshes with that same read instead of a second one. Re-reading
  /// would let an out-of-band `oci session authenticate` rotate the keypair between
  /// the two reads, leaving the caller pairing the new token with the old key.
  @discardableResult
  func refresh(
    using state: ProfileState,
    minimumRemaining: Int = SecurityTokenContainer.defaultExpiryJitterSeconds
  ) async throws -> SecurityTokenContainer {
    let current = try SecurityTokenContainer(token: state.token)
    // Two distinct answers, because they mean different things to a caller: the
    // session is over, versus the session is alive but not worth spending a round
    // trip on. Both end at "create a new session", but only the second is a
    // judgement call the caller can overrule with `minimumRemaining: 0`.
    guard current.isValid() else {
      throw SessionTokenError.sessionExpired(expiredAt: current.expiresAt)
    }
    guard minimumRemaining <= 0 || current.isValid(jitterSeconds: minimumRemaining) else {
      throw SessionTokenError.sessionTooCloseToExpiry(
        expiresAt: current.expiresAt,
        minimumRemaining: minimumRemaining
      )
    }

    let client = try makeClient(region: state.region)
    let refreshedToken = try await client.refreshSecurityToken(
      currentToken: state.token,
      privateKey: state.privateKey
    )
    let refreshed = try SecurityTokenContainer(token: refreshedToken)
    try SessionTokenStore.writeToken(refreshedToken, toPath: state.tokenFilePath)
    logger.debug("Session \(profile) refreshed; now valid until \(refreshed.expiresAt)")
    return refreshed
  }

  // MARK: Authenticate (non-interactive)

  /// A session created by ``authenticate(using:region:profile:configFilePath:sessionsDirectory:sessionExpirationInMinutes:realmDomainComponent:transport:logger:)``.
  public struct AuthenticatedSession: Sendable {
    /// The issued session token, parsed.
    public let container: SecurityTokenContainer
    /// The keypair the token is bound to.
    public let keyPair: SessionKeyPair
    /// Where the session was written.
    public let paths: SessionTokenStore.SessionPaths

    /// A signer for the new session, usable immediately without re-reading the
    /// config file.
    public var signer: SecurityTokenSigner {
      SecurityTokenSigner(securityToken: container.token, privateKey: keyPair.privateKey)
    }
  }

  /// Creates a new user session non-interactively and persists it as a config
  /// profile — the `--no-browser` half of `oci session authenticate`.
  ///
  /// A fresh RSA session keypair is generated, its public half is exchanged for a
  /// short-lived user security token (UPST) using credentials the caller already
  /// has, and the keypair, token, and a config profile pointing at them are
  /// written in the CLI's own layout under `~/.oci/sessions/<profile>/`. The
  /// resulting profile is usable by both this SDK and the CLI.
  ///
  /// The interactive browser login flow is not implemented — see the note at the
  /// top of this file.
  ///
  /// - Parameters:
  ///   - signer: Existing credentials authorising the exchange, typically an
  ///     ``APIKeySigner``. The session is issued for *that* principal.
  ///   - region: The region to create the session in.
  ///   - profile: The config profile name to create or replace.
  ///   - configFilePath: The config file to update.
  ///   - sessionsDirectory: Where to write the session directory.
  ///   - sessionExpirationInMinutes: Requested lifetime, 5–60 minutes.
  /// - Returns: The issued session, its keypair, and the paths written.
  @discardableResult
  public static func authenticate(
    using signer: Signer,
    region: String,
    profile: String,
    configFilePath: String = SessionTokenStore.defaultConfigFilePath,
    sessionsDirectory: String = SessionTokenStore.defaultSessionsDirectory,
    sessionExpirationInMinutes: Int = SessionTokenClient.defaultSessionMinutes,
    realmDomainComponent: String = SessionTokenClient.defaultRealmDomainComponent,
    transport: HTTPClient = .live,
    logger: Logger = Logger(label: "SessionTokenManager")
  ) async throws -> AuthenticatedSession {
    let client = try SessionTokenClient(
      region: region,
      realmDomainComponent: realmDomainComponent,
      transport: transport,
      logger: logger
    )
    let keyPair = try SessionKeyPair.generate()
    let token = try await client.generateUserSecurityToken(
      publicKeyPEM: keyPair.publicKeyPEM,
      sessionExpirationInMinutes: sessionExpirationInMinutes,
      signer: signer
    )
    let container = try SecurityTokenContainer(token: token)
    let paths = try SessionTokenStore.persistSession(
      keyPair: keyPair,
      token: token,
      profile: profile,
      region: SessionTokenClient.canonicalRegionId(region),
      // The issued token carries the principal it was minted for, so the profile
      // records the same user/tenancy the CLI would write.
      tenancyOCID: container.tenancyId,
      userOCID: container.subject,
      configFilePath: configFilePath,
      sessionsDirectory: sessionsDirectory
    )
    logger.debug("Session \(profile) created; valid until \(container.expiresAt)")
    return AuthenticatedSession(container: container, keyPair: keyPair, paths: paths)
  }

  // MARK: Helpers

  private func makeClient(region: String) throws -> SessionTokenClient {
    try SessionTokenClient(
      region: region,
      realmDomainComponent: realmDomainComponent,
      transport: transport,
      logger: logger
    )
  }
}
