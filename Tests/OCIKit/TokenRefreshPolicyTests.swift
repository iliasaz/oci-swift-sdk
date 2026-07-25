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
// Credential-free unit tests for the staleness rules shared by the token-based
// signers (`TokenRefreshPolicy`) and the JWT claim reader they share
// (`TokenClaims`). Both were previously duplicated per signer; these tests pin
// the single implementation.
//

import Foundation
import Testing

@testable import OCIKit

// MARK: - Helpers

/// Base64url-encodes without padding (JWT segment encoding).
private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacing("+", with: "-")
    .replacing("/", with: "_")
    .replacing("=", with: "")
}

/// Builds an unsigned-but-well-formed JWT whose payload carries `claims`.
private func makeJWT(claims: [String: Any]) -> String {
  let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
  let payload = try! JSONSerialization.data(withJSONObject: claims)
  return "\(base64URL(header)).\(base64URL(payload)).c2ln"
}

/// Builds a JWT whose payload is the given raw JSON, so a test can express numeric
/// literals (`1e30`) that `JSONSerialization` would not round-trip from a Swift value.
private func makeJWT(claimsJSON: String) -> String {
  let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
  return "\(base64URL(header)).\(base64URL(Data(claimsJSON.utf8))).c2ln"
}

// MARK: - Half-life rule

struct TokenRefreshPolicyTests {
  @Test("a token before the iat/exp midpoint is fresh, and stale from the midpoint on")
  func halfLife() {
    // Validity window 1000...2000, so the midpoint is 1500.
    let fresh = TokenRefreshPolicy.isFreshAtHalfLife(
      issuedAt: 1000,
      expiry: 2000,
      obtainedAt: 1000,
      now: 1499
    )
    let atMidpoint = TokenRefreshPolicy.isFreshAtHalfLife(
      issuedAt: 1000,
      expiry: 2000,
      obtainedAt: 1000,
      now: 1500
    )
    let past = TokenRefreshPolicy.isFreshAtHalfLife(
      issuedAt: 1000,
      expiry: 2000,
      obtainedAt: 1000,
      now: 1700
    )
    #expect(fresh)
    #expect(!atMidpoint)
    #expect(!past)
  }

  @Test("with no iat claim the half-life rule falls back to the fixed jitter before exp")
  func fallbackJitter() {
    let jitter = TokenRefreshPolicy.fallbackJitterSeconds
    let before = TokenRefreshPolicy.isFreshAtHalfLife(
      issuedAt: nil,
      expiry: 2000,
      obtainedAt: 1000,
      now: 2000 - jitter - 1
    )
    let atThreshold = TokenRefreshPolicy.isFreshAtHalfLife(
      issuedAt: nil,
      expiry: 2000,
      obtainedAt: 1000,
      now: 2000 - jitter
    )
    #expect(before)
    #expect(!atThreshold)
  }

  @Test("a non-monotonic iat/exp pair falls back to the jitter rule rather than going backwards")
  func degenerateWindow() {
    let jitter = TokenRefreshPolicy.fallbackJitterSeconds
    // exp <= iat: the midpoint would be meaningless, so the jitter rule applies.
    #expect(
      TokenRefreshPolicy.isFreshAtHalfLife(
        issuedAt: 3000,
        expiry: 2000,
        obtainedAt: 1000,
        now: 2000 - jitter - 1
      )
    )
    #expect(
      !TokenRefreshPolicy.isFreshAtHalfLife(
        issuedAt: 3000,
        expiry: 2000,
        obtainedAt: 1000,
        now: 2000 - jitter
      )
    )
  }

  // MARK: No-exp TTL

  @Test("a token with no exp claim is trusted for the TTL, not forever")
  func noExpiryIsBounded() {
    let ttl = TokenRefreshPolicy.noExpiryTTLSeconds
    let obtainedAt = 1000
    #expect(
      TokenRefreshPolicy.isFreshAtHalfLife(
        issuedAt: nil,
        expiry: nil,
        obtainedAt: obtainedAt,
        now: obtainedAt
      )
    )
    #expect(
      TokenRefreshPolicy.isFreshAtHalfLife(
        issuedAt: nil,
        expiry: nil,
        obtainedAt: obtainedAt,
        now: obtainedAt + ttl - 1
      )
    )
    // The regression this guards: previously "no exp" meant "cached forever".
    #expect(
      !TokenRefreshPolicy.isFreshAtHalfLife(
        issuedAt: nil,
        expiry: nil,
        obtainedAt: obtainedAt,
        now: obtainedAt + ttl
      )
    )
    #expect(
      !TokenRefreshPolicy.isFreshAtHalfLife(
        issuedAt: nil,
        expiry: nil,
        obtainedAt: obtainedAt,
        now: obtainedAt + ttl + 86_400
      )
    )
  }

  @Test("the jitter rule also bounds a token that carries no exp claim")
  func noExpiryIsBoundedUnderJitterRule() {
    let ttl = TokenRefreshPolicy.noExpiryTTLSeconds
    let obtainedAt = 1000
    #expect(
      TokenRefreshPolicy.isFreshWithinJitter(
        expiry: nil,
        obtainedAt: obtainedAt,
        now: obtainedAt + ttl - 1
      )
    )
    #expect(
      !TokenRefreshPolicy.isFreshWithinJitter(
        expiry: nil,
        obtainedAt: obtainedAt,
        now: obtainedAt + ttl
      )
    )
  }

  // MARK: Jitter rule

  @Test("the jitter rule treats a token as stale once it is within the jitter of exp")
  func jitterRule() {
    let jitter = TokenRefreshPolicy.fallbackJitterSeconds
    #expect(TokenRefreshPolicy.isFreshWithinJitter(expiry: 2000, obtainedAt: 1000, now: 2000 - jitter - 1))
    // Boundary is inclusive here, preserving the resource-principal behaviour.
    #expect(TokenRefreshPolicy.isFreshWithinJitter(expiry: 2000, obtainedAt: 1000, now: 2000 - jitter))
    #expect(!TokenRefreshPolicy.isFreshWithinJitter(expiry: 2000, obtainedAt: 1000, now: 2000 - jitter + 1))
    #expect(!TokenRefreshPolicy.isFreshWithinJitter(expiry: 2000, obtainedAt: 1000, now: 2100))
  }
}

// MARK: - Shared claim reader

struct TokenClaimsTests {
  @Test("issuedAndExpiry reads the iat and exp claims from a JWT payload")
  func readsClaims() {
    let claims = TokenClaims.issuedAndExpiry(of: makeJWT(claims: ["iat": 1000, "exp": 2000]))
    #expect(claims.issuedAt == 1000)
    #expect(claims.expiry == 2000)
  }

  @Test("claims encoded as JSON numbers with a fractional part are truncated to Int")
  func readsDoubleClaims() {
    let claims = TokenClaims.issuedAndExpiry(of: makeJWT(claims: ["iat": 1000.9, "exp": 2000.4]))
    #expect(claims.issuedAt == 1000)
    #expect(claims.expiry == 2000)
  }

  @Test("an opaque, non-JWT token yields nil claims rather than throwing")
  func opaqueToken() {
    let claims = TokenClaims.issuedAndExpiry(of: "not-a-jwt")
    #expect(claims.issuedAt == nil)
    #expect(claims.expiry == nil)
    #expect(TokenClaims.expiry(of: "not-a-jwt") == nil)
  }

  @Test("a JWT with no iat/exp claims yields nil for both")
  func missingClaims() {
    let claims = TokenClaims.issuedAndExpiry(of: makeJWT(claims: ["sub": "x"]))
    #expect(claims.issuedAt == nil)
    #expect(claims.expiry == nil)
  }

  @Test("isUnexpired compares exp against now and treats an unreadable exp as expired")
  func isUnexpired() {
    let now = 1000
    #expect(TokenClaims.isUnexpired(makeJWT(claims: ["exp": now + 60]), now: now))
    #expect(!TokenClaims.isUnexpired(makeJWT(claims: ["exp": now - 60]), now: now))
    #expect(!TokenClaims.isUnexpired(makeJWT(claims: ["sub": "x"]), now: now))
    #expect(!TokenClaims.isUnexpired("not-a-jwt", now: now))
  }

  @Test("base64URLDecode handles the base64url alphabet and absent padding")
  func base64URLDecoding() throws {
    // "sure." padded to a length needing 2 '=' characters when re-padded.
    let decoded = try #require(TokenClaims.base64URLDecode(base64URL(Data("sure.".utf8))))
    #expect(String(decoding: decoded, as: UTF8.self) == "sure.")
    // '-' and '_' map to '+' and '/'.
    let bytes = Data([0xFB, 0xFF, 0xBE])
    let roundTripped = try #require(TokenClaims.base64URLDecode(base64URL(bytes)))
    #expect(roundTripped == bytes)
    #expect(TokenClaims.base64URLDecode("!!!not base64!!!") == nil)
  }
}

// MARK: - Out-of-range numeric claims

/// `JSONSerialization` bridges a numeric claim too large for `Int` to an
/// `NSNumber` that fails `as? Int` but succeeds `as? Double`. The plain `Int(_:)`
/// initializer *traps* on such a value — an uncatchable process abort reached from
/// token text, which for resource principals arrives via an environment variable.
struct TokenClaimsRangeTests {
  @Test("a numeric claim beyond Int's range yields nil instead of trapping")
  func outOfRangeClaimsAreRejected() {
    // These parse as a JSON document on both Foundation implementations; only the
    // claim itself is out of `Int` range. Literals that overflow `Double` are
    // excluded on purpose — they are platform-divergent: macOS Foundation reads
    // `-1e400` as `-infinity` while swift-corelibs-foundation rejects the whole
    // document. Either way no claim is produced, which the opaque-token tests
    // already cover; pinning it here would just make the suite Linux-fragile.
    for literal in ["1e30", "-1e30", "9223372036854775808"] {
      let token = makeJWT(claimsJSON: #"{"iat":1000,"exp":\#(literal)}"#)
      let claims = TokenClaims.issuedAndExpiry(of: token)
      #expect(claims.expiry == nil, "exp \(literal) should be unreadable, not fatal")
      #expect(claims.issuedAt == 1000, "a sibling claim stays readable")
      // The staleness rules must still be usable on such a token.
      #expect(
        TokenRefreshPolicy.isFreshAtHalfLife(
          issuedAt: claims.issuedAt,
          expiry: claims.expiry,
          obtainedAt: 1000,
          now: 1001
        )
      )
    }
  }

  @Test("in-range fractional claims keep truncating toward zero")
  func inRangeFractionalClaimsTruncate() {
    let claims = TokenClaims.issuedAndExpiry(of: makeJWT(claimsJSON: #"{"iat":1000.9,"exp":2000.9}"#))
    #expect(claims.issuedAt == 1000)
    #expect(claims.expiry == 2000)
  }
}
