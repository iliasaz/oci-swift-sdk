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
public struct CreateImagePullSecretDetails: Codable {
  /// The type of ImagePullSecret.
  public let secretType: ImagePullSecretType
  /// The registry endpoint of the container image.
  public let registryEndpoint: String
  /// (BASIC only) The username which should be used with the registry for authentication. The value is expected in base64 format.
  public let username: String?
  /// (BASIC only) The password which should be used with the registry for authentication. The value is expected in base64 format.
  public let password: String?
  /// (VAULT only) The OCID of the secret for registry credentials.
  public let secretId: String?

  public init(
    secretType: ImagePullSecretType,
    registryEndpoint: String,
    username: String? = nil,
    password: String? = nil,
    secretId: String? = nil
  ) {
    self.secretType = secretType
    self.registryEndpoint = registryEndpoint
    self.username = username
    self.password = password
    self.secretId = secretId
  }

  /// Creates a BASIC image pull secret which accepts username and password (base64-encoded) as credentials.
  public static func basic(registryEndpoint: String, username: String, password: String) -> CreateImagePullSecretDetails {
    CreateImagePullSecretDetails(secretType: .basic, registryEndpoint: registryEndpoint, username: username, password: password)
  }

  /// Creates a VAULT image pull secret which accepts a secret OCID as credentials.
  public static func vault(registryEndpoint: String, secretId: String) -> CreateImagePullSecretDetails {
    CreateImagePullSecretDetails(secretType: .vault, registryEndpoint: registryEndpoint, secretId: secretId)
  }
}
