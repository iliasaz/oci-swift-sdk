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

/// For a flexible shape, the amount of memory available for container instances that use this shape.
public struct ShapeMemoryOptions: Codable {
  /// The minimum amount of memory (GB).
  public let minInGBs: Float?
  /// The maximum amount of memory (GB).
  public let maxInGBs: Float?
  /// The default amount of memory per OCPU available for this shape (GB).
  public let defaultPerOcpuInGBs: Float?
  /// The minimum amount of memory per OCPU available for this shape (GB).
  public let minPerOcpuInGBs: Float?
  /// The maximum amount of memory per OCPU available for this shape (GB).
  public let maxPerOcpuInGBs: Float?

  public init(
    minInGBs: Float? = nil,
    maxInGBs: Float? = nil,
    defaultPerOcpuInGBs: Float? = nil,
    minPerOcpuInGBs: Float? = nil,
    maxPerOcpuInGBs: Float? = nil
  ) {
    self.minInGBs = minInGBs
    self.maxInGBs = maxInGBs
    self.defaultPerOcpuInGBs = defaultPerOcpuInGBs
    self.minPerOcpuInGBs = minPerOcpuInGBs
    self.maxPerOcpuInGBs = maxPerOcpuInGBs
  }
}
