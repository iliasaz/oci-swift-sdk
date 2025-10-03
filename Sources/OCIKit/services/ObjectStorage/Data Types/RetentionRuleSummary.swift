//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2025 Szabolcs Tóth and the oci-swift-sdk project authors
// Licensed under MIT License
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of oci-swift-sdk project authors
//
// SPDX-License-Identifier: MIT License
//
//===----------------------------------------------------------------------===//

import Foundation

/// The summary of a retention rule.
public struct RetentionRuleSummary: Codable {
  /// User specified name for the retention rule.
  public let displayName: String
  public let duration: Duration?
  /// The entity tag (ETag) for the retention rule.
  public let etag: String
  /// Unique identifier for the retention rule.
  public let id: String
  /// The raw string value of the creation time from the server.
  public let timeCreatedRaw: String
  /// The raw string value of the modified time from the server.
  private let timeModifiedRaw: String
  /// The raw string value of the rule lock time from the server.
  private let timeRuleLockedRaw: String?

  /// The date and time that the retention rule was created as a `Date`.
  public var timeCreated: Date? {
      Date.fromRFC3339(timeCreatedRaw)
  }

  /// The date and time that the retention rule was modified as a `Date`.
  public var timeModified: Date? {
      Date.fromRFC3339(timeModifiedRaw)
  }

  /// The date and time as per as `Date` after which this rule becomes locked.
  public var timeRuleLocked: Date? {
    guard let raw = timeRuleLockedRaw else { return nil }
      return Date.fromRFC3339(raw)
  }

  // Custom CodingKeys to map raw string fields to their JSON keys
  private enum CodingKeys: String, CodingKey {
    case displayName
    case duration
    case etag
    case id
    case timeCreatedRaw = "timeCreated"
    case timeModifiedRaw = "timeModified"
    case timeRuleLockedRaw = "timeRuleLocked"
  }
}
