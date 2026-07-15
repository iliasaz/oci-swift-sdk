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

/// Information to create a new container within a container instance.
///
/// The container created by this call contains both the tags specified in this object and any tags
/// specified in the parent container instance. The container is created in the same compartment,
/// availability domain, and fault domain as its container instance.
public struct CreateContainerDetails: Codable {
  /// A user-friendly name. Does not have to be unique, and it's changeable. Avoid entering confidential information. If you don't provide a name, a name is generated automatically.
  public let displayName: String?
  /// A URL identifying the image that the container runs in, such as docker.io/library/busybox:latest. If you do not provide a tag, the tag will default to latest. If no registry is provided, will default the registry to public docker hub `docker.io/library`. The registry used for container image must be reachable over the Container Instance's VNIC.
  public let imageUrl: String
  /// An optional command that overrides the ENTRYPOINT process. If you do not provide a value, the existing ENTRYPOINT process defined in the image is used.
  public let command: [String]?
  /// A list of string arguments for a container's ENTRYPOINT process. Many containers use an ENTRYPOINT process pointing to a shell (/bin/bash). For those containers, this argument list specifies the main command in the container process. The total size of all arguments combined must be 64 KB or smaller.
  public let arguments: [String]?
  /// The working directory within the container's filesystem for the container process. If not specified, the default working directory from the image is used.
  public let workingDirectory: String?
  /// A map of additional environment variables to set in the environment of the container's ENTRYPOINT process. These variables are in addition to any variables already defined in the container's image. The total size of all environment variables combined, name and values, must be 64 KB or smaller.
  public let environmentVariables: [String: String]?
  /// List of the volume mounts.
  public let volumeMounts: [CreateVolumeMountDetails]?
  /// Determines if the container will have access to the container instance resource principal. This method utilizes resource principal version 2.2.
  public let isResourcePrincipalDisabled: Bool?
  /// The size and amount of resources available to the container.
  public let resourceConfig: CreateContainerResourceConfigDetails?
  /// list of container health checks to check container status and take appropriate action if container status is failed. There are two types of health checks that we currently support HTTP and TCP.
  public let healthChecks: [CreateContainerHealthCheckDetails]?
  /// The security context to apply to the container.
  public let securityContext: CreateSecurityContextDetails?
  /// Simple key-value pair that is applied without any predefined name, type or scope. Exists for cross-compatibility only. Example: `{"bar-key": "value"}`
  public let freeformTags: [String: String]?
  /// Defined tags for this resource. Each key is predefined and scoped to a namespace. Example: `{"foo-namespace": {"bar-key": "value"}}`.
  public let definedTags: [String: [String: String]]?

  public init(
    displayName: String? = nil,
    imageUrl: String,
    command: [String]? = nil,
    arguments: [String]? = nil,
    workingDirectory: String? = nil,
    environmentVariables: [String: String]? = nil,
    volumeMounts: [CreateVolumeMountDetails]? = nil,
    isResourcePrincipalDisabled: Bool? = nil,
    resourceConfig: CreateContainerResourceConfigDetails? = nil,
    healthChecks: [CreateContainerHealthCheckDetails]? = nil,
    securityContext: CreateSecurityContextDetails? = nil,
    freeformTags: [String: String]? = nil,
    definedTags: [String: [String: String]]? = nil
  ) {
    self.displayName = displayName
    self.imageUrl = imageUrl
    self.command = command
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environmentVariables = environmentVariables
    self.volumeMounts = volumeMounts
    self.isResourcePrincipalDisabled = isResourcePrincipalDisabled
    self.resourceConfig = resourceConfig
    self.healthChecks = healthChecks
    self.securityContext = securityContext
    self.freeformTags = freeformTags
    self.definedTags = definedTags
  }
}
