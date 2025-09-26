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

public struct RenameObjectDetails: Codable {
  /// The new name of the source object. Avoid entering confidential information.
  public let newName: String
  /// The if-match entity tag (ETag) of the new object.
  public let newObjIfMatchETag: String?
  /// The if-none-match entity tag (ETag) of the new object. The only valid value is '*', which indicates request should fail if the new object already exists.
  public let newObjIfNoneMatchETag: String?
  /// The name of the source object to be renamed.
  public let sourceName: String
  /// The if-match entity tag (ETag) of the source object.
  public let srcObjIfMatchETag: String?

  public init(newName: String, newObjIfMatchETag: String? = nil, newObjIfNoneMatchETag: String? = nil, sourceName: String, srcObjIfMatchETag: String? = nil) {
    self.newName = newName
    self.newObjIfMatchETag = newObjIfMatchETag
    self.newObjIfNoneMatchETag = newObjIfNoneMatchETag
    self.sourceName = sourceName
    self.srcObjIfMatchETag = srcObjIfMatchETag
  }
}
