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

/// Define the mapping from volume to a mount path in container.
public struct VolumeMount: Codable {
  /// Describes the volume access path.
  public let mountPath: String
  /// The name of the volume.
  public let volumeName: String
  /// A sub-path inside the referenced volume.
  public let subPath: String?
  /// Whether the volume was mounted in read-only mode. By default, the volume is mounted with write access.
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
