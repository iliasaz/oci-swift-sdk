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

public struct ReencryptObjectDetails: Codable {
  // The OCID of the master encryption key used to call the Vault service to re-encrypt the data encryption keys associated with the object and its chunks. If the kmsKeyId value is empty, whether null or an empty string, the API will perform re-encryption by using the kmsKeyId associated with the bucket or the master encryption key managed by Oracle, depending on the bucket encryption mechanism.
  public let kmsKeyId: String?
  // Specifies the details of the customer-provided encryption key (SSE-C) associated with an object.
  public let sourceSseCustomerKey: SSECustomerKeyDetails?
  // Specifies the details of the customer-provided encryption key (SSE-C) associated with an object.
  public let sseCustomerKey: SSECustomerKeyDetails?

  public init(kmsKeyId: String? = nil, sourceSseCustomerKey: SSECustomerKeyDetails? = nil, sseCustomerKey: SSECustomerKeyDetails? = nil) {
    self.kmsKeyId = kmsKeyId
    self.sourceSseCustomerKey = sourceSseCustomerKey
    self.sseCustomerKey = sseCustomerKey
  }
}
