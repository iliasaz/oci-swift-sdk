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

import Foundation

/// Decides when a cached security token has gone stale.
///
/// Shared by the token-based signers so the policy — and any fix to it — lives in
/// one place instead of being copied per signer. Two rules are in use:
///
/// * **Half-life** (``isFreshAtHalfLife(issuedAt:expiry:obtainedAt:now:)``), for
///   tokens the SDK negotiates over the network (``InstancePrincipalSigner``,
///   ``OKEWorkloadIdentitySigner``). Refreshing at the midpoint of the validity
///   window leaves a full half-life of slack to retry a failed exchange before
///   the cached token actually expires.
/// * **Expiry jitter** (``isFreshWithinJitter(expiry:obtainedAt:now:)``), for
///   tokens injected by the hosting service (``ResourcePrincipalSigner``), where
///   a "refresh" is only a cheap re-read of an environment variable or file and
///   there is no exchange to leave slack for.
enum TokenRefreshPolicy {
  /// Seconds before `exp` at which a token is treated as stale when there is no
  /// `iat` claim to compute a half-life from.
  static let fallbackJitterSeconds = 60

  /// How long a token carrying **no** readable `exp` claim is trusted, measured
  /// from the moment it was obtained.
  ///
  /// The Auth Service returns JWTs today, so this is a safety net rather than a
  /// live code path. Trusting an unreadable `exp` indefinitely would mean an
  /// opaque token is never proactively refreshed, so every request past the real
  /// expiry would pay a 401-then-retry; a conservative TTL bounds that instead.
  static let noExpiryTTLSeconds = 900  // 15 minutes

  /// Whether a token is still fresh under the half-life rule.
  ///
  /// - Parameters:
  ///   - issuedAt: The `iat` claim, if readable.
  ///   - expiry: The `exp` claim, if readable.
  ///   - obtainedAt: When the SDK obtained the token (epoch seconds). Used only
  ///     when `expiry` is `nil`, since an opaque token carries no timestamps.
  ///   - now: The current time in epoch seconds.
  static func isFreshAtHalfLife(issuedAt: Int?, expiry: Int?, obtainedAt: Int, now: Int) -> Bool {
    guard let expiry else { return now < obtainedAt + noExpiryTTLSeconds }
    let threshold: Int
    if let issuedAt, expiry > issuedAt {
      threshold = expiry - (expiry - issuedAt) / 2  // midpoint of the validity window
    }
    else {
      threshold = expiry - fallbackJitterSeconds
    }
    return now < threshold
  }

  /// Whether a token is still fresh under the expiry-jitter rule.
  ///
  /// - Parameters:
  ///   - expiry: The `exp` claim, if readable.
  ///   - obtainedAt: When the SDK loaded the token (epoch seconds). Used only
  ///     when `expiry` is `nil`.
  ///   - now: The current time in epoch seconds.
  static func isFreshWithinJitter(expiry: Int?, obtainedAt: Int, now: Int) -> Bool {
    guard let expiry else { return now < obtainedAt + noExpiryTTLSeconds }
    return now <= expiry - fallbackJitterSeconds
  }
}
