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

/// A log message from a work request.
public struct ContainerInstanceWorkRequestLogEntry: Codable {
  /// Human-readable log message.
  public let message: String
  /// The time the log message was written, as a raw RFC3339 string.
  private let timestampRaw: String
  /// The time the log message was written, in the format defined by RFC 3339.
  public var timestamp: Date? {
    return Date.fromRFC3339(timestampRaw)
  }

  public init(
    message: String,
    timestampRaw: String
  ) {
    self.message = message
    self.timestampRaw = timestampRaw
  }

  enum CodingKeys: String, CodingKey {
    case message
    case timestampRaw = "timestamp"
  }
}
