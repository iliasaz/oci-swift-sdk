//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2025 Szabolcs Toth and the oci-swift-sdk project authors
// Licensed under MIT License
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of oci-swift-sdk project authors
//
// SPDX-License-Identifier: MIT License
//
//===----------------------------------------------------------------------===//

import Foundation

public struct SSECustomerKeyDetails: Codable {
  // Specifies the encryption algorithm. The only supported value is "AES256".
  public var algorithm: String = "AES256"
  // Specifies the base64-encoded 256-bit encryption key to use to encrypt or decrypt the object data.
  public let key: String
  // Specifies the base64-encoded SHA256 hash of the encryption key. This value is used to check the integrity of the encryption key.
  public let keySha256: String
}
