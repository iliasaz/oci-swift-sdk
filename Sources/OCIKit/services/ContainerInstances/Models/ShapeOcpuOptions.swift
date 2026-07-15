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

/// For a flexible shape, the number of OCPUs available for container instances that use this shape.
public struct ShapeOcpuOptions: Codable {
  /// The minimum number of OCPUs.
  public let min: Float?
  /// The maximum number of OCPUs.
  public let max: Float?

  public init(min: Float? = nil, max: Float? = nil) {
    self.min = min
    self.max = max
  }
}
