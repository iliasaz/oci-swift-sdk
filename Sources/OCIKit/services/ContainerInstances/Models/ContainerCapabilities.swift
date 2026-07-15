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

/// Linux Container capabilities to configure capabilities of container.
public struct ContainerCapabilities: Codable {
  /// A list of additional configurable container capabilities.
  public let addCapabilities: [String]?
  /// A list of container capabilities that can be dropped.
  public let dropCapabilities: [String]?

  public init(addCapabilities: [String]? = nil, dropCapabilities: [String]? = nil) {
    self.addCapabilities = addCapabilities
    self.dropCapabilities = dropCapabilities
  }
}
