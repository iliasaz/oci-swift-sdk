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
// A self-maintaining signer for an OCI **session-token** (UPST) config profile —
// the `security_token` authentication type written by `oci session authenticate`.
//
// ``SecurityTokenSigner`` deliberately *snapshots*: its `init(configFilePath:…)`
// reads the token file once and signs with that string forever. That is the right
// behaviour for a short-lived command, and it stays as-is. It is the wrong
// behaviour for a long-running process, because a user session is short (60
// minutes at most) and is extended in place:
//
//   * `oci session refresh`, another process, or another task in this one can
//     rewrite `security_token_file` at any moment — a snapshotting signer never
//     sees that token and keeps signing with the stale one until it 401s;
//   * nobody refreshes the session on the SDK's behalf unless the SDK does it.
//
// ``SessionTokenSigner`` closes both gaps the way every other token-based signer
// in this directory does: it is an `actor` that caches the profile's token +
// private key, treats the cache as stale at the token's **half-life**
// (``SecurityTokenContainer/isValidWithinHalfExpiration(now:)``, i.e.
// ``TokenRefreshPolicy``), and re-obtains material before signing when it is.
//
// ## Where fresh material comes from
//
// Unlike the instance-principal and OKE signers, a *wire call is not always
// needed*. The session lives in a file shared with the CLI, so a stale cache is
// first resolved by **re-reading the profile from disk**: if the on-disk token was
// already refreshed out of band it is simply adopted, no request made. Only when
// the on-disk token is itself past its half-life does this call
// ``SessionTokenManager/refresh()``, which performs the refresh exchange and
// writes the new token back to `security_token_file` — so the CLI and any other
// process see it too.
//
// All profile parsing, wire calls and file writes are delegated to
// ``SessionTokenManager``; this type only owns the caching, staleness and
// concurrency policy.
//
// ## Concurrency
//
// The cached token + session key are protected by actor isolation rather than a
// lock:
//
//   - ``sign(_:)`` re-obtains material inline when the cache is empty or past its
//     half-life, then signs — so a freshly built signer is usable without a
//     priming step.
//   - Concurrent refreshes coalesce onto a single in-flight exchange
//     (``SingleFlightExchange``), so a burst of requests arriving after a token's
//     half-life re-reads the profile — and at most refreshes — once, not N times.
//   - ``forceRefresh()`` is the `401` path: it drops the cache and refuses to
//     adopt the token the service just rejected.
//
// A session that is genuinely over cannot be repaired without a human: those
// failures (``SessionTokenError/sessionExpired(expiredAt:)``,
// ``SessionTokenError/refreshRejected``) are surfaced to the caller rather than
// swallowed, and no request is ever signed with a token known to be expired.
//

import Crypto
import Foundation
import Logging
import _CryptoExtras

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Errors

/// Errors raised by ``SessionTokenSigner`` itself.
///
/// Everything that can go wrong with the *session* — an expired session, a
/// refresh the service refused, an unreadable token file — is reported as
/// ``SessionTokenError``, and everything wrong with the *profile* as
/// ``ConfigErrors``, exactly as ``SessionTokenManager`` reports them. This enum
/// covers only the signer's own cache invariant.
public enum SessionTokenSignerError: Error, LocalizedError, Equatable {
  /// The signer could not obtain a cached session to sign with, although every
  /// refresh it attempted reported success.
  ///
  /// Reachable only under sustained invalidation: ``SessionTokenSigner/forceRefresh()``
  /// clears the cache synchronously, so a `401` wave can empty it again between a
  /// successful refresh and the `sign(_:)` that was waiting for it. `sign(_:)`
  /// therefore re-refreshes rather than failing, and gives up with this error only
  /// after several rounds — a real request must not die with "call refresh() first"
  /// merely because it was unlucky.
  case notPrimed

  public var errorDescription: String? {
    switch self {
    case .notPrimed:
      return
        "The session token signer could not keep a refreshed session long enough to sign with it, "
        + "because the cache was invalidated again by a concurrent authentication failure."
    }
  }
}

// MARK: - SessionTokenSigner

/// A ``RefreshableSigner`` that signs with an OCI **user session token** (UPST)
/// config profile and keeps that session fresh.
///
/// Use this instead of ``SecurityTokenSigner`` whenever the process outlives a
/// single request: it picks up a token refreshed out of band (`oci session
/// refresh`, another process) and refreshes the session itself at the token's
/// half-life, while ``SecurityTokenSigner`` signs forever with the token it read
/// at init.
///
/// ## Example
/// ```swift
/// // A profile created by `oci session authenticate` (auth type security_token):
/// let signer = SessionTokenSigner(profile: "my-session-profile")
/// let client = try ObjectStorageClient(region: .phx, signer: signer)
///
/// // No priming needed — the first sign() loads the profile, and every later one
/// // re-reads or refreshes the session only once it is past its half-life:
/// let namespace = try await client.getNamespace()
///
/// // A session that has actually ended surfaces as an error, because only a
/// // human can create a new one:
/// do {
///   _ = try await client.getNamespace()
/// }
/// catch SessionTokenError.refreshRejected {
///   logger.error("session is over; run `oci session authenticate` again")
/// }
/// ```
public actor SessionTokenSigner: RefreshableSigner {
  /// The OCI config file holding the profile.
  public nonisolated let configFilePath: String
  /// The profile name.
  public nonisolated let profile: String
  /// The realm's DNS domain component used to compose the Auth Service endpoint.
  public nonisolated let realmDomainComponent: String

  /// Does all the real work: profile parsing, the refresh exchange, and writing
  /// the refreshed token back to `security_token_file`.
  private let manager: SessionTokenManager
  private let logger: Logger

  /// The signing material for one session, cached together so a snapshot can
  /// never pair a token with a key it is not bound to.
  private struct Material {
    let container: SecurityTokenContainer
    let privateKey: _RSA.Signing.PrivateKey

    /// Whether this session is still within the first half of its validity
    /// window; see ``SecurityTokenContainer/isValidWithinHalfExpiration(now:)``.
    func isFresh(now: Date) -> Bool { container.isValidWithinHalfExpiration(now: now) }
  }

  // Actor-isolated cache. Both halves live in one value, so ``sign(_:)`` cannot
  // observe a token from one session with the key of another.
  private var material: Material?
  /// A token the service has refused, held until material that is *not* it has been
  /// obtained.
  ///
  /// Actor state rather than an argument to the forced exchange, because the
  /// on-disk shortcut in ``performRefresh()`` must honour the rejection whichever
  /// exchange runs it: a routine exchange started by a concurrent ``sign(_:)``
  /// carries no rejection of its own and would happily re-adopt the rejected token
  /// from disk while it is still locally fresh, handing the `401` retry the very
  /// token that caused it. The same applies in sequence — a routine refresh
  /// following a failed forced one must not fall back to the rejected token either.
  private var rejectedToken: String?
  /// Bookkeeping for the single-flight exchange; see ``SingleFlightExchange``.
  private var exchange = SingleFlightExchange()

  // MARK: Init

  /// Builds a signer for a session-token config profile.
  ///
  /// Nothing is read at init: the profile is loaded on first use, so constructing
  /// a signer never throws and never blocks. Call ``refreshIfNeeded()`` if you
  /// would rather find out about a broken profile before the first request.
  ///
  /// - Parameters:
  ///   - configFilePath: The OCI config file to read. Defaults to
  ///     ``SessionTokenStore/defaultConfigFilePath`` (`~/.oci/config`); a leading
  ///     `~` is expanded.
  ///   - profile: The config profile name. Defaults to `DEFAULT`.
  ///   - realmDomainComponent: The realm's DNS domain component used to compose
  ///     the Auth Service endpoint. Defaults to
  ///     ``SessionTokenClient/defaultRealmDomainComponent`` (the commercial
  ///     realm).
  ///   - transport: The HTTP transport used for the refresh exchange. Defaults to
  ///     ``HTTPClient/live`` (`URLSession`); injectable for testing.
  ///   - logger: Logger for diagnostics. Token material is never logged.
  public init(
    configFilePath: String = SessionTokenStore.defaultConfigFilePath,
    profile: String = "DEFAULT",
    realmDomainComponent: String = SessionTokenClient.defaultRealmDomainComponent,
    transport: HTTPClient = .live,
    logger: Logger = Logger(label: "SessionTokenSigner")
  ) {
    self.init(
      manager: SessionTokenManager(
        configFilePath: configFilePath,
        profile: profile,
        realmDomainComponent: realmDomainComponent,
        transport: transport,
        logger: logger
      ),
      logger: logger
    )
  }

  /// Builds a signer around an existing ``SessionTokenManager``, for a caller that
  /// already validated or created the session through one and does not want a
  /// second description of the same profile.
  ///
  /// - Parameters:
  ///   - manager: The lifecycle manager to delegate profile reads and refreshes
  ///     to. Its profile, config path and realm are reported by this signer.
  ///   - logger: Logger for diagnostics. Token material is never logged.
  public init(manager: SessionTokenManager, logger: Logger = Logger(label: "SessionTokenSigner")) {
    self.manager = manager
    self.configFilePath = manager.configFilePath
    self.profile = manager.profile
    self.realmDomainComponent = manager.realmDomainComponent
    self.logger = logger
  }

  // MARK: Signer

  /// Signs `req` with the profile's session token, re-obtaining material inline
  /// when the cache is empty or past its half-life.
  ///
  /// Deliberately `nonisolated`, so that only the credential snapshot is
  /// actor-isolated and the signing work — an RSA signature plus, for
  /// `post`/`put`/`patch`, a SHA-256 over the entire request body — provably
  /// stays off this actor's executor. A multi-MB `putObject` therefore never
  /// serializes other requests sharing the signer, and never delays a concurrent
  /// session refresh.
  ///
  /// Today an isolated `sign` would behave the same, because
  /// ``SecurityTokenSigner/sign(_:)`` is a `nonisolated async` function and
  /// SE-0338 runs those on the generic executor rather than the caller's actor.
  /// That guarantee inverts under SE-0461 (`NonisolatedNonsendingByDefault`, the
  /// Swift 7 default), where a `nonisolated async` callee inherits the caller's
  /// isolation — an isolated `sign` would then hash bodies on the actor.
  /// Splitting the snapshot out keeps the property under both rules.
  public nonisolated func sign(_ req: inout URLRequest) async throws {
    let (token, privateKey) = try await credentials()
    try await SecurityTokenSigner(securityToken: token, privateKey: privateKey).sign(&req)
  }

  /// Returns a currently-fresh token + private-key pair, re-obtaining material
  /// inline when the cache is empty or past its half-life. Isolated, so the two
  /// values are snapshotted together and always belong to the same session.
  private func credentials() async throws -> (String, _RSA.Signing.PrivateKey) {
    // A successful refresh normally leaves `material` set, but it is not enough to
    // check once: `forceRefresh()` clears the cache synchronously, so a `401` on a
    // sibling request can empty it in the window between the exchange this call
    // awaited completing and this call being resumed. Refreshing again is the right
    // answer — the alternative is failing a perfectly good request with
    // `notPrimed`. Bounded, so a pathological 401 storm cannot spin here forever.
    for _ in 0..<maximumRefreshAttempts {
      try await refreshIfNeeded()
      if let material { return (material.container.token, material.privateKey) }
    }
    throw SessionTokenSignerError.notPrimed
  }

  /// How many times ``credentials()`` re-refreshes when a concurrent
  /// ``forceRefresh()`` keeps invalidating the cache underneath it.
  private let maximumRefreshAttempts = 4

  // MARK: Refresh

  /// Re-obtains material only if the cache is empty or past its half-life.
  ///
  /// Long-running servers can call this at the start of a logical operation to
  /// warm the session ahead of a latency-sensitive request; ``sign(_:)`` calls it
  /// anyway.
  ///
  /// - Throws: ``SessionTokenError/sessionExpired(expiredAt:)`` or
  ///   ``SessionTokenError/refreshRejected`` when the session is over, and
  ///   ``ConfigErrors`` when the profile cannot be read.
  public func refreshIfNeeded() async throws {
    if let material, material.isFresh(now: Date()) { return }
    try await refresh()
  }

  /// Re-obtains material: re-reads the profile from disk and adopts the on-disk
  /// session when it is still fresh, otherwise performs the refresh exchange and
  /// writes the new token back to `security_token_file`.
  ///
  /// Concurrent callers coalesce onto one in-flight exchange.
  ///
  /// - Throws: ``SessionTokenError/sessionExpired(expiredAt:)`` or
  ///   ``SessionTokenError/refreshRejected`` when the session is over, and
  ///   ``ConfigErrors`` when the profile cannot be read.
  public func refresh() async throws {
    if let running = exchange.running {
      try await running.value
      return
    }
    try await startExchange(kind: .routine)
  }

  /// Drops the cache and re-obtains material so the next ``sign(_:)`` uses a
  /// different token. Called by ``HTTPClient/send(_:signer:retry:logger:)`` after
  /// a `401`; because it is `async`, the caller's immediate retry re-signs with
  /// the recovered token.
  ///
  /// The rejected token is recorded on the actor (see ``rejectedToken``) until
  /// material that is not it has been obtained, so *no* exchange — this one, one
  /// running concurrently, or one that follows a failure — can hand back the very
  /// token the service just refused, even while that token still looks locally
  /// fresh. A session the service considers over therefore surfaces as
  /// ``SessionTokenError/refreshRejected`` instead of being signed with again.
  public func forceRefresh() async throws {
    if let rejected = material?.container.token { rejectedToken = rejected }
    material = nil  // invalidate any concurrently-observed cached session
    // Deliberately refuses to join an exchange that began *before* this call. Such
    // an exchange read its credential material before the `401`, so it can only
    // hand back what the service just rejected — and the retry, which gets only
    // one shot, would re-sign with it and fail again. Concurrent `forceRefresh()`
    // calls still coalesce onto one post-`401` exchange, so a session that expired
    // under N in-flight requests triggers one refresh, not N.
    let startedBefore = exchange.started
    while true {
      // Joinable when the running exchange read its material after a `401` (it is
      // itself forced, i.e. part of this same rejection wave) or simply began after
      // this call — and in both cases its result cannot be the rejected token,
      // because every exchange honours ``rejectedToken``.
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

  /// Starts a new exchange and awaits it. The caller must have established that
  /// nothing acceptable is already in flight.
  private func startExchange(kind: SingleFlightExchange.Kind) async throws {
    let task = Task { try await self.performRefresh() }
    exchange.begin(task, kind: kind)
    try await task.value
  }

  /// Obtains fresh material and caches it, never adopting ``rejectedToken``.
  private func performRefresh() async throws {
    // Marks the exchange finished on both success and failure. Runs as this
    // actor-isolated body returns — strictly before any `await task.value`
    // awaiter is resumed — so a caller waiting an exchange out always observes it
    // as finished when it wakes, and cannot spin.
    defer { exchange.finish() }

    // 1. Re-read the profile on every refresh, so a session refreshed out of band
    //    — or replaced outright by a new `oci session authenticate`, which rotates
    //    the keypair too — is picked up. This is the step a snapshotting
    //    ``SecurityTokenSigner`` never performs.
    let state = try manager.profileState()
    let onDisk = try SecurityTokenContainer(token: state.token)

    // 2. Prefer the on-disk session when it is still within its half-life: some
    //    other process (or `oci session refresh`) may already have done the work,
    //    and then there is nothing to ask the service for.
    if onDisk.token != rejectedToken, onDisk.isValidWithinHalfExpiration() {
      adopt(Material(container: onDisk, privateKey: state.privateKey))
      logger.debug("Session \(profile): adopted the on-disk token (valid until \(onDisk.expiresAt))")
      return
    }

    // 3. Otherwise extend the session over the wire. The manager writes the new
    //    token back to `security_token_file`, so the next process to read the
    //    profile — including the CLI — sees it. A session that is over throws
    //    (`sessionExpired` / `refreshRejected`) and is propagated: only an
    //    interactive `oci session authenticate` can recover from it, so the cache
    //    is deliberately left empty rather than filled with a dead token.
    // Refreshed against the profile read in step 1, not a second read of it: the
    // exchange re-binds the *same* public key, so pairing the new token with
    // `state.privateKey` is correct precisely because both come from one read. A
    // second read could be a rotated keypair (an out-of-band
    // `oci session authenticate`), which would bind the token to a key this cache
    // does not hold.
    //
    // `minimumRemaining: 0` opts out of the manager's "too close to expiry to be
    // worth a round trip" gate, which is the right default for a one-shot
    // `refresh()` but the wrong one here: this signer's alternative to a long-shot
    // exchange is failing a caller's request outright and demanding an interactive
    // re-authentication. When the session is alive at all, it is worth asking.
    let refreshed = try await manager.refresh(using: state, minimumRemaining: 0)
    adopt(Material(container: refreshed, privateKey: state.privateKey))
    logger.debug("Session \(profile): refreshed over the wire (valid until \(refreshed.expiresAt))")
  }

  /// Caches `material` and clears any recorded rejection, since the newly-obtained
  /// token is by construction not the rejected one.
  private func adopt(_ material: Material) {
    self.material = material
    if material.container.token != rejectedToken { rejectedToken = nil }
  }

  // MARK: Profile access

  /// The region id recorded in the profile (e.g. `us-phoenix-1`), so a caller can
  /// build a service client without parsing the config file itself.
  ///
  /// Read from disk on each call rather than cached, since the profile is shared
  /// with the CLI.
  ///
  /// - Throws: ``ConfigErrors`` when the profile cannot be read, and
  ///   ``ConfigErrors/missingRegion`` when it carries no `region`.
  public func regionId() throws -> String {
    try manager.profileState().region
  }
}
