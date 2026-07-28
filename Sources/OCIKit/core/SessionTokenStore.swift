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
import Synchronization

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

  // MARK: Profile names

  /// Whether `profile` is safe to use as *both* a path component under the
  /// sessions directory *and* an INI section name in the config file.
  ///
  /// A profile name reaches disk twice — as `~/.oci/sessions/<profile>/…` and as
  /// the `[<profile>]` line of the config file — so anything that could escape
  /// the sessions directory (`/`, `..`) or terminate/extend an INI section
  /// (`]`, `=`, newlines) has to be refused rather than sanitized. The accepted
  /// set is ASCII letters, digits, `.`, `-` and `_`, which also rules out
  /// leading or trailing whitespace. This is the same defensive posture
  /// ``InstancePrincipalSigner/isValidHostComponent(_:)`` takes for
  /// region/realm values spliced into a host name.
  public static func isValidProfileName(_ profile: String) -> Bool {
    guard !profile.isEmpty, profile.count <= 255 else { return false }
    guard profile != ".", profile != ".." else { return false }
    return profile.allSatisfy(isProfileNameCharacter)
  }

  /// Whether `character` may appear in a profile name: ASCII `[A-Za-z0-9._-]`.
  private static func isProfileNameCharacter(_ character: Character) -> Bool {
    guard character.isASCII else { return false }
    return character.isNumber || character.isLetter || character == "." || character == "-"
      || character == "_"
  }

  // MARK: Config entries

  /// Rejects a config entry whose key or value could not survive an INI round trip.
  ///
  /// A profile name is validated (see ``isValidProfileName(_:)``) because it
  /// reaches disk as a path component and a section header; the *entries* need the
  /// same posture for the same reason. ``upsertProfile(in:profile:entries:)``
  /// renders each pair as `key=value`, so a newline anywhere in either half would
  /// inject further config lines — and because a duplicate section is *merged* by
  /// the parsers that read these files (later assignments winning), an injected
  /// `[DEFAULT]` block could silently re-point another profile's `key_file` or
  /// `security_token_file`. Values arrive from places this type does not control
  /// (a caller-supplied region, and `tenancy`/`user` read out of a token's
  /// unverified JWT claims), so they are refused rather than sanitized.
  ///
  /// - Throws: ``SessionTokenError/invalidConfigEntry(key:detail:)``.
  public static func validateEntries(_ entries: [(key: String, value: String)]) throws {
    for entry in entries {
      let key = entry.key
      guard !key.isEmpty else {
        throw SessionTokenError.invalidConfigEntry(key: key, detail: "the key is empty")
      }
      guard key == key.trimmingCharacters(in: .whitespaces) else {
        throw SessionTokenError.invalidConfigEntry(
          key: key,
          detail: "the key carries leading or trailing whitespace"
        )
      }
      guard !key.contains(where: isConfigStructuralCharacter) else {
        throw SessionTokenError.invalidConfigEntry(
          key: key,
          detail: "the key carries a character that is significant in an INI file"
        )
      }
      guard !entry.value.contains(where: isNewlineCharacter) else {
        throw SessionTokenError.invalidConfigEntry(
          key: key,
          detail: "the value carries a line break, which would inject further config lines"
        )
      }
    }
  }

  /// Whether `character` would change the meaning of a `key=value` line.
  private static func isConfigStructuralCharacter(_ character: Character) -> Bool {
    character == "=" || character == "[" || character == "]" || character == "#" || character == ";"
      || isNewlineCharacter(character)
  }

  /// Whether `character` ends a line in a config file, `\r` included.
  private static func isNewlineCharacter(_ character: Character) -> Bool {
    character == "\n" || character == "\r" || character.isNewline
  }

  /// Rejects a profile name that is not usable as a directory name and an INI
  /// section name.
  ///
  /// - Throws: ``SessionTokenError/invalidProfileName(_:)``.
  public static func validateProfileName(_ profile: String) throws {
    guard isValidProfileName(profile) else {
      throw SessionTokenError.invalidProfileName(profile)
    }
  }

  /// The directory holding `profile`'s session material.
  ///
  /// - Throws: ``SessionTokenError/invalidProfileName(_:)`` when `profile` is not
  ///   a safe path component — see ``isValidProfileName(_:)``.
  public static func sessionDirectory(
    forProfile profile: String,
    sessionsDirectory: String = defaultSessionsDirectory
  ) throws -> String {
    try validateProfileName(profile)
    return URL(fileURLWithPath: expandingTilde(sessionsDirectory), isDirectory: true)
      .appending(path: profile, directoryHint: .notDirectory)
      .path
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
  /// - Throws: ``ConfigErrors/badConfigFileFormat`` when the file is absent or cannot be
  ///   parsed and ``ConfigErrors/missingConfig`` when the profile is absent — the same
  ///   mapping ``SignerConfiguration/fromFileForSecurityToken(configFilePath:configName:)``
  ///   reports for the same file.
  public static func profileSection(configFilePath: String, profile: String) throws -> [String: String] {
    guard let parsed = try? INIParser(expandingTilde(configFilePath)) else {
      throw ConfigErrors.badConfigFileFormat
    }
    guard let section = parsed.sections[profile] else {
      throw ConfigErrors.missingConfig
    }
    return section
  }

  // MARK: Writing

  /// Writes `contents` to `path`, creating intermediate directories and applying
  /// `permissions` to the file.
  ///
  /// The bytes are never observable at looser permissions than `permissions`, at
  /// the destination or anywhere else: they go to a sibling temporary file created
  /// by `open(2)` with `O_CREAT | O_EXCL` *and* the intended mode — so the file
  /// carries that mode from the moment it exists — which then replaces the
  /// destination with `rename(2)`, so a reader either sees the previous file or the
  /// complete new one, never a partial write.
  ///
  /// Neither of the obvious Foundation spellings can promise that, and both were
  /// tried here first: `write(toFile:atomically:)` followed by a `chmod` renames
  /// its own umask-moded temporary into place *before* tightening the mode, and
  /// `FileManager.createFile(atPath:contents:attributes:)` is itself a
  /// write-then-`chmod` (`Data.write(options: .atomic)` plus `setAttributes`) on
  /// both Darwin and swift-corelibs-foundation, so the full contents exist at
  /// `0666 & ~umask` — typically `0644` — before the mode is applied. A private key
  /// or session token must not be world-readable for even that long. `open(2)`
  /// *does* mask the requested mode with the umask, so an explicit `fchmod(2)` on
  /// the same descriptor — still before any bytes are written, and never on a path
  /// an attacker could have swapped — pins the mode to exactly `permissions`.
  ///
  /// - Throws: ``SessionTokenError/persistenceFailed(path:detail:)``.
  public static func write(_ contents: String, toPath path: String, permissions: Int) throws {
    let expanded = expandingTilde(path)
    let destination = URL(fileURLWithPath: expanded, isDirectory: false)
    let directory = (expanded as NSString).deletingLastPathComponent
    let fileManager = FileManager.default
    do {
      if !directory.isEmpty, !fileManager.fileExists(atPath: directory) {
        try createDirectoryTree(atPath: directory, permissions: 0o700)
      }
      guard let data = contents.data(using: .utf8) else {
        throw SessionTokenError.persistenceFailed(
          path: expanded,
          detail: "The contents could not be encoded as UTF-8."
        )
      }
      let temporary =
        destination
        .deletingLastPathComponent()
        .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
      try writeExclusively(data, toPath: temporary.path, permissions: permissions, destination: expanded)
      // `rename(2)` (libc, reachable through Foundation on Darwin and Linux
      // alike) is the move that fits: it is atomic, it replaces the destination
      // even when that file is mode `0400` — which an in-place truncating write
      // could not even open — and it carries the temporary file's mode over, so
      // the destination is `permissions` the instant it becomes visible.
      // `FileManager.moveItem` refuses an existing destination, and
      // `replaceItemAt` is unreliable here (it fails outright on
      // swift-corelibs-foundation and can copy the replaced file's metadata).
      guard rename(temporary.path, expanded) == 0 else {
        let code = errno
        try? fileManager.removeItem(at: temporary)
        throw SessionTokenError.persistenceFailed(
          path: expanded,
          detail: "Moving the new file into place failed: \(String(cString: strerror(code))) (errno \(code))."
        )
      }
    }
    catch let error as SessionTokenError {
      throw error
    }
    catch {
      throw SessionTokenError.persistenceFailed(path: expanded, detail: String(describing: error))
    }
  }

  /// Creates `path` exclusively at exactly `permissions` and writes `data` into it.
  ///
  /// The file is created by `open(2)` with `O_CREAT | O_EXCL`, so an existing file
  /// (or a symlink planted at that name) makes this fail rather than being written
  /// through, and the mode is pinned with `fchmod(2)` on the descriptor before the
  /// first byte lands. `destination` names the file the caller is ultimately
  /// writing, so the thrown error points at that rather than at the temporary.
  ///
  /// - Throws: ``SessionTokenError/persistenceFailed(path:detail:)``. The partial
  ///   file, if any, is removed first.
  private static func writeExclusively(
    _ data: Data,
    toPath path: String,
    permissions: Int,
    destination: String
  ) throws {
    func failure(_ what: String, _ code: Int32) -> SessionTokenError {
      .persistenceFailed(
        path: destination,
        detail: "\(what) at \(path) failed: \(String(cString: strerror(code))) (errno \(code))."
      )
    }

    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions))
    guard descriptor >= 0 else { throw failure("Creating a temporary file", errno) }
    // Everything from here on cleans the partial file up: a `.tmp` carrying key
    // material must not be left behind for a failure the caller will see anyway.
    func abandon(_ error: SessionTokenError) -> SessionTokenError {
      close(descriptor)
      unlink(path)
      return error
    }
    // `open(2)` masks the requested mode with the umask, so a `0644` public key
    // under a `0077` umask would arrive as `0600`; pin the exact mode while the
    // file is still empty and reachable only through this descriptor.
    guard fchmod(descriptor, mode_t(permissions)) == 0 else {
      throw abandon(failure("Setting the permissions of the temporary file", errno))
    }
    do {
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      try handle.write(contentsOf: data)
    }
    catch {
      throw abandon(
        .persistenceFailed(path: destination, detail: "Writing \(path) failed: \(error).")
      )
    }
    guard close(descriptor) == 0 else {
      let code = errno
      unlink(path)
      throw failure("Closing the temporary file", code)
    }
  }

  /// Creates `path` and every missing directory above it with `permissions`.
  ///
  /// `createDirectory(withIntermediateDirectories: true, attributes:)` applies
  /// the attributes to the leaf only, so intermediates (e.g. `~/.oci` when
  /// creating `~/.oci/sessions/<profile>`) would be left at the umask default
  /// `0755`. Session material must not sit under a world-readable directory, so
  /// each level is created individually. Explicit POSIX permissions are not
  /// masked by the umask.
  ///
  /// A level someone else created in the meantime is *not* an error.
  /// `withIntermediateDirectories: false` throws `EEXIST` for an existing
  /// directory rather than no-op'ing like the `true` form, and the levels here are
  /// chosen before they are created, so two concurrent sessions under a not-yet-
  /// existing `~/.oci/sessions` would otherwise make one of them fail — discarding
  /// an already-minted token over a directory that now exists with the right mode.
  private static func createDirectoryTree(atPath path: String, permissions: Int) throws {
    let fileManager = FileManager.default
    var missing: [String] = []
    var current = path
    while !current.isEmpty, current != "/", !fileManager.fileExists(atPath: current) {
      missing.append(current)
      let parent = (current as NSString).deletingLastPathComponent
      guard parent != current else { break }
      current = parent
    }
    for directory in missing.reversed() {
      if fileManager.fileExists(atPath: directory) { continue }
      do {
        try fileManager.createDirectory(
          atPath: directory,
          withIntermediateDirectories: false,
          attributes: [.posixPermissions: permissions]
        )
      }
      catch {
        // Lost a race with another creator: the level exists, which is all this
        // needs. Anything else is a real failure.
        guard fileManager.fileExists(atPath: directory) else { throw error }
      }
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

  /// Serializes every config-file read-modify-write this process performs.
  ///
  /// Upserting a profile reads the whole config file, drops one section and writes
  /// the file back, so two unsynchronised upserts — two ``SessionTokenManager``
  /// `authenticate` calls for different profiles, say — would both read the same
  /// "before" text and the second write would lose the first profile entirely.
  /// Holding this across the read *and* the write makes the sequence atomic within
  /// the process, and ``persistSession(keyPair:token:profile:region:tenancyOCID:userOCID:configFilePath:sessionsDirectory:)``
  /// holds it across its four writes so no other task in this process can observe
  /// (or produce) a profile whose key, token and `fingerprint` come from different
  /// sessions.
  ///
  /// Known limitation: this is a process-local lock, so it does not order this SDK
  /// against a concurrently-running `oci session authenticate` / `oci session
  /// refresh` — the CLI takes no lock of its own, so there is nothing to interlock
  /// with. Run one at a time for the same config file.
  private static let configFileLock = Mutex(())

  /// Rewrites an OCI config file so `profile` holds exactly `entries`, replacing
  /// any existing section of that name and leaving every other profile untouched.
  ///
  /// The file is created if absent, and always ends up with user-only
  /// permissions. Concurrent calls in this process are serialized; see
  /// ``configFileLock``.
  ///
  /// - Throws: ``SessionTokenError/invalidProfileName(_:)`` for an unsafe profile
  ///   name, ``SessionTokenError/invalidConfigEntry(key:detail:)`` for an entry that
  ///   would not survive an INI round trip, and
  ///   ``SessionTokenError/persistenceFailed(path:detail:)`` when an existing config
  ///   file cannot be read or the new one cannot be written.
  public static func upsertProfile(
    configFilePath: String,
    profile: String,
    entries: [(key: String, value: String)]
  ) throws {
    try configFileLock.withLock { _ in
      let update = try preparedProfileUpdate(configFilePath: configFilePath, profile: profile, entries: entries)
      try write(update.text, toPath: update.path, permissions: 0o600)
    }
  }

  /// The complete new contents of `configFilePath` with `profile` upserted, and the
  /// expanded path they belong at — everything ``upsertProfile(configFilePath:profile:entries:)``
  /// does *except* the write.
  ///
  /// Separated out so a caller writing several files can validate the profile,
  /// validate the entries and read the existing config *before* replacing anything
  /// on disk; see ``persistSession(keyPair:token:profile:region:tenancyOCID:userOCID:configFilePath:sessionsDirectory:)``.
  ///
  /// Callers must hold ``configFileLock`` across this and the write that follows,
  /// otherwise the read-modify-write is not atomic.
  private static func preparedProfileUpdate(
    configFilePath: String,
    profile: String,
    entries: [(key: String, value: String)]
  ) throws -> (path: String, text: String) {
    try validateProfileName(profile)
    let expanded = expandingTilde(configFilePath)
    // "The file does not exist" and "the file exists but could not be read" must
    // stay separate cases. Collapsing them (`try? … ?? ""`) means a config that
    // is merely unreadable right now — non-UTF-8 bytes, EACCES, a transient I/O
    // error — is treated as empty, and the write below then replaces the user's
    // whole `~/.oci/config` with just this session profile, destroying every
    // other profile unrecoverably. Only a genuinely absent file may start empty.
    let existing: String
    if FileManager.default.fileExists(atPath: expanded) {
      do {
        existing = try String(contentsOfFile: expanded, encoding: .utf8)
      }
      catch {
        throw SessionTokenError.persistenceFailed(
          path: expanded,
          detail:
            "The existing config file could not be read (\(error)), so it was left untouched "
            + "rather than replaced with only the \"\(profile)\" profile."
        )
      }
    }
    else {
      existing = ""
    }
    return (expanded, try upsertProfile(in: existing, profile: profile, entries: entries))
  }

  /// The pure text transform behind ``upsertProfile(configFilePath:profile:entries:)``:
  /// drops any existing `[profile]` section from `configText` and appends a fresh
  /// one built from `entries`.
  ///
  /// Section boundaries are the INI ones: a `[name]` line starts a section and it
  /// runs until the next `[…]` line or end of file. Comments and blank lines
  /// belonging to other profiles are preserved verbatim, because only the removed
  /// section's lines are dropped.
  ///
  /// - Throws: ``SessionTokenError/invalidProfileName(_:)`` when `profile` is not
  ///   INI-safe — a name carrying `]`, `=`, a newline or a carriage return could
  ///   otherwise corrupt the file or inject keys into another profile — and
  ///   ``SessionTokenError/invalidConfigEntry(key:detail:)`` when an entry could
  ///   not survive the round trip; see ``validateEntries(_:)``.
  public static func upsertProfile(
    in configText: String,
    profile: String,
    entries: [(key: String, value: String)]
  ) throws -> String {
    try validateProfileName(profile)
    try validateEntries(entries)
    var kept: [String] = []
    var insideTargetSection = false
    for line in configText.components(separatedBy: "\n") {
      if let name = sectionName(ofLine: line) {
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

  /// The section `line` opens, or `nil` when it opens none.
  ///
  /// Reads a header exactly the way the parsers that consume these files do —
  /// `INIParser`, and therefore ``profileSection(configFilePath:profile:)``,
  /// ``SignerConfiguration`` and the CLI's `configparser`: the header ends at the
  /// *first* `]`, anything after it (typically a trailing `; comment`) is not part
  /// of the name, and whitespace inside the brackets is ignored. Requiring the line
  /// to *end* in `]` instead — the obvious spelling — makes the writer disagree with
  /// the reader in two ways that both destroy configuration:
  ///
  ///   * `[work] ; my other tenancy` would not be seen as a header, so the section
  ///     being replaced would appear to continue through the whole of `[work]`, and
  ///     that profile would be deleted along with it;
  ///   * a CRLF config file (copied in from Windows) ends every header in `]\r`,
  ///     which `CharacterSet.whitespaces` does not cover, so *no* header would be
  ///     recognised and the file would end up with the profile twice — merged
  ///     silently by `INIParser`, a hard `DuplicateSectionError` for the CLI.
  private static func sectionName(ofLine line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
    let name = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
    return name.filter { !$0.isWhitespace }
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
  /// Re-authenticating an existing profile overwrites that profile's key and token
  /// in place, so the order matters: everything that can fail without touching disk
  /// — validating the profile name and the entries, and reading the config file that
  /// is about to be rewritten — happens *first*, and only then is any material
  /// replaced. Writing the material first would mean a failure to read the config
  /// (an unreadable `~/.oci/config`, which this type refuses to overwrite) left the
  /// profile pointing at a `fingerprint` that no longer matches the key on disk,
  /// destroying a session that was still working.
  ///
  /// - Returns: The paths written.
  /// - Throws: ``SessionTokenError/invalidProfileName(_:)`` when `profile` is not
  ///   usable as a directory name and config section,
  ///   ``SessionTokenError/invalidConfigEntry(key:detail:)`` when a value would not
  ///   survive the INI round trip, and
  ///   ``SessionTokenError/persistenceFailed(path:detail:)`` on any write failure.
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
    try validateProfileName(profile)
    let directory = try sessionDirectory(forProfile: profile, sessionsDirectory: sessionsDirectory)
    let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    let privateKeyPath = directoryURL.appending(path: "\(defaultKeyName).pem").path
    let publicKeyPath = directoryURL.appending(path: "\(defaultKeyName)_public.pem").path
    let tokenPath = directoryURL.appending(path: defaultTokenName).path

    var entries: [(key: String, value: String)] = []
    if let userOCID { entries.append((key: "user", value: userOCID)) }
    entries.append((key: "fingerprint", value: keyPair.fingerprint))
    entries.append((key: "key_file", value: privateKeyPath))
    if let tenancyOCID { entries.append((key: "tenancy", value: tenancyOCID)) }
    entries.append((key: "region", value: region))
    entries.append((key: "security_token_file", value: tokenPath))

    // One critical section over the whole session: another task in this process
    // cannot interleave its own keypair, token or config section into this
    // profile's, and the config file's read-modify-write stays atomic.
    try configFileLock.withLock { _ in
      let update = try preparedProfileUpdate(configFilePath: configFilePath, profile: profile, entries: entries)
      try writePrivateKey(keyPair.privateKeyPEM, toPath: privateKeyPath)
      try writePublicKey(keyPair.publicKeyPEM, toPath: publicKeyPath)
      try writeToken(token, toPath: tokenPath)
      try write(update.text, toPath: update.path, permissions: 0o600)
    }

    return SessionPaths(
      profile: profile,
      configFilePath: expandingTilde(configFilePath),
      privateKeyPath: privateKeyPath,
      publicKeyPath: publicKeyPath,
      tokenPath: tokenPath
    )
  }
}
