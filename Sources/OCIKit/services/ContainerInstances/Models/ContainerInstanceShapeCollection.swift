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

/// A collection of container instance shapes.
public struct ContainerInstanceShapeCollection: Codable {
  /// A list of shapes.
  public let items: [ContainerInstanceShapeSummary]

  public init(items: [ContainerInstanceShapeSummary]) {
    self.items = items
  }
}
