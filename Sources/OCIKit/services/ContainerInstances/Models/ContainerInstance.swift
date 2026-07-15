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

/// A container instance to host containers.
///
/// If you delete a container instance, the record remains visible for a short period
/// of time before being permanently removed.
public struct ContainerInstance: Codable {
  /// An OCID that cannot be changed.
  public let id: String
  /// A user-friendly name. Does not have to be unique, and it's changeable. Avoid entering confidential information.
  public let displayName: String
  /// The OCID of the compartment.
  public let compartmentId: String
  /// TenantId id of the container instance.
  public let tenantId: String?
  /// Simple key-value pair that is applied without any predefined name, type or scope. Exists for cross-compatibility only.
  public let freeformTags: [String: String]?
  /// Defined tags for this resource. Each key is predefined and scoped to a namespace.
  public let definedTags: [String: [String: String]]?
  /// Usage of system tag keys. These predefined keys are scoped to namespaces.
  public let systemTags: [String: [String: String]]?
  /// The availability domain to place the container instance.
  public let availabilityDomain: String
  /// The fault domain to place the container instance.
  public let faultDomain: String?
  /// The current state of the container instance.
  public let lifecycleState: ContainerInstanceLifecycleState
  /// A message that describes the current state of the container in more detail. Can be used to provide actionable information.
  public let lifecycleDetails: String?
  /// A volume is a directory with data that is accessible across multiple containers in a container instance.
  public let volumes: [ContainerVolume]?
  /// The number of volumes that are attached to the container instance.
  public let volumeCount: Int?
  /// The containers on the container instance.
  public let containers: [ContainerInstanceContainer]
  /// The number of containers on the container instance.
  public let containerCount: Int
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
  /// The shape of the container instance. The shape determines the number of OCPUs, amount of memory, and other resources that are allocated to a container instance.
  public let shape: String
  /// The shape configuration for the container instance.
  public let shapeConfig: ContainerInstanceShapeConfig
  /// The virtual networks available to the containers in the container instance.
  public let vnics: [ContainerVnic]
  /// The DNS configuration for the container instance.
  public let dnsConfig: ContainerDnsConfig?
  /// The amount of time that processes in a container have to gracefully end when the container must be stopped. For example, when you delete a container instance. After the timeout is reached, the processes are sent a signal to be deleted.
  public let gracefulShutdownTimeoutInSeconds: Int?
  /// The image pulls secrets so you can access private registry to pull container images.
  public let imagePullSecrets: [ImagePullSecret]?
  /// The container restart policy is applied for all containers in container instance.
  public let containerRestartPolicy: ContainerRestartPolicy
  /// The security context for the container instance.
  public let securityContext: ContainerInstanceSecurityContext?

  public init(
    id: String,
    displayName: String,
    compartmentId: String,
    tenantId: String? = nil,
    freeformTags: [String: String]? = nil,
    definedTags: [String: [String: String]]? = nil,
    systemTags: [String: [String: String]]? = nil,
    availabilityDomain: String,
    faultDomain: String? = nil,
    lifecycleState: ContainerInstanceLifecycleState,
    lifecycleDetails: String? = nil,
    volumes: [ContainerVolume]? = nil,
    volumeCount: Int? = nil,
    containers: [ContainerInstanceContainer],
    containerCount: Int,
    timeCreatedRaw: String? = nil,
    timeUpdatedRaw: String? = nil,
    shape: String,
    shapeConfig: ContainerInstanceShapeConfig,
    vnics: [ContainerVnic],
    dnsConfig: ContainerDnsConfig? = nil,
    gracefulShutdownTimeoutInSeconds: Int? = nil,
    imagePullSecrets: [ImagePullSecret]? = nil,
    containerRestartPolicy: ContainerRestartPolicy,
    securityContext: ContainerInstanceSecurityContext? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.compartmentId = compartmentId
    self.tenantId = tenantId
    self.freeformTags = freeformTags
    self.definedTags = definedTags
    self.systemTags = systemTags
    self.availabilityDomain = availabilityDomain
    self.faultDomain = faultDomain
    self.lifecycleState = lifecycleState
    self.lifecycleDetails = lifecycleDetails
    self.volumes = volumes
    self.volumeCount = volumeCount
    self.containers = containers
    self.containerCount = containerCount
    self.timeCreatedRaw = timeCreatedRaw
    self.timeUpdatedRaw = timeUpdatedRaw
    self.shape = shape
    self.shapeConfig = shapeConfig
    self.vnics = vnics
    self.dnsConfig = dnsConfig
    self.gracefulShutdownTimeoutInSeconds = gracefulShutdownTimeoutInSeconds
    self.imagePullSecrets = imagePullSecrets
    self.containerRestartPolicy = containerRestartPolicy
    self.securityContext = securityContext
  }

  enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case compartmentId
    case tenantId
    case freeformTags
    case definedTags
    case systemTags
    case availabilityDomain
    case faultDomain
    case lifecycleState
    case lifecycleDetails
    case volumes
    case volumeCount
    case containers
    case containerCount
    case timeCreatedRaw = "timeCreated"
    case timeUpdatedRaw = "timeUpdated"
    case shape
    case shapeConfig
    case vnics
    case dnsConfig
    case gracefulShutdownTimeoutInSeconds
    case imagePullSecrets
    case containerRestartPolicy
    case securityContext
  }
}
