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

/// The file that is mounted on a container instance through a volume mount.
public struct ContainerConfigFile: Codable {
  /// The name of the file. The fileName should be unique across the volume.
  public let fileName: String
  /// The base64 encoded contents of the file. The contents are decoded to plain text before mounted as a file to a container inside container instance.
  public let data: String
  /// (Optional) Relative path for this file inside the volume mount directory. By default, the file is presented at the root of the volume mount path.
  public let path: String?

  public init(fileName: String, data: String, path: String? = nil) {
    self.fileName = fileName
    self.data = data
    self.path = path
  }
}
