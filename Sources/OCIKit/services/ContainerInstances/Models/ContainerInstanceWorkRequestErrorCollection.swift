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

/// Results of a workRequestError search. Contains both WorkRequestError items and other information, such as metadata.
public struct ContainerInstanceWorkRequestErrorCollection: Codable {
  /// List of workRequestError objects.
  public let items: [ContainerInstanceWorkRequestError]

  public init(items: [ContainerInstanceWorkRequestError]) {
    self.items = items
  }
}
