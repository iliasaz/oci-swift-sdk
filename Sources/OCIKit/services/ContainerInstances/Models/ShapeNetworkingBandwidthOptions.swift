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

/// For a flexible shape, the amount of networking bandwidth available for container instances that use this shape.
public struct ShapeNetworkingBandwidthOptions: Codable {
  /// The minimum amount of networking bandwidth, in gigabits per second.
  public let minInGbps: Float?
  /// The maximum amount of networking bandwidth, in gigabits per second.
  public let maxInGbps: Float?
  /// The default amount of networking bandwidth per OCPU, in gigabits per second.
  public let defaultPerOcpuInGbps: Float?

  public init(
    minInGbps: Float? = nil,
    maxInGbps: Float? = nil,
    defaultPerOcpuInGbps: Float? = nil
  ) {
    self.minInGbps = minInGbps
    self.maxInGbps = maxInGbps
    self.defaultPerOcpuInGbps = defaultPerOcpuInGbps
  }
}
