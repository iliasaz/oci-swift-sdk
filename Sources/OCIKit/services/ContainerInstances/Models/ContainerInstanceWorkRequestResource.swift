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

/// A resource created or operated on by a work request.
public struct ContainerInstanceWorkRequestResource: Codable {
  /// The resource type the work request affects.
  public let entityType: String
  /// The way in which this resource is affected by the work tracked in the work request.
  /// A resource being created, updated, or deleted remains in the IN_PROGRESS state until
  /// work is complete for that resource, at which point it updates to CREATED, UPDATED,
  /// or DELETED, respectively.
  public let actionType: ContainerInstanceWorkRequestActionType
  /// The ID of the resource the work request affects.
  public let identifier: String
  /// The URI path that the user can do a GET on to access the resource metadata.
  public let entityUri: String?

  public init(
    entityType: String,
    actionType: ContainerInstanceWorkRequestActionType,
    identifier: String,
    entityUri: String? = nil
  ) {
    self.entityType = entityType
    self.actionType = actionType
    self.identifier = identifier
    self.entityUri = entityUri
  }
}
