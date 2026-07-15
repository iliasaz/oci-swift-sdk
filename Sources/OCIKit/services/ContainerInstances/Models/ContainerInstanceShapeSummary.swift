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

/// Details about a shape for a container instance.
public struct ContainerInstanceShapeSummary: Codable {
  /// The name identifying the shape.
  public let name: String
  /// A short description of the container instance's processor (CPU).
  public let processorDescription: String
  /// For a flexible shape, the number of OCPUs available for container instances that use this shape.
  public let ocpuOptions: ShapeOcpuOptions?
  /// For a flexible shape, the amount of memory available for container instances that use this shape.
  public let memoryOptions: ShapeMemoryOptions?
  /// For a flexible shape, the amount of networking bandwidth available for container instances that use this shape.
  public let networkingBandwidthOptions: ShapeNetworkingBandwidthOptions?

  public init(
    name: String,
    processorDescription: String,
    ocpuOptions: ShapeOcpuOptions? = nil,
    memoryOptions: ShapeMemoryOptions? = nil,
    networkingBandwidthOptions: ShapeNetworkingBandwidthOptions? = nil
  ) {
    self.name = name
    self.processorDescription = processorDescription
    self.ocpuOptions = ocpuOptions
    self.memoryOptions = memoryOptions
    self.networkingBandwidthOptions = networkingBandwidthOptions
  }
}
