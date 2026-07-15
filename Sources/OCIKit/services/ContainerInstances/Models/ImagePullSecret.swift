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

/// The image pull secrets for accessing private registry to pull images for containers.
public struct ImagePullSecret: Codable {
  /// The type of ImagePullSecret.
  public let secretType: ImagePullSecretType
  /// The registry endpoint of the container image.
  public let registryEndpoint: String

  public init(secretType: ImagePullSecretType, registryEndpoint: String) {
    self.secretType = secretType
    self.registryEndpoint = registryEndpoint
  }
}
