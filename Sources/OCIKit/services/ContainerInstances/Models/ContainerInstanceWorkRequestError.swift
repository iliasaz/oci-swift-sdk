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

/// An error encountered while executing a work request.
public struct ContainerInstanceWorkRequestError: Codable {
  /// A machine-usable code for the error that occured. See API Errors for a list of error codes.
  public let code: String
  /// A description of the issue encountered.
  public let message: String
  /// The time the error occured, as a raw RFC3339 string.
  private let timestampRaw: String
  /// The time the error occured, in the format defined by RFC 3339.
  public var timestamp: Date? {
    return Date.fromRFC3339(timestampRaw)
  }

  public init(
    code: String,
    message: String,
    timestampRaw: String
  ) {
    self.code = code
    self.message = message
    self.timestampRaw = timestampRaw
  }

  enum CodingKeys: String, CodingKey {
    case code
    case message
    case timestampRaw = "timestamp"
  }
}
