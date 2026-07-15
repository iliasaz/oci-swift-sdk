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

/// Container HTTP headers for an HTTP health check.
public struct HealthCheckHttpHeader: Codable {
  /// Container HTTP header key.
  public let name: String?
  /// Container HTTP header value.
  public let value: String?

  public init(name: String? = nil, value: String? = nil) {
    self.name = name
    self.value = value
  }
}
