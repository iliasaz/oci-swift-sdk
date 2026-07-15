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

/// Summary information about a container.
public struct ContainerSummary: Codable {
  /// The OCID of the container.
  public let id: String
  /// A user-friendly name. Does not have to be unique, and it's changeable. Avoid entering confidential information.
  public let displayName: String
  /// The compartment OCID.
  public let compartmentId: String
  /// Simple key-value pair that is applied without any predefined name, type or scope. Exists for cross-compatibility only.
  public let freeformTags: [String: String]?
  /// Defined tags for this resource. Each key is predefined and scoped to a namespace.
  public let definedTags: [String: [String: String]]?
  /// Usage of system tag keys. These predefined keys are scoped to namespaces.
  public let systemTags: [String: [String: String]]?
  /// The availability domain where the container instance that hosts this container runs.
  public let availabilityDomain: String
  /// The fault domain where the container instance that hosts the container runs.
  public let faultDomain: String?
  /// The current state of the container.
  public let lifecycleState: ContainerInstanceLifecycleState
  /// A message that describes the current state of the container in more detail. Can be used to provide actionable information.
  public let lifecycleDetails: String?
  /// The time the container was created, as a raw RFC3339 string.
  private let timeCreatedRaw: String?
  /// The time the container was created.
  public var timeCreated: Date? {
    guard let raw = timeCreatedRaw else { return nil }
    return Date.fromRFC3339(raw)
  }
  /// The time the container was updated, as a raw RFC3339 string.
  private let timeUpdatedRaw: String?
  /// The time the container was updated.
  public var timeUpdated: Date? {
    guard let raw = timeUpdatedRaw else { return nil }
    return Date.fromRFC3339(raw)
  }
  /// The OCID of the container instance on which the container is running.
  public let containerInstanceId: String
  /// The resource configuration for the container.
  public let resourceConfig: ContainerResourceConfig?
  /// A URL identifying the image that the container runs in, such as docker.io/library/busybox:latest.
  public let imageUrl: String
  /// Determines whether the container will have access to the container instance resource principal.
  public let isResourcePrincipalDisabled: Bool?
  /// The security context of the container.
  public let securityContext: SecurityContext?

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
    containerInstanceId: String,
    resourceConfig: ContainerResourceConfig? = nil,
    imageUrl: String,
    isResourcePrincipalDisabled: Bool? = nil,
    securityContext: SecurityContext? = nil
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
    self.containerInstanceId = containerInstanceId
    self.resourceConfig = resourceConfig
    self.imageUrl = imageUrl
    self.isResourcePrincipalDisabled = isResourcePrincipalDisabled
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
    case containerInstanceId
    case resourceConfig
    case imageUrl
    case isResourcePrincipalDisabled
    case securityContext
  }
}
