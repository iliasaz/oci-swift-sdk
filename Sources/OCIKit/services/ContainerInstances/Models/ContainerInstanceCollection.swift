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

/// Summary information about a list of container instances.
public struct ContainerInstanceCollection: Codable {
  /// List of container instances.
  public let items: [ContainerInstanceSummary]

  public init(items: [ContainerInstanceSummary]) {
    self.items = items
  }
}
