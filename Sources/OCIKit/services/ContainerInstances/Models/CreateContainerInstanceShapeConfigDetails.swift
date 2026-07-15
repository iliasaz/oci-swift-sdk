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

/// The size and amount of resources available to the container instance.
public struct CreateContainerInstanceShapeConfigDetails: Codable {
  /// The total number of OCPUs available to the container instance.
  public let ocpus: Float
  /// The total amount of memory available to the container instance (GB).
  public let memoryInGBs: Float?

  public init(ocpus: Float, memoryInGBs: Float? = nil) {
    self.ocpus = ocpus
    self.memoryInGBs = memoryInGBs
  }
}
