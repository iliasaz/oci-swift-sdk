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

// MARK: - Lifecycle

/// The lifecycle state of a container instance or container.
///
/// The same value domain is used by both `ContainerInstance`/`ContainerInstanceSummary`
/// and `Container`/`ContainerSummary`.
public enum ContainerInstanceLifecycleState: String, Codable, Sendable {
  case creating = "CREATING"
  case updating = "UPDATING"
  case active = "ACTIVE"
  case inactive = "INACTIVE"
  case deleting = "DELETING"
  case deleted = "DELETED"
  case failed = "FAILED"
}

/// The restart policy applied to the containers of a container instance.
public enum ContainerRestartPolicy: String, Codable, Sendable {
  case always = "ALWAYS"
  case never = "NEVER"
  case onFailure = "ON_FAILURE"
}

// MARK: - Image pull secrets / volumes

/// The type of an image pull secret used to authenticate to a container registry.
public enum ImagePullSecretType: String, Codable, Sendable {
  case basic = "BASIC"
  case vault = "VAULT"
}

/// The type of a container volume.
public enum ContainerVolumeType: String, Codable, Sendable {
  case emptyDir = "EMPTYDIR"
  case configFile = "CONFIGFILE"
  case ociFssFileSystem = "OCI_FSS_FILE_SYSTEM"
}

// MARK: - Health checks

/// The protocol/type of a container health check.
public enum ContainerHealthCheckType: String, Codable, Sendable {
  case http = "HTTP"
  case tcp = "TCP"
  case command = "COMMAND"
}

/// The action performed when a container health check fails.
public enum ContainerHealthCheckFailureAction: String, Codable, Sendable {
  case kill = "KILL"
  case none = "NONE"
}

/// The observed health status of a container.
public enum ContainerHealthCheckStatus: String, Codable, Sendable {
  case unknown = "UNKNOWN"
  case healthy = "HEALTHY"
  case unhealthy = "UNHEALTHY"
}

// MARK: - Security context

/// The type of a container / container-instance security context.
public enum SecurityContextType: String, Codable, Sendable {
  case linux = "LINUX"
}

// MARK: - Work requests

/// The status of a container instances work request.
public enum ContainerInstanceWorkRequestStatus: String, Codable, Sendable {
  case accepted = "ACCEPTED"
  case inProgress = "IN_PROGRESS"
  case failed = "FAILED"
  case succeeded = "SUCCEEDED"
  case canceling = "CANCELING"
  case canceled = "CANCELED"
}

/// The type of operation a container instances work request represents.
public enum ContainerInstanceWorkRequestOperationType: String, Codable, Sendable {
  case createContainerInstance = "CREATE_CONTAINER_INSTANCE"
  case updateContainerInstance = "UPDATE_CONTAINER_INSTANCE"
  case deleteContainerInstance = "DELETE_CONTAINER_INSTANCE"
  case moveContainerInstance = "MOVE_CONTAINER_INSTANCE"
  case startContainerInstance = "START_CONTAINER_INSTANCE"
  case stopContainerInstance = "STOP_CONTAINER_INSTANCE"
  case restartContainerInstance = "RESTART_CONTAINER_INSTANCE"
  case updateContainer = "UPDATE_CONTAINER"
}

/// The effect a work request had on an affected resource.
public enum ContainerInstanceWorkRequestActionType: String, Codable, Sendable {
  case created = "CREATED"
  case updated = "UPDATED"
  case deleted = "DELETED"
  case inProgress = "IN_PROGRESS"
  case related = "RELATED"
  case failed = "FAILED"
}

// MARK: - Sorting

/// The field to sort container instances / containers by.
public enum ContainerInstanceSortBy: String, Codable, Sendable {
  case timeCreated
  case displayName
}
