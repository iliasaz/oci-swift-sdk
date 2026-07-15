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

/// An interface to a virtual network available to containers on a container instance.
public struct ContainerVnic: Codable {
  /// The identifier of the virtual network interface card (VNIC) over which
  /// the containers accessing this network can communicate with the
  /// larger virtual cloud network.
  public let vnicId: String?

  public init(vnicId: String? = nil) {
    self.vnicId = vnicId
  }
}
