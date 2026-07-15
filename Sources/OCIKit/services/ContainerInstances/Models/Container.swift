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

/// A single container on a container instance.
///
/// If you delete a container, the record remains visible for a short period
/// of time before being permanently removed.
public struct Container: Codable {
  /// The OCID of the container.
  public let id: String
  /// A user-friendly name. Does not have to be unique, and it's changeable. Avoid entering confidential information.
  public let displayName: String
  /// The OCID of the compartment that contains the container.
  public let compartmentId: String
  /// Simple key-value pair that is applied without any predefined name, type or scope. Exists for cross-compatibility only.
  public let freeformTags: [String: String]?
  /// Defined tags for this resource. Each key is predefined and scoped to a namespace.
  public let definedTags: [String: [String: String]]?
  /// Usage of system tag keys. These predefined keys are scoped to namespaces.
  public let systemTags: [String: [String: String]]?
  /// The availability domain where the container instance that hosts the container runs.
  public let availabilityDomain: String
  /// The fault domain of the container instance that hosts the container runs.
  public let faultDomain: String?
  /// The current state of the container.
  public let lifecycleState: ContainerInstanceLifecycleState
  /// A message that describes the current state of the container in more detail. Can be used to provide actionable information.
  public let lifecycleDetails: String?
  /// The exit code of the container process when it stopped running.
  public let exitCode: Int?
  /// The time when the container last deleted (terminated), as a raw RFC3339 string.
  private let timeTerminatedRaw: String?
  /// The time when the container last deleted (terminated).
  public var timeTerminated: Date? {
    guard let raw = timeTerminatedRaw else { return nil }
    return Date.fromRFC3339(raw)
  }
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
  /// The OCID of the container instance that the container is running on.
  public let containerInstanceId: String
  /// The container image information. Currently only supports public Docker registry.
  public let imageUrl: String
  /// This command overrides ENTRYPOINT process of the container.
  public let command: [String]?
  /// A list of string arguments for the ENTRYPOINT process of the container.
  public let arguments: [String]?
  /// The working directory within the container's filesystem for the container process.
  public let workingDirectory: String?
  /// A map of additional environment variables to set in the environment of the ENTRYPOINT process of the container.
  public let environmentVariables: [String: String]?
  /// List of the volume mounts.
  public let volumeMounts: [VolumeMount]?
  /// List of container health checks.
  public let healthChecks: [ContainerHealthCheck]?
  /// Determines if the container will have access to the container instance resource principal.
  public let isResourcePrincipalDisabled: Bool?
  /// The resource configuration for the container.
  public let resourceConfig: ContainerResourceConfig?
  /// The number of container restart attempts. Depending on the restart policy, a restart might be attempted after a health check failure or a container exit.
  public let containerRestartAttemptCount: Int?
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
    exitCode: Int? = nil,
    timeTerminatedRaw: String? = nil,
    timeCreatedRaw: String? = nil,
    timeUpdatedRaw: String? = nil,
    containerInstanceId: String,
    imageUrl: String,
    command: [String]? = nil,
    arguments: [String]? = nil,
    workingDirectory: String? = nil,
    environmentVariables: [String: String]? = nil,
    volumeMounts: [VolumeMount]? = nil,
    healthChecks: [ContainerHealthCheck]? = nil,
    isResourcePrincipalDisabled: Bool? = nil,
    resourceConfig: ContainerResourceConfig? = nil,
    containerRestartAttemptCount: Int? = nil,
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
    self.exitCode = exitCode
    self.timeTerminatedRaw = timeTerminatedRaw
    self.timeCreatedRaw = timeCreatedRaw
    self.timeUpdatedRaw = timeUpdatedRaw
    self.containerInstanceId = containerInstanceId
    self.imageUrl = imageUrl
    self.command = command
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environmentVariables = environmentVariables
    self.volumeMounts = volumeMounts
    self.healthChecks = healthChecks
    self.isResourcePrincipalDisabled = isResourcePrincipalDisabled
    self.resourceConfig = resourceConfig
    self.containerRestartAttemptCount = containerRestartAttemptCount
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
    case exitCode
    case timeTerminatedRaw = "timeTerminated"
    case timeCreatedRaw = "timeCreated"
    case timeUpdatedRaw = "timeUpdated"
    case containerInstanceId
    case imageUrl
    case command
    case arguments
    case workingDirectory
    case environmentVariables
    case volumeMounts
    case healthChecks
    case isResourcePrincipalDisabled
    case resourceConfig
    case containerRestartAttemptCount
    case securityContext
  }
}
