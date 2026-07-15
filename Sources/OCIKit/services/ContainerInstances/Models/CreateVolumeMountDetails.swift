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

/// Defines the mapping from volume to a mount path in a container.
public struct CreateVolumeMountDetails: Codable {
  /// The volume access path.
  public let mountPath: String
  /// The name of the volume. Avoid entering confidential information.
  public let volumeName: String
  /// A subpath inside the referenced volume.
  public let subPath: String?
  /// Whether the volume was mounted in read-only mode. By default, the volume is not read-only.
  public let isReadOnly: Bool?
  /// If there is more than one partition in the volume, reference this number of partitions.
  public let partition: Int?

  public init(
    mountPath: String,
    volumeName: String,
    subPath: String? = nil,
    isReadOnly: Bool? = nil,
    partition: Int? = nil
  ) {
    self.mountPath = mountPath
    self.volumeName = volumeName
    self.subPath = subPath
    self.isReadOnly = isReadOnly
    self.partition = partition
  }
}
