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

/// A summary of the status of a work request.
public struct ContainerInstanceWorkRequestSummary: Codable {
  /// Type of work request.
  public let operationType: ContainerInstanceWorkRequestOperationType
  /// Status of current work request.
  public let status: ContainerInstanceWorkRequestStatus
  /// The ID of the work request.
  public let id: String
  /// The OCID of the compartment that contains the work request. Work requests should be scoped to
  /// the same compartment as the resource the work request affects.
  public let compartmentId: String
  /// The resources affected by this work request.
  public let resources: [ContainerInstanceWorkRequestResource]
  /// Percentage of the request completed.
  public let percentComplete: Float
  /// The date and time the request was created, as a raw RFC3339 string.
  private let timeAcceptedRaw: String
  /// The date and time the request was created, as described in RFC 3339, section 14.29.
  public var timeAccepted: Date? {
    return Date.fromRFC3339(timeAcceptedRaw)
  }
  /// The date and time the request was started, as a raw RFC3339 string.
  private let timeStartedRaw: String?
  /// The date and time the request was started, as described in RFC 3339, section 14.29.
  public var timeStarted: Date? {
    guard let raw = timeStartedRaw else { return nil }
    return Date.fromRFC3339(raw)
  }
  /// The date and time the object was finished, as a raw RFC3339 string.
  private let timeFinishedRaw: String?
  /// The date and time the object was finished, as described in RFC 3339.
  public var timeFinished: Date? {
    guard let raw = timeFinishedRaw else { return nil }
    return Date.fromRFC3339(raw)
  }

  public init(
    operationType: ContainerInstanceWorkRequestOperationType,
    status: ContainerInstanceWorkRequestStatus,
    id: String,
    compartmentId: String,
    resources: [ContainerInstanceWorkRequestResource],
    percentComplete: Float,
    timeAcceptedRaw: String,
    timeStartedRaw: String? = nil,
    timeFinishedRaw: String? = nil
  ) {
    self.operationType = operationType
    self.status = status
    self.id = id
    self.compartmentId = compartmentId
    self.resources = resources
    self.percentComplete = percentComplete
    self.timeAcceptedRaw = timeAcceptedRaw
    self.timeStartedRaw = timeStartedRaw
    self.timeFinishedRaw = timeFinishedRaw
  }

  enum CodingKeys: String, CodingKey {
    case operationType
    case status
    case id
    case compartmentId
    case resources
    case percentComplete
    case timeAcceptedRaw = "timeAccepted"
    case timeStartedRaw = "timeStarted"
    case timeFinishedRaw = "timeFinished"
  }
}
