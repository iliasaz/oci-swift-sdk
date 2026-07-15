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

/// The shape configuration for a container instance. The shape configuration determines
/// the resources thats are available to the container instance and its containers.
public struct ContainerInstanceShapeConfig: Codable {
  /// The total number of OCPUs available to the container instance.
  public let ocpus: Float
  /// The total amount of memory available to the container instance, in gigabytes.
  public let memoryInGBs: Float
  /// A short description of the container instance's processor (CPU).
  public let processorDescription: String
  /// The networking bandwidth available to the container instance, in gigabits per second.
  public let networkingBandwidthInGbps: Float

  public init(
    ocpus: Float,
    memoryInGBs: Float,
    processorDescription: String,
    networkingBandwidthInGbps: Float
  ) {
    self.ocpus = ocpus
    self.memoryInGBs = memoryInGBs
    self.processorDescription = processorDescription
    self.networkingBandwidthInGbps = networkingBandwidthInGbps
  }
}
