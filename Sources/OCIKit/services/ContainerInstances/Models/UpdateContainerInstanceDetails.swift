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

/// The information to be updated.
public struct UpdateContainerInstanceDetails: Codable {
  /// A user-friendly name. Does not have to be unique, and it's changeable. Avoid entering confidential information.
  public let displayName: String?
  /// Simple key-value pair that is applied without any predefined name, type or scope. Exists for cross-compatibility only. Example: `{"bar-key": "value"}`
  public let freeformTags: [String: String]?
  /// Defined tags for this resource. Each key is predefined and scoped to a namespace. Example: `{"foo-namespace": {"bar-key": "value"}}`.
  public let definedTags: [String: [String: String]]?

  public init(
    displayName: String? = nil,
    freeformTags: [String: String]? = nil,
    definedTags: [String: [String: String]]? = nil
  ) {
    self.displayName = displayName
    self.freeformTags = freeformTags
    self.definedTags = definedTags
  }
}
