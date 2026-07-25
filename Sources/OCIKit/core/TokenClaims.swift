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

/// Minimal reader for the JWT claims the token-based signers need.
///
/// The security tokens handled by ``InstancePrincipalSigner``,
/// ``OKEWorkloadIdentitySigner`` and ``ResourcePrincipalSigner`` are all signed
/// JWTs, but — exactly like the Python SDK — the SDK only reads the `iat`/`exp`
/// claims and never verifies the signature (reading claims requires no key).
///
/// Shared by all three signers so that a fix to the claim parsing lands once
/// rather than in three near-identical copies.
enum TokenClaims {
  /// Returns the `(iat, exp)` claims in epoch seconds. Either is `nil` when the
  /// claim is absent or the token is not a parseable JWT (e.g. an opaque token).
  static func issuedAndExpiry(of token: String) -> (issuedAt: Int?, expiry: Int?) {
    guard let claims = payload(of: token) else { return (nil, nil) }
    return (intClaim(claims["iat"]), intClaim(claims["exp"]))
  }

  /// Returns the `exp` claim in epoch seconds, or `nil` if absent/unparseable.
  static func expiry(of token: String) -> Int? {
    guard let claims = payload(of: token) else { return nil }
    return intClaim(claims["exp"])
  }

  /// Whether `token` carries an `exp` claim that is still in the future. A token
  /// with no readable `exp` is treated as expired.
  static func isUnexpired(_ token: String, now: Int) -> Bool {
    guard let exp = expiry(of: token) else { return false }
    return now < exp
  }

  /// Decodes a base64url segment (base64url alphabet, padding optional — JWT
  /// segments are unpadded).
  static func base64URLDecode(_ string: String) -> Data? {
    var base64 =
      string
      .replacing("-", with: "+")
      .replacing("_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 {
      base64 += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: base64)
  }

  /// Decodes the JWT payload segment into its claim dictionary.
  private static func payload(of token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2,
      let data = base64URLDecode(String(parts[1])),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return nil
    }
    return object
  }

  /// Reads an integer claim that may be encoded as either `Int` or `Double`.
  ///
  /// The `Double` conversion is range-guarded on purpose. `JSONSerialization`
  /// bridges a numeric claim too large for `Int` — `{"exp":1e30}` — to an
  /// `NSNumber` that fails `as? Int` but succeeds `as? Double`, and the plain
  /// `Int(_:)` initializer *traps* on a value outside `Int`'s range. That is an
  /// uncatchable process abort reached from attacker-influencable input: a
  /// resource principal's token arrives via `OCI_RESOURCE_PRINCIPAL_RPST`, an
  /// environment variable or file rather than a TLS-protected response.
  /// `Int(exactly:)` returns `nil` instead, and also rejects NaN and infinity.
  private static func intClaim(_ value: Any?) -> Int? {
    if let intValue = value as? Int { return intValue }
    // `rounded(.towardZero)` preserves the truncating behaviour of `Int(_:)` for
    // in-range fractional claims, which `Int(exactly:)` alone would reject.
    if let doubleValue = value as? Double { return Int(exactly: doubleValue.rounded(.towardZero)) }
    return nil
  }
}
