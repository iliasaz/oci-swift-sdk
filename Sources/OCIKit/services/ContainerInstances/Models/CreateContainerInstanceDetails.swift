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

/// Information to create a container instance.
public struct CreateContainerInstanceDetails: Codable {
  /// A user-friendly name. Does not have to be unique, and it's changeable. Avoid entering confidential information. If you don't provide a name, a name is generated automatically.
  public let displayName: String?
  /// The compartment OCID.
  public let compartmentId: String
  /// The availability domain where the container instance runs.
  public let availabilityDomain: String
  /// The fault domain where the container instance runs.
  public let faultDomain: String?
  /// The shape of the container instance. The shape determines the resources available to the container instance.
  public let shape: String
  /// The size and amount of resources available to the container instance.
  public let shapeConfig: CreateContainerInstanceShapeConfigDetails
  /// A volume is a directory with data that is accessible across multiple containers in a container instance. You can attach up to 32 volumes to single container instance.
  public let volumes: [CreateContainerVolumeDetails]?
  /// The containers to create on this container instance.
  public let containers: [CreateContainerDetails]
  /// The networks available to containers on this container instance.
  public let vnics: [CreateContainerVnicDetails]
  /// The DNS configuration of the container instance.
  public let dnsConfig: CreateContainerDnsConfigDetails?
  /// The amount of time that processes in a container have to gracefully end when the container must be stopped. For example, when you delete a container instance. After the timeout is reached, the processes are sent a signal to be deleted.
  public let gracefulShutdownTimeoutInSeconds: Int?
  /// The image pulls secrets so you can access private registry to pull container images.
  public let imagePullSecrets: [CreateImagePullSecretDetails]?
  /// Container restart policy
  public let containerRestartPolicy: ContainerRestartPolicy?
  /// Simple key-value pair that is applied without any predefined name, type or scope. Exists for cross-compatibility only. Example: `{"bar-key": "value"}`
  public let freeformTags: [String: String]?
  /// Defined tags for this resource. Each key is predefined and scoped to a namespace. Example: `{"foo-namespace": {"bar-key": "value"}}`.
  public let definedTags: [String: [String: String]]?
  /// The security context to apply to the container instance.
  public let securityContext: CreateContainerInstanceSecurityContextDetails?

  public init(
    displayName: String? = nil,
    compartmentId: String,
    availabilityDomain: String,
    faultDomain: String? = nil,
    shape: String,
    shapeConfig: CreateContainerInstanceShapeConfigDetails,
    volumes: [CreateContainerVolumeDetails]? = nil,
    containers: [CreateContainerDetails],
    vnics: [CreateContainerVnicDetails],
    dnsConfig: CreateContainerDnsConfigDetails? = nil,
    gracefulShutdownTimeoutInSeconds: Int? = nil,
    imagePullSecrets: [CreateImagePullSecretDetails]? = nil,
    containerRestartPolicy: ContainerRestartPolicy? = nil,
    freeformTags: [String: String]? = nil,
    definedTags: [String: [String: String]]? = nil,
    securityContext: CreateContainerInstanceSecurityContextDetails? = nil
  ) {
    self.displayName = displayName
    self.compartmentId = compartmentId
    self.availabilityDomain = availabilityDomain
    self.faultDomain = faultDomain
    self.shape = shape
    self.shapeConfig = shapeConfig
    self.volumes = volumes
    self.containers = containers
    self.vnics = vnics
    self.dnsConfig = dnsConfig
    self.gracefulShutdownTimeoutInSeconds = gracefulShutdownTimeoutInSeconds
    self.imagePullSecrets = imagePullSecrets
    self.containerRestartPolicy = containerRestartPolicy
    self.freeformTags = freeformTags
    self.definedTags = definedTags
    self.securityContext = securityContext
  }
}
