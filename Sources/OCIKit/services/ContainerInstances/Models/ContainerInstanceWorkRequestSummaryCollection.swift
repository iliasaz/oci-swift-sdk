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

/// Results of a workRequest search. Contains both WorkRequest items and other information, such as metadata.
public struct ContainerInstanceWorkRequestSummaryCollection: Codable {
  /// List of workRequestSummary objects.
  public let items: [ContainerInstanceWorkRequestSummary]

  public init(items: [ContainerInstanceWorkRequestSummary]) {
    self.items = items
  }
}
