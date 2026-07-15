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

/// The resource configuration for a container. The resource configuration determines
/// the amount of resources allocated to the container and the maximum allowed resources for a container.
public struct ContainerResourceConfig: Codable {
  /// The maximum amount of CPUs that can be consumed by the container's process.
  ///
  /// If you do not set a value, then the process may use all available CPU resources on the container instance.
  /// CPU usage is defined in terms of logical CPUs. This means that the maximum possible value on an E3
  /// ContainerInstance with 1 OCPU is 2.0.
  public let vcpusLimit: Float?
  /// The maximum amount of memory that can be consumed by the container's process.
  /// If you do not set a value, then the process may use all available memory on the instance.
  public let memoryLimitInGBs: Float?

  public init(vcpusLimit: Float? = nil, memoryLimitInGBs: Float? = nil) {
    self.vcpusLimit = vcpusLimit
    self.memoryLimitInGBs = memoryLimitInGBs
  }
}
