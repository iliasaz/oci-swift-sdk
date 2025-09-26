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

public struct BucketSummary: Decodable {
  /// The compartment ID in which the bucket is authorized.
  public let compartmentId: String
  /// The OCID of the user who created the bucket.
  public let createdBy: String
  /// Defined tags for this resource.
  /// Example: {"Operations": {"CostCenter": "42"}}
  public let definedTags: [String: [String: String]]?
  /// The entity tag (ETag) for the bucket.
  public let etag: String
  ///Free-form tags for this resource.
  ///  Example: {"Department": "Finance"}
  public let freeformTags: [String: String]?
  /// The name of the bucket. Avoid entering confidential information
  public let name: String
  /// The Object Storage namespace in which the bucket lives.
  public let namespace: String
  /// The date and time the bucket was created, as described in RFC 2616.
  public let timeCreated: String
}
