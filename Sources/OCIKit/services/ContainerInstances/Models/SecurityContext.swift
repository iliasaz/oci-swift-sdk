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

/// Security context for container.
public struct SecurityContext: Codable {
  /// The type of security context.
  public let securityContextType: SecurityContextType
  /// (LINUX only) The user ID (UID) to run the entrypoint process of the container. Defaults to user
  /// specified UID in container image metadata if not provided. This must be provided if runAsGroup is provided.
  public let runAsUser: Int?
  /// (LINUX only) The group ID (GID) to run the entrypoint process of the container. Uses runtime default if not provided.
  public let runAsGroup: Int?
  /// (LINUX only) Indicates if the container must run as a non-root user. If true, the service validates the
  /// container image at runtime to ensure that it is not going to run with UID 0 (root) and fails the
  /// container instance creation if the validation fails.
  public let isNonRootUserCheckEnabled: Bool?
  /// (LINUX only) Determines if the container will have a read-only root file system. Default value is false.
  public let isRootFileSystemReadonly: Bool?
  /// (LINUX only) Linux container capabilities to configure capabilities of the container.
  public let capabilities: ContainerCapabilities?

  public init(
    securityContextType: SecurityContextType,
    runAsUser: Int? = nil,
    runAsGroup: Int? = nil,
    isNonRootUserCheckEnabled: Bool? = nil,
    isRootFileSystemReadonly: Bool? = nil,
    capabilities: ContainerCapabilities? = nil
  ) {
    self.securityContextType = securityContextType
    self.runAsUser = runAsUser
    self.runAsGroup = runAsGroup
    self.isNonRootUserCheckEnabled = isNonRootUserCheckEnabled
    self.isRootFileSystemReadonly = isRootFileSystemReadonly
    self.capabilities = capabilities
  }

  /// Creates a security context for a Linux container.
  public static func linux(
    runAsUser: Int? = nil,
    runAsGroup: Int? = nil,
    isNonRootUserCheckEnabled: Bool? = nil,
    isRootFileSystemReadonly: Bool? = nil,
    capabilities: ContainerCapabilities? = nil
  ) -> SecurityContext {
    SecurityContext(
      securityContextType: .linux,
      runAsUser: runAsUser,
      runAsGroup: runAsGroup,
      isNonRootUserCheckEnabled: isNonRootUserCheckEnabled,
      isRootFileSystemReadonly: isRootFileSystemReadonly,
      capabilities: capabilities
    )
  }
}
