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

/// The size and amount of resources available to the container.
public struct CreateContainerResourceConfigDetails: Codable {
  /// The maximum amount of CPUs that can be consumed by the container's process. If you do not set a value, then the process can use all available CPU resources on the instance. CPU usage is defined in terms of logical CPUs. Values can be fractional. A value of "1.5" means that the container can consume at most the equivalent of 1 and a half logical CPUs worth of CPU capacity.
  public let vcpusLimit: Float?
  /// The maximum amount of memory that can be consumed by the container's process. If you do not set a value, then the process may use all available memory on the instance.
  public let memoryLimitInGBs: Float?

  public init(vcpusLimit: Float? = nil, memoryLimitInGBs: Float? = nil) {
    self.vcpusLimit = vcpusLimit
    self.memoryLimitInGBs = memoryLimitInGBs
  }
}
