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

/// A volume represents a directory with data that is accessible across multiple containers in a container instance.
public struct ContainerVolume: Codable {
  /// The name of the volume. This must be unique within a single container instance.
  public let name: String
  /// The type of volume.
  public let volumeType: ContainerVolumeType
  /// (EMPTYDIR only) The volume type of the empty directory, can be either File Storage or Memory.
  public let backingStore: String?
  /// (CONFIGFILE only) Contains string key value pairs which can be mounted as individual files inside the container. The value needs to be base64 encoded. It is decoded to plain text before the mount.
  public let configs: [ContainerConfigFile]?

  public init(name: String, volumeType: ContainerVolumeType, backingStore: String? = nil, configs: [ContainerConfigFile]? = nil) {
    self.name = name
    self.volumeType = volumeType
    self.backingStore = backingStore
    self.configs = configs
  }

  /// Creates an EMPTYDIR volume.
  public static func emptyDir(name: String, backingStore: String? = nil) -> ContainerVolume {
    ContainerVolume(name: name, volumeType: .emptyDir, backingStore: backingStore)
  }

  /// Creates a CONFIGFILE volume.
  public static func configFile(name: String, configs: [ContainerConfigFile]) -> ContainerVolume {
    ContainerVolume(name: name, volumeType: .configFile, configs: configs)
  }
}
