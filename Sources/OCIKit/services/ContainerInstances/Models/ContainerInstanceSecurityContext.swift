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

/// Security context for all containers in a container instance.
public struct ContainerInstanceSecurityContext: Codable {
  /// The type of security context.
  public let securityContextType: SecurityContextType
  /// (LINUX only) A special supplemental group that applies to all containers in the container instance.
  /// Some volume types allow the container instance to change ownership of the volume. The owning GID will
  /// be the fsGroup, the setgid bit will be set (new files will be owned by the fsGroup), and the permission
  /// bits are OR'd with rw-rw----. If unset, the container instance will not modify the ownership and
  /// permissions of volumes.
  public let fsGroup: Int?
  /// (LINUX only) Defines behavior of changing ownership and permission of the volume before being exposed
  /// inside the containers.
  public let fsGroupChangePolicy: FsGroupChangePolicy?

  public init(
    securityContextType: SecurityContextType,
    fsGroup: Int? = nil,
    fsGroupChangePolicy: FsGroupChangePolicy? = nil
  ) {
    self.securityContextType = securityContextType
    self.fsGroup = fsGroup
    self.fsGroupChangePolicy = fsGroupChangePolicy
  }

  /// Creates a security context for all containers in a Linux container instance.
  public static func linux(
    fsGroup: Int? = nil,
    fsGroupChangePolicy: FsGroupChangePolicy? = nil
  ) -> ContainerInstanceSecurityContext {
    ContainerInstanceSecurityContext(
      securityContextType: .linux,
      fsGroup: fsGroup,
      fsGroupChangePolicy: fsGroupChangePolicy
    )
  }
}
