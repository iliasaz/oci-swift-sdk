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

/// The parameters required by Object Storage to process a request to copy an object to another bucket.
public struct CopyObjectDetails: Codable {
  /// The destination bucket the object will be copied to.
  public let destinationBucket: String
  /// The destination Object Storage namespace the object will be copied to.
  public let destinationNamespace: String
  /// The entity tag (ETag) to match against that of the destination object (an object intended to be overwritten).
  /// Used to confirm that the destination object stored under a given name is the version of that object storing a specified entity tag.
  public let destinationObjectIfMatchETag: String?
  /// The entity tag (ETag) to avoid matching. The only valid value is '*', which indicates that the request should fail
  /// if the object already exists in the destination bucket.
  public let destinationObjectIfNoneMatchETag: String?
  /// Arbitrary string keys and values for the user-defined metadata for the object.
  /// Keys must be in "opc-meta-*" format. Avoid entering confidential information.
  /// If no metadata is provided, the destination object inherits metadata from the source object.
  public let destinationObjectMetadata: [String: String]?
  /// The name of the destination object resulting from the copy operation. Avoid entering confidential information.
  public let destinationObjectName: String
  /// The storage tier that the object should be stored in. If not specified, the object will be stored in the same storage tier as the bucket.
  /// Allowed values: Standard, InfrequentAccess, Archive
  public let destinationObjectStorageTier: String?
  /// The destination region the object will be copied to, for example "us-ashburn-1".
  public let destinationRegion: String
  /// The entity tag (ETag) to match against that of the source object.
  /// Used to confirm that the source object with a given name is the version of that object storing a specified ETag.
  public let sourceObjectIfMatchETag: String?
  /// The name of the object to be copied.
  public let sourceObjectName: String

  /// VersionId of the object to copy. If not provided, the current version is copied by default.
  public let sourceVersionId: String?

  public init(
    destinationBucket: String,
    destinationNamespace: String,
    destinationObjectIfMatchETag: String? = nil,
    destinationObjectIfNoneMatchETag: String? = nil,
    destinationObjectMetadata: [String: String]? = nil,
    destinationObjectName: String,
    destinationObjectStorageTier: String? = nil,
    destinationRegion: String,
    sourceObjectIfMatchETag: String? = nil,
    sourceObjectName: String,
    sourceVersionId: String? = nil
  ) {
    self.destinationBucket = destinationBucket
    self.destinationNamespace = destinationNamespace
    self.destinationObjectIfMatchETag = destinationObjectIfMatchETag
    self.destinationObjectIfNoneMatchETag = destinationObjectIfNoneMatchETag
    self.destinationObjectMetadata = destinationObjectMetadata
    self.destinationObjectName = destinationObjectName
    self.destinationObjectStorageTier = destinationObjectStorageTier
    self.destinationRegion = destinationRegion
    self.sourceObjectIfMatchETag = sourceObjectIfMatchETag
    self.sourceObjectName = sourceObjectName
    self.sourceVersionId = sourceVersionId
  }
}
