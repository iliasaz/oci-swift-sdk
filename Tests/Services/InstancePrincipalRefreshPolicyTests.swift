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
// Credential-free tests for the *wiring* between `InstancePrincipalSigner` and
// `TokenRefreshPolicy`: that the signer really consults the half-life rule before
// reusing a cached security token, re-federates when the rule says the token has
// gone stale, and then signs with the token that exchange returned.
//
// The arithmetic itself — the `iat`/`exp` midpoint, the fixed jitter fallback for
// a token with no `iat`, the TTL for a token with no `exp` — is pinned by
// `TokenRefreshPolicyTests` in `Tests/OCIKit`, and is deliberately not repeated
// here. These drive the whole signer against the in-memory IMDS + federation fake
// instead (see `InstancePrincipalTestSupport.swift`), seeding tokens with chosen
// claims and counting federation exchanges — so a signer that stopped calling the
// policy, or called it with the wrong arguments, fails here even though the
// policy's own tests keep passing.
//

import Foundation
import Testing

@testable import OCIKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Signer-level coverage of the half-life refresh rule.
///
/// Every token is minted relative to the wall clock the signer reads
/// (`Int(Date().timeIntervalSince1970)`), with margins of minutes on either side
/// of each threshold, so the few milliseconds a test spends generating RSA keys
/// cannot flip a verdict.
struct InstancePrincipalRefreshPolicyTests {
  /// The clock `refreshIfNeeded()` reads, in epoch seconds.
  private var epochNow: Int { Int(Date().timeIntervalSince1970) }

  /// Signs a throwaway request with `signer` and returns its `Authorization`
  /// header, which carries `keyId="ST$<token>"` — i.e. exactly which cached token
  /// the signer used.
  private func authorization(from signer: InstancePrincipalSigner) async throws -> String {
    var req = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
    req.httpMethod = "GET"
    try await signer.sign(&req)
    return try #require(req.value(forHTTPHeaderField: "Authorization"))
  }

  // MARK: - Half-life rule

  @Test("a token well inside its half-life is reused, so a second sign() does not re-federate")
  func freshTokenIsReusedAcrossSigns() async throws {
    let now = epochNow
    // Window now-10 ... now+3600, so the midpoint is roughly now+1795.
    let token = makeToken(issuedAt: now - 10, expiry: now + 3600, marker: "fresh")
    let (service, _) = try makeFakeService(token: token)
    let signer = makeSigner(service: service)

    let first = try await authorization(from: signer)
    let second = try await authorization(from: signer)

    // One exchange for both signatures: the first sign() self-primed, the second
    // found the cached token still inside its half-life.
    #expect(service.federationCount == 1)
    #expect(first.contains("keyId=\"ST$\(token)\""))
    #expect(second.contains("keyId=\"ST$\(token)\""))
  }

  @Test("a token past its iat/exp midpoint is re-federated, and the new token is the one signed with")
  func staleTokenIsReFederatedAndAdopted() async throws {
    let now = epochNow
    let staleExpiry = now + 600
    // Window now-3000 ... now+600, so the half-life threshold is around now-1200:
    // ten minutes of validity left, but well past the midpoint.
    let stale = makeToken(issuedAt: now - 3000, expiry: staleExpiry, marker: "stale")
    // Premise for the discrimination: this same token is still *fresh* under the
    // jitter rule (now <= exp - 60) and is not expired either, so re-federating
    // can only mean the signer applied the half-life rule specifically.
    #expect(TokenRefreshPolicy.isFreshWithinJitter(expiry: staleExpiry, obtainedAt: now, now: now))
    #expect(TokenClaims.isUnexpired(stale, now: now))

    let (service, _) = try makeFakeService(token: stale)
    let signer = makeSigner(service: service)

    let first = try await authorization(from: signer)
    #expect(service.federationCount == 1)
    #expect(first.contains("keyId=\"ST$\(stale)\""))

    // The Auth Service now hands out a token that is inside its own half-life.
    let renewed = makeToken(issuedAt: now - 10, expiry: now + 3600, marker: "renewed")
    service.setToken(renewed)

    // Past its midpoint, so this sign() must run a second exchange — and must sign
    // with the token that exchange returned, not the one it replaced.
    let second = try await authorization(from: signer)
    #expect(service.federationCount == 2)
    #expect(second.contains("keyId=\"ST$\(renewed)\""))

    // The staleness bound is recomputed from the *new* token's claims: the renewed
    // token is fresh, so a third sign() reuses it rather than federating again.
    let third = try await authorization(from: signer)
    #expect(service.federationCount == 2)
    #expect(third.contains("keyId=\"ST$\(renewed)\""))
  }

  // MARK: - Jitter fallback (no iat claim)

  @Test("a token with no iat is reused while it is further from exp than the jitter")
  func tokenWithoutIssuedAtIsReusedOutsideTheJitter() async throws {
    let now = epochNow
    let jitter = TokenRefreshPolicy.fallbackJitterSeconds
    let token = makeToken(issuedAt: nil, expiry: now + jitter + 600, marker: "no-iat-fresh")
    let (service, _) = try makeFakeService(token: token)
    let signer = makeSigner(service: service)

    let first = try await authorization(from: signer)
    let second = try await authorization(from: signer)

    // With no `iat` there is no midpoint to compute, so the fixed jitter before
    // `exp` decides — and this token is ten minutes clear of it.
    #expect(service.federationCount == 1)
    #expect(first.contains("keyId=\"ST$\(token)\""))
    #expect(second.contains("keyId=\"ST$\(token)\""))
  }

  @Test("a token with no iat is re-federated once it is within the jitter of exp")
  func tokenWithoutIssuedAtIsRefreshedInsideTheJitter() async throws {
    let now = epochNow
    let jitter = TokenRefreshPolicy.fallbackJitterSeconds
    let expiry = now + jitter - 30
    let token = makeToken(issuedAt: nil, expiry: expiry, marker: "no-iat-stale")
    // Not expired — it still has half a minute of life — so a signer that only
    // checked for expiry would happily keep using it.
    #expect(TokenClaims.isUnexpired(token, now: now))

    let (service, _) = try makeFakeService(token: token)
    let signer = makeSigner(service: service)

    _ = try await authorization(from: signer)
    #expect(service.federationCount == 1)

    _ = try await authorization(from: signer)
    #expect(service.federationCount == 2)
  }

  // MARK: - No-expiry TTL fallback (iat present, exp absent)

  @Test("a JWT carrying iat but no exp is cached under the no-expiry TTL, not re-federated per sign")
  func tokenWithIssuedAtButNoExpiryIsCached() async throws {
    let now = epochNow
    // An `iat` on its own gives the policy no window to halve, so the no-`exp`
    // TTL — measured from when the token was obtained — is what keeps it cached.
    // Deliberately distinct from the opaque-token path in
    // `InstancePrincipalOpaqueTokenTests`: there *both* claims come back nil,
    // whereas here the claim reader returns an `iat`, so a signer that folded
    // that value into its cached `expiry` would compute a threshold in the past
    // and re-federate on every sign() while every other suite stayed green.
    let token = makeToken(issuedAt: now - 10, expiry: nil, marker: "no-exp")
    let claims = TokenClaims.issuedAndExpiry(of: token)
    #expect(claims.issuedAt == now - 10)
    #expect(claims.expiry == nil)

    let (service, _) = try makeFakeService(token: token)
    let signer = makeSigner(service: service)

    for _ in 0..<3 {
      #expect(try await authorization(from: signer).contains("keyId=\"ST$\(token)\""))
    }

    // Well inside `TokenRefreshPolicy.noExpiryTTLSeconds`, so one exchange serves
    // all three signatures.
    #expect(service.federationCount == 1)
  }

  // MARK: - Which entry points consult the policy

  @Test("refreshIfNeeded() skips the exchange for a fresh token and performs one for a stale token")
  func refreshIfNeededConsultsThePolicy() async throws {
    let now = epochNow

    let freshToken = makeToken(issuedAt: now - 10, expiry: now + 3600, marker: "fresh")
    let (freshService, _) = try makeFakeService(token: freshToken)
    let freshSigner = makeSigner(service: freshService)
    try await freshSigner.refresh()  // prime: exchange #1
    try await freshSigner.refreshIfNeeded()  // still inside the half-life: no exchange
    #expect(freshService.federationCount == 1)

    let staleToken = makeToken(issuedAt: now - 3000, expiry: now + 600, marker: "stale")
    let (staleService, _) = try makeFakeService(token: staleToken)
    let staleSigner = makeSigner(service: staleService)
    try await staleSigner.refresh()  // prime: exchange #1
    try await staleSigner.refreshIfNeeded()  // past the midpoint: exchange #2
    #expect(staleService.federationCount == 2)
  }

  @Test("refresh() federates unconditionally, even when the cached token is fresh")
  func refreshIgnoresThePolicy() async throws {
    let now = epochNow
    let (service, _) = try makeFakeService(
      token: makeToken(issuedAt: now - 10, expiry: now + 3600, marker: "fresh")
    )
    let signer = makeSigner(service: service)

    try await signer.refresh()
    try await signer.refresh()

    // The half-life rule gates `refreshIfNeeded()`, not `refresh()`: a caller that
    // asks for an exchange outright always gets one.
    #expect(service.federationCount == 2)
  }
}
