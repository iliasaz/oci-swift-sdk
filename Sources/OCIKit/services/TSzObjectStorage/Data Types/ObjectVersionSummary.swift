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

public struct ObjectVersionSummary: Codable {
  /// Archival state of an object. This field is set only for objects in Archive tier.
  public let archivalState: ArchivalState?
  /// The current entity tag (ETag) for the object.
  public let etag: String?
  /// This flag will indicate if the version is deleted or not.
  public let isDeleteMarker: Bool
  /// Base64-encoded MD5 hash of the object data.
  public let md5: String?
  /// The name of the object. Avoid entering confidential information. Example: test/object1.log
  public let name: String
  /// Size of the object in bytes.
  public let size: Int?
  /// The storage tier that the object is stored in.
  public let storageTier: StorageTier?
  ///  The date and time the object was created, as described in RFC 2616.
  public let timeCreated: String?
  /// The date and time the object was modified, as described in RFC 2616, section 14.29.
  public let timeModified: String
  /// VersionId of the object.
  public let versionId: String
}
