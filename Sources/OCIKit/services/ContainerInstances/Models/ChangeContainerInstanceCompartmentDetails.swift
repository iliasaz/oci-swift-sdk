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

/// The configuration details for the move operation.
public struct ChangeContainerInstanceCompartmentDetails: Codable {
  /// The OCID of the compartment to move the container instance to.
  public let compartmentId: String

  public init(compartmentId: String) {
    self.compartmentId = compartmentId
  }
}
