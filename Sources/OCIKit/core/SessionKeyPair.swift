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
// The ephemeral RSA keypair a user session is bound to. Mirrors the key handling
// in the OCI CLI's `oci session authenticate` (`cli_util.generate_key`,
// `cli_util.serialize_key`, `cli_setup.public_key_to_fingerprint`) — the parts
// that belong in an SDK, i.e. everything except the interactive browser flow.
//

import Crypto
import Foundation
import RegexBuilder
import _CryptoExtras

/// An RSA keypair whose public half is handed to the Auth Service when a user
/// session token (UPST) is requested, and whose private half signs every request
/// made with the resulting token.
///
/// ## Example
/// ```swift
/// let keyPair = try SessionKeyPair.generate()
/// let token = try await client.generateUserSecurityToken(
///   publicKeyPEM: keyPair.publicKeyPEM,
///   signer: apiKeySigner
/// )
/// let sessionSigner = SecurityTokenSigner(securityToken: token, privateKey: keyPair.privateKey)
/// ```
public struct SessionKeyPair: Sendable {
  /// The private half. Signs service requests under keyId `ST$<token>`.
  public let privateKey: _RSA.Signing.PrivateKey

  /// The public half, which the Auth Service binds the issued token to.
  public var publicKey: _RSA.Signing.PublicKey { privateKey.publicKey }

  /// PKCS#8 PEM of the private key — the `key_file` contents of a session profile.
  public var privateKeyPEM: String { privateKey.pemRepresentation }

  /// SubjectPublicKeyInfo PEM of the public key — the `publicKey` field of a
  /// `GenerateUpst` request body, sent complete with its PEM header and footer
  /// (unlike the X.509 federation flow, which sends a stripped blob).
  public var publicKeyPEM: String { publicKey.pemRepresentation }

  /// The OCI fingerprint of the public key: the colon-separated lowercase MD5 of
  /// the SubjectPublicKeyInfo DER, e.g. `aa:bb:…`. This is the value written as
  /// `fingerprint` into the config profile.
  public var fingerprint: String {
    // The PEM body is base64 of exactly the DER bytes the CLI hashes, so this
    // cannot fail for a key we just serialized ourselves.
    (try? Self.fingerprint(forPublicKeyPEM: publicKeyPEM)) ?? ""
  }

  /// Wraps an existing private key — e.g. one read back from a session's
  /// `key_file` — so the same fingerprint/PEM helpers apply to it.
  public init(privateKey: _RSA.Signing.PrivateKey) {
    self.privateKey = privateKey
  }

  /// Generates a fresh RSA-2048 session keypair.
  ///
  /// - Throws: ``SessionTokenError/keyGenerationFailed`` when the key could not
  ///   be generated.
  public static func generate() throws -> SessionKeyPair {
    guard let key = try? _RSA.Signing.PrivateKey(keySize: .bits2048) else {
      throw SessionTokenError.keyGenerationFailed
    }
    return SessionKeyPair(privateKey: key)
  }

  /// Computes the OCI fingerprint of a SubjectPublicKeyInfo PEM: colon-separated
  /// lowercase MD5 over the DER the PEM encodes.
  ///
  /// Derived from the PEM body rather than a DER accessor so that a key parsed
  /// from a file and a key generated in-process fingerprint through exactly the
  /// same bytes — the same thing the CLI's `public_key_to_fingerprint` does.
  ///
  /// - Throws: ``SessionTokenError/malformedToken(_:)`` is *not* used here;
  ///   a PEM whose body is not base64 raises
  ///   ``SessionTokenError/persistenceFailed(path:detail:)`` with an empty path,
  ///   since the only way to reach it is a corrupt key file.
  public static func fingerprint(forPublicKeyPEM pem: String) throws -> String {
    let body =
      pem
      .replacing("-----BEGIN PUBLIC KEY-----", with: "")
      .replacing("-----END PUBLIC KEY-----", with: "")
      // Matches any newline *sequence*: `replacing(_:with:)` is grapheme-based,
      // so a plain "\n" never matches inside a CRLF cluster and a CRLF-wrapped
      // PEM would survive unchanged.
      .replacing(CharacterClass.newlineSequence, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let der = Data(base64Encoded: body) else {
      throw SessionTokenError.persistenceFailed(path: "", detail: "the public key PEM body is not valid base64")
    }
    let hex = der.md5hex
    return stride(from: 0, to: hex.count, by: 2)
      .map { offset -> String in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        let end = hex.index(start, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        return String(hex[start..<end])
      }
      .joined(separator: ":")
  }
}
