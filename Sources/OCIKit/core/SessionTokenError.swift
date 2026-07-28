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

/// Errors raised by the session-token (delegation/UPST) lifecycle:
/// ``SecurityTokenContainer``, ``SessionTokenClient``, ``SessionTokenStore`` and
/// ``SessionTokenManager``.
///
/// Configuration-file problems (a missing profile, `key_file` or
/// `security_token_file` entry, an unparseable key) keep reporting as
/// ``ConfigErrors``, so a caller that already handles those for
/// ``SecurityTokenSigner`` does not need a second error path.
public enum SessionTokenError: Error, LocalizedError, Equatable {
  /// The token is not a parseable JWT, or carries no readable `exp` claim.
  case malformedToken(String)
  /// The session token has expired and can no longer be used or refreshed.
  case sessionExpired(expiredAt: Date)
  /// The session has not expired yet, but so little of its window is left that a
  /// refresh signed with it is not worth attempting — the request would likely
  /// land after `exp`. Carries the slack that was required.
  case sessionTooCloseToExpiry(expiresAt: Date, minimumRemaining: Int)
  /// The Auth Service refused to refresh the token (HTTP `401`) — the user
  /// session itself is over, so a new `authenticate` is required.
  case refreshRejected
  /// The refresh call failed for a reason other than an expired session.
  /// A `status` of `-1` means the request never produced an HTTP response.
  case refreshFailed(status: Int, message: String)
  /// The service returned a success body that carries no `token` field. Carries a
  /// description of the body's *shape* — never its contents, since a success body
  /// on these endpoints is a credential.
  case malformedResponse(String)
  /// The service rejected the token during a remote validation (HTTP `401`).
  case rejectedByService
  /// A remote validation failed for a reason other than rejection.
  case validationFailed(status: Int, message: String)
  /// Generating the user security token (UPST) failed.
  case tokenGenerationFailed(status: Int, message: String)
  /// A region/realm pair did not compose a usable service endpoint.
  case invalidEndpoint(String)
  /// A region or realm value is not a plausible DNS name component, so it was
  /// refused instead of being interpolated into a service host.
  case invalidHostComponent(field: String, value: String)
  /// The requested session duration is outside the range the Auth Service
  /// accepts (5–60 minutes).
  case invalidSessionDuration(minutes: Int)
  /// The ephemeral session keypair could not be generated.
  case keyGenerationFailed
  /// A session artifact (token, key, config) could not be read or written.
  case persistenceFailed(path: String, detail: String)
  /// A config profile name is not safe to use as both a filesystem path
  /// component and an INI section name.
  case invalidProfileName(String)
  /// A public key PEM was found, but its body could not be decoded.
  case malformedPublicKey(String)
  /// A config entry's key or value could not be written into an INI file without
  /// changing its structure — most importantly a value carrying a line break,
  /// which would inject further config lines into the file.
  case invalidConfigEntry(key: String, detail: String)

  public var errorDescription: String? {
    switch self {
    case .malformedToken(let detail):
      return "The security token could not be read as a JWT with an exp claim: \(detail)"
    case .sessionExpired(let expiredAt):
      return "The session token expired at \(expiredAt). Create a new session to continue."
    case .sessionTooCloseToExpiry(let expiresAt, let minimumRemaining):
      return
        "The session expires at \(expiresAt), leaving less than \(minimumRemaining) seconds — "
        + "too little for a refresh to be worth attempting. Create a new session to continue, "
        + "or pass a smaller `minimumRemaining` to try the refresh anyway."
    case .refreshRejected:
      return
        "The session is no longer valid and cannot be refreshed. "
        + "Create a new session (e.g. `oci session authenticate`) to continue."
    case .refreshFailed(let status, let message):
      return "Refreshing the session token failed (HTTP \(status)). \(message)"
    case .malformedResponse(let shape):
      return "The Auth Service response carried no security token. The body was \(shape)."
    case .rejectedByService:
      return "The session was deemed invalid by the service."
    case .validationFailed(let status, let message):
      return "Validating the session against the service failed (HTTP \(status)). \(message)"
    case .tokenGenerationFailed(let status, let message):
      return "Generating a user security token failed (HTTP \(status)). \(message)"
    case .invalidEndpoint(let endpoint):
      return "The Auth Service endpoint is not a valid URL: \(endpoint)"
    case .invalidHostComponent(let field, let value):
      return
        "The \(field) \"\(value)\" is not a valid DNS name component. "
        + "Refusing to build a service endpoint from it."
    case .invalidSessionDuration(let minutes):
      return
        "A session duration of \(minutes) minutes is out of range; "
        + "it must be between \(SessionTokenClient.minimumSessionMinutes) and "
        + "\(SessionTokenClient.maximumSessionMinutes) minutes."
    case .keyGenerationFailed:
      return "Failed to generate the ephemeral session keypair."
    case .persistenceFailed(let path, let detail):
      return "Failed to persist the session at \(path): \(detail)"
    case .invalidProfileName(let name):
      return
        "The profile name \"\(name)\" is not usable as a directory name and config section. "
        + "Use a name made of letters, digits, dots, dashes and underscores."
    case .malformedPublicKey(let detail):
      return
        "The public key could not be decoded from its PEM body: \(detail). "
        + "Regenerate the session keypair."
    case .invalidConfigEntry(let key, let detail):
      return
        "The config entry \"\(key)\" cannot be written to the config file because \(detail). "
        + "Refusing to write it rather than altering it."
    }
  }
}
