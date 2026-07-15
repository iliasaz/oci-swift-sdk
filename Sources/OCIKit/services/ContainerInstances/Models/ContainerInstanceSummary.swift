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

/// A set of details about a single container instance returned by list APIs.
public struct ContainerInstanceSummary: Codable {
  /// OCID that cannot be changed.
  public let id: String
  /// A user-friendly name. Does not have to be unique, and it's changeable. Avoid entering confidential information.
  public let displayName: String
  /// The OCID of the compartment to create the container instance in.
  public let compartmentId: String
  /// Simple key-value pair that is applied without any predefined name, type or scope. Exists for cross-compatibility only.
  public let freeformTags: [String: String]?
  /// Defined tags for this resource. Each key is predefined and scoped to a namespace.
  public let definedTags: [String: [String: String]]?
  /// Usage of system tag keys. These predefined keys are scoped to namespaces.
  public let systemTags: [String: [String: String]]?
  /// The availability domain where the container instance runs.
  public let availabilityDomain: String
  /// The fault domain where the container instance runs.
  public let faultDomain: String?
  /// The current state of the container instance.
  public let lifecycleState: ContainerInstanceLifecycleState
  /// A message that describes the current state of the container instance in more detail. Can be used to provide actionable information.
  public let lifecycleDetails: String?
  /// The time the container instance was created, as a raw RFC3339 string.
  private let timeCreatedRaw: String?
  /// The time the container instance was created.
  public var timeCreated: Date? {
    guard let raw = timeCreatedRaw else { return nil }
    return Date.fromRFC3339(raw)
  }
  /// The time the container instance was updated, as a raw RFC3339 string.
  private let timeUpdatedRaw: String?
  /// The time the container instance was updated.
  public var timeUpdated: Date? {
    guard let raw = timeUpdatedRaw else { return nil }
    return Date.fromRFC3339(raw)
  }
  /// The shape of the container instance. The shape determines the resources available to the container instance.
  public let shape: String
  /// The shape configuration for the container instance.
  public let shapeConfig: ContainerInstanceShapeConfig
  /// The number of containers in the container instance.
  public let containerCount: Int
  /// The amount of time that processes in a container have to gracefully end when the container must be stopped. For example, when you delete a container instance. After the timeout is reached, the processes are sent a signal to be deleted.
  public let gracefulShutdownTimeoutInSeconds: Int?
  /// The number of volumes that are attached to the container instance.
  public let volumeCount: Int?
  /// Container Restart Policy.
  public let containerRestartPolicy: ContainerRestartPolicy
  /// The security context for the container instance.
  public let securityContext: ContainerInstanceSecurityContext?

  public init(
    id: String,
    displayName: String,
    compartmentId: String,
    freeformTags: [String: String]? = nil,
    definedTags: [String: [String: String]]? = nil,
    systemTags: [String: [String: String]]? = nil,
    availabilityDomain: String,
    faultDomain: String? = nil,
    lifecycleState: ContainerInstanceLifecycleState,
    lifecycleDetails: String? = nil,
    timeCreatedRaw: String? = nil,
    timeUpdatedRaw: String? = nil,
    shape: String,
    shapeConfig: ContainerInstanceShapeConfig,
    containerCount: Int,
    gracefulShutdownTimeoutInSeconds: Int? = nil,
    volumeCount: Int? = nil,
    containerRestartPolicy: ContainerRestartPolicy,
    securityContext: ContainerInstanceSecurityContext? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.compartmentId = compartmentId
    self.freeformTags = freeformTags
    self.definedTags = definedTags
    self.systemTags = systemTags
    self.availabilityDomain = availabilityDomain
    self.faultDomain = faultDomain
    self.lifecycleState = lifecycleState
    self.lifecycleDetails = lifecycleDetails
    self.timeCreatedRaw = timeCreatedRaw
    self.timeUpdatedRaw = timeUpdatedRaw
    self.shape = shape
    self.shapeConfig = shapeConfig
    self.containerCount = containerCount
    self.gracefulShutdownTimeoutInSeconds = gracefulShutdownTimeoutInSeconds
    self.volumeCount = volumeCount
    self.containerRestartPolicy = containerRestartPolicy
    self.securityContext = securityContext
  }

  enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case compartmentId
    case freeformTags
    case definedTags
    case systemTags
    case availabilityDomain
    case faultDomain
    case lifecycleState
    case lifecycleDetails
    case timeCreatedRaw = "timeCreated"
    case timeUpdatedRaw = "timeUpdated"
    case shape
    case shapeConfig
    case containerCount
    case gracefulShutdownTimeoutInSeconds
    case volumeCount
    case containerRestartPolicy
    case securityContext
  }
}
