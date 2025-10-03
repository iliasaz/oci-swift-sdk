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

/// The details to create a retention rule.
public struct CreateRetentionRuleDetails: Codable {
  /// A user-specified name for the retention rule. Names can be helpful in identifying retention rules. Avoid entering confidential information.
  public let displayName: String
  /// The amount of time that objects in the bucket should be preserved for and which is calculated in relation to each object's Last-Modified timestamp. If duration is not present, then there is no time limit and the objects in the bucket will be preserved indefinitely.
  public let duration: Duration?
  /// The date and time as per RFC 3339 after which this rule is locked and can only be deleted by deleting the bucket. Once a rule is locked, only increases in the duration are allowed and no other properties can be changed. This property cannot be updated for rules that are in a locked state. Specifying it when a duration is not specified is considered an error.
  public let timeRuleLocked: String?
    
    public init(displayName: String, duration: Duration? = nil, timeRuleLocked: Date? = nil) {
        self.displayName = displayName
        self.duration = duration
        self.timeRuleLocked = timeRuleLocked?.toRFC3339()
    }
}
