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
// On-disk layout of an OCI user session, matching what the CLI's
// `oci session authenticate` writes and what `oci session refresh` updates:
//
//   ~/.oci/sessions/<profile>/oci_api_key.pem         private session key (0600)
//   ~/.oci/sessions/<profile>/oci_api_key_public.pem  public session key (0644)
//   ~/.oci/sessions/<profile>/token                   the session token  (0600)
//   ~/.oci/config                                     [<profile>] entry pointing at them
//
// Keeping this compatible matters in both directions: a session created by the
// CLI can be refreshed by this SDK, and a session created here can be used by
// the CLI.
//

import Foundation
import INIParser

/// Reads and writes the files that make up an OCI user session.
///
/// Every write applies user-only permissions (`0600`) to the private key and the
/// token, mirroring the CLI's `apply_user_only_access_permissions`.
public enum SessionTokenStore {
  /// The default OCI config file.
  public static let defaultConfigFilePath = "~/.oci/config"
  /// The default directory holding per-profile session material.
  public static let defaultSessionsDirectory = "~/.oci/sessions"
  /// Base name the CLI gives session keys.
  public static let defaultKeyName = "oci_api_key"
  /// File name the CLI gives the session token.
  public static let defaultTokenName = "token"

  /// Expands a leading `~` to the current user's home directory.
  public static func expandingTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
  }

  /// The directory holding `profile`'s session material.
  public static func sessionDirectory(
    forProfile profile: String,
    sessionsDirectory: String = defaultSessionsDirectory
  ) -> String {
    expandingTilde(sessionsDirectory) + "/" + profile
  }

  // MARK: Reading

  /// Reads a session token from disk, trimmed of trailing whitespace.
  ///
  /// - Throws: ``ConfigErrors/badSecurityTokenFile`` when the file is missing,
  ///   unreadable, or empty — the same error ``SecurityTokenSigner`` already
  ///   reports for that condition.
  public static func readToken(atPath path: String) throws -> String {
    guard
      let contents = try? String(contentsOfFile: expandingTilde(path), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !contents.isEmpty
    else {
      throw ConfigErrors.badSecurityTokenFile
    }
    return contents
  }

  /// Returns the raw key/value entries of one profile in an OCI config file.
  ///
  /// Deliberately raw: ``SignerConfiguration`` resolves a profile into *parsed*
  /// credentials, but the session lifecycle also needs the literal
  /// `security_token_file` path so a refreshed token can be written back.
  ///
  /// - Throws: ``ConfigErrors/missingConfig`` when the file cannot be parsed and
  ///   ``ConfigErrors/badConfigFileFormat`` when the profile is absent.
  public static func profileSection(configFilePath: String, profile: String) throws -> [String: String] {
    guard let parsed = try? INIParser(expandingTilde(configFilePath)) else {
      throw ConfigErrors.missingConfig
    }
    guard let section = parsed.sections[profile] else {
      throw ConfigErrors.badConfigFileFormat
    }
    return section
  }

  // MARK: Writing

  /// Writes `contents` to `path`, creating intermediate directories and applying
  /// `permissions` to the file.
  ///
  /// - Throws: ``SessionTokenError/persistenceFailed(path:detail:)``.
  public static func write(_ contents: String, toPath path: String, permissions: Int) throws {
    let expanded = expandingTilde(path)
    let directory = (expanded as NSString).deletingLastPathComponent
    do {
      if !directory.isEmpty, !FileManager.default.fileExists(atPath: directory) {
        try FileManager.default.createDirectory(
          atPath: directory,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      }
      try contents.write(toFile: expanded, atomically: true, encoding: .utf8)
      // Set the mode after writing: `write(toFile:atomically:)` replaces the file
      // via a temporary, so permissions applied beforehand would not survive.
      try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: expanded)
    }
    catch let error as SessionTokenError {
      throw error
    }
    catch {
      throw SessionTokenError.persistenceFailed(path: expanded, detail: String(describing: error))
    }
  }

  /// Writes a session token with user-only permissions.
  public static func writeToken(_ token: String, toPath path: String) throws {
    try write(token, toPath: path, permissions: 0o600)
  }

  /// Writes a session private key PEM with user-only permissions.
  public static func writePrivateKey(_ pem: String, toPath path: String) throws {
    try write(pem, toPath: path, permissions: 0o600)
  }

  /// Writes a session public key PEM.
  public static func writePublicKey(_ pem: String, toPath path: String) throws {
    try write(pem, toPath: path, permissions: 0o644)
  }

  // MARK: Config profile

  /// Rewrites an OCI config file so `profile` holds exactly `entries`, replacing
  /// any existing section of that name and leaving every other profile untouched.
  ///
  /// The file is created if absent, and always ends up with user-only
  /// permissions.
  public static func upsertProfile(
    configFilePath: String,
    profile: String,
    entries: [(key: String, value: String)]
  ) throws {
    let expanded = expandingTilde(configFilePath)
    let existing = (try? String(contentsOfFile: expanded, encoding: .utf8)) ?? ""
    let updated = upsertProfile(in: existing, profile: profile, entries: entries)
    try write(updated, toPath: expanded, permissions: 0o600)
  }

  /// The pure text transform behind ``upsertProfile(configFilePath:profile:entries:)``:
  /// drops any existing `[profile]` section from `configText` and appends a fresh
  /// one built from `entries`.
  ///
  /// Section boundaries are the INI ones: a `[name]` line starts a section and it
  /// runs until the next `[…]` line or end of file. Comments and blank lines
  /// belonging to other profiles are preserved verbatim, because only the removed
  /// section's lines are dropped.
  public static func upsertProfile(
    in configText: String,
    profile: String,
    entries: [(key: String, value: String)]
  ) -> String {
    var kept: [String] = []
    var insideTargetSection = false
    for line in configText.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
        let name = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        insideTargetSection = (name == profile)
      }
      if !insideTargetSection {
        kept.append(line)
      }
    }
    // Drop trailing blank lines so exactly one blank line separates the sections.
    while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      kept.removeLast()
    }

    var section = ["[\(profile)]"]
    section.append(contentsOf: entries.map { "\($0.key)=\($0.value)" })

    if kept.isEmpty {
      return section.joined(separator: "\n") + "\n"
    }
    return (kept + [""] + section).joined(separator: "\n") + "\n"
  }

  // MARK: Whole-session persistence

  /// The paths a persisted session occupies on disk.
  public struct SessionPaths: Sendable, Equatable {
    /// The profile name written into the config file.
    public let profile: String
    /// The config file the profile was written to.
    public let configFilePath: String
    /// The session's private key PEM.
    public let privateKeyPath: String
    /// The session's public key PEM.
    public let publicKeyPath: String
    /// The session token.
    public let tokenPath: String
  }

  /// Writes a complete session — keypair, token, and config profile — in the
  /// layout the OCI CLI uses, so the resulting profile works with both this SDK
  /// and the CLI.
  ///
  /// This is the persistence half of `oci session authenticate`; see
  /// ``SessionTokenManager/authenticate(using:region:profile:configFilePath:sessionsDirectory:sessionExpirationInMinutes:realmDomainComponent:transport:logger:)``
  /// for the call that mints the token first.
  ///
  /// - Parameters:
  ///   - keyPair: The session keypair the token is bound to.
  ///   - token: The issued session token.
  ///   - profile: The config profile name to create or replace.
  ///   - region: The region written into the profile.
  ///   - tenancyOCID: The tenancy OCID, when known (read from the token's
  ///     `tenant` claim by the caller).
  ///   - userOCID: The user OCID, when known (the token's `sub` claim).
  ///   - configFilePath: The config file to update.
  ///   - sessionsDirectory: Where the session directory is created.
  /// - Returns: The paths written.
  @discardableResult
  public static func persistSession(
    keyPair: SessionKeyPair,
    token: String,
    profile: String,
    region: String,
    tenancyOCID: String?,
    userOCID: String?,
    configFilePath: String = defaultConfigFilePath,
    sessionsDirectory: String = defaultSessionsDirectory
  ) throws -> SessionPaths {
    let directory = sessionDirectory(forProfile: profile, sessionsDirectory: sessionsDirectory)
    let privateKeyPath = "\(directory)/\(defaultKeyName).pem"
    let publicKeyPath = "\(directory)/\(defaultKeyName)_public.pem"
    let tokenPath = "\(directory)/\(defaultTokenName)"

    try writePrivateKey(keyPair.privateKeyPEM, toPath: privateKeyPath)
    try writePublicKey(keyPair.publicKeyPEM, toPath: publicKeyPath)
    try writeToken(token, toPath: tokenPath)

    var entries: [(key: String, value: String)] = []
    if let userOCID { entries.append((key: "user", value: userOCID)) }
    entries.append((key: "fingerprint", value: keyPair.fingerprint))
    entries.append((key: "key_file", value: privateKeyPath))
    if let tenancyOCID { entries.append((key: "tenancy", value: tenancyOCID)) }
    entries.append((key: "region", value: region))
    entries.append((key: "security_token_file", value: tokenPath))
    try upsertProfile(configFilePath: configFilePath, profile: profile, entries: entries)

    return SessionPaths(
      profile: profile,
      configFilePath: expandingTilde(configFilePath),
      privateKeyPath: privateKeyPath,
      publicKeyPath: publicKeyPath,
      tokenPath: tokenPath
    )
  }
}
