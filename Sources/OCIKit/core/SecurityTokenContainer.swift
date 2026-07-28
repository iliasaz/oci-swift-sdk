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
// Mirrors `oci/auth/security_token_container.py` (`SecurityTokenContainer`) from
// the Python SDK: the read-only view of a user session token (UPST) that answers
// "is this still usable?" without contacting the service.
//

import Foundation

/// A parsed OCI **user session token** (UPST) and the validity questions callers
/// ask about it.
///
/// The token is a signed JWT. Exactly like the Python SDK, the signature is
/// never verified here — only the claims are read, which requires no key. The
/// service remains the authority on whether a token is accepted; this type only
/// answers the local question the CLI's `oci session validate --local` answers.
///
/// ## Example
/// ```swift
/// let container = try SecurityTokenContainer(token: tokenString)
/// if !container.isValid() {
///   logger.warning("session expired at \(container.expiresAt)")
/// }
/// ```
public struct SecurityTokenContainer: Sendable, Equatable {
  /// The raw JWT, exactly as read from the `security_token_file` or returned by
  /// the Auth Service.
  public let token: String
  /// The `iat` claim in epoch seconds, when the token carries one.
  public let issuedAt: Int?
  /// The `exp` claim in epoch seconds. Always present — a token without a
  /// readable `exp` fails ``init(token:)``.
  public let expiry: Int
  /// The `sub` claim: the OCID of the user the session belongs to.
  public let subject: String?
  /// The `tenant` claim: the OCID of the tenancy the session belongs to.
  public let tenancyId: String?

  /// The default slack applied by ``isValid(jitterSeconds:now:)``, matching the
  /// Python SDK's `DEFAULT_EXPIRY_JITTER_SECONDS`.
  public static let defaultExpiryJitterSeconds = 60

  /// When the session expires.
  public var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(expiry)) }
  /// When the session was issued, when the token carries an `iat` claim.
  public var issuedAtDate: Date? { issuedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

  /// Parses `token` as a JWT and reads its session claims.
  ///
  /// - Throws: ``SessionTokenError/malformedToken(_:)`` when the string is not a
  ///   parseable JWT or carries no readable `exp` claim. A session token that
  ///   cannot state its own expiry is unusable for every operation this type
  ///   exists to support, so it is rejected up front rather than treated as
  ///   valid forever or silently expired.
  public init(token: String) throws {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw SessionTokenError.malformedToken("the token is empty")
    }
    guard let claims = TokenClaims.payload(of: trimmed) else {
      throw SessionTokenError.malformedToken("the token is not a parseable JWT")
    }
    let (issuedAt, expiry) = TokenClaims.issuedAndExpiry(of: trimmed)
    guard let expiry else {
      throw SessionTokenError.malformedToken("the token carries no readable exp claim")
    }
    self.token = trimmed
    self.issuedAt = issuedAt
    self.expiry = expiry
    self.subject = claims["sub"] as? String
    self.tenancyId = claims["tenant"] as? String
  }

  /// Whether the session has not yet expired.
  ///
  /// Matches the Python SDK's `valid()`: no slack at all, so this answers "is
  /// the token expired *right now*" rather than "is it worth reusing".
  public func isValid(now: Date = Date()) -> Bool {
    Int(now.timeIntervalSince1970) <= expiry
  }

  /// Whether the session is still valid with `jitterSeconds` of slack, to absorb
  /// clock skew and the gap between checking a token and the service receiving
  /// the request signed with it.
  ///
  /// Matches the Python SDK's `valid_with_jitter(jitter:)`.
  public func isValid(jitterSeconds: Int, now: Date = Date()) -> Bool {
    Int(now.timeIntervalSince1970) <= expiry - jitterSeconds
  }

  /// Whether the session is still within the first half of its validity window —
  /// the point at which a long-running process should proactively refresh, so a
  /// failed refresh still has the second half of the window to retry in.
  ///
  /// Matches the Python SDK's `valid_with_half_expiration_time()`. When the token
  /// carries no `iat` claim there is no window to halve, so this falls back to
  /// ``defaultExpiryJitterSeconds`` of slack.
  public func isValidWithinHalfExpiration(now: Date = Date()) -> Bool {
    TokenRefreshPolicy.isFreshAtHalfLife(
      issuedAt: issuedAt,
      expiry: expiry,
      obtainedAt: Int(now.timeIntervalSince1970),
      now: Int(now.timeIntervalSince1970)
    )
  }
}
