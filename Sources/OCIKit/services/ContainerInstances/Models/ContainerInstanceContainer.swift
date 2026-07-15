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

/// A container on a container instance.
public struct ContainerInstanceContainer: Codable {
  /// The OCID of the container.
  public let containerId: String
  /// Display name for the Container.
  public let displayName: String?

  public init(
    containerId: String,
    displayName: String? = nil
  ) {
    self.containerId = containerId
    self.displayName = displayName
  }
}
