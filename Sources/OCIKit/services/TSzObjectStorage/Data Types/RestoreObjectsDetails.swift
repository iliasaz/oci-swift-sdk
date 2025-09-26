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

public struct RestoreObjectsDetails: Codable {
  /// The number of hours for which this object will be restored. By default objects will be restored for 24 hours. You can instead configure the duration using the hours parameter. Min 1, max 240
  public let hours: Int?
  /// An object that is in an archive storage tier and needs to be restored.
  public let objectName: String
  /// The versionId of the object to restore. Current object version is used by default.
  public let versionId: String?

  public init(hours: Int? = nil, objectName: String, versionId: String? = nil) {
    self.hours = hours
    self.objectName = objectName
    self.versionId = versionId
  }
}
