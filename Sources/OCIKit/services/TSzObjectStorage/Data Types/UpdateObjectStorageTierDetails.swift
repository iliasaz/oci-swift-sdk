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

public struct UpdateObjectStorageTierDetails: Codable {
  ///    An object for which the storage tier needs to be changed.
  public let objectName: String
  /// The storage tier that the object should be moved to.
  /// Allowed values are:
  /// - Standard
  /// - InfrequentAccess
  /// - Archive
  public let storageTier: String
  /// The versionId of the object. Current object version is used by default.
  public let versionId: String?

  public init(objectName: String, storageTier: String, versionId: String? = nil) {
    self.objectName = objectName
    self.storageTier = storageTier
    self.versionId = versionId
  }
}
