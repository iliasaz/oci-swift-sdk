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

/// Container health check used to check and report the status of a container.
///
/// This is a flattened union of the HTTP and TCP health check subtypes. The
/// `healthCheckType` discriminator selects which subtype-specific fields apply.
/// Prefer the `http(...)` and `tcp(...)` factory methods over the memberwise
/// initializer.
public struct CreateContainerHealthCheckDetails: Codable {
  /// Health check name.
  public let name: String?
  /// Container health check type.
  public let healthCheckType: ContainerHealthCheckType
  /// The initial delay in seconds before start checking container health status.
  public let initialDelayInSeconds: Int?
  /// Number of seconds between two consecutive runs for checking container health.
  public let intervalInSeconds: Int?
  /// Number of consecutive failures at which we consider the check failed.
  public let failureThreshold: Int?
  /// Number of consecutive successes at which we consider the check succeeded again after it was in failure state.
  public let successThreshold: Int?
  /// Length of waiting time in seconds before marking health check failed.
  public let timeoutInSeconds: Int?
  /// The action triggered when the container health check fails. There are two types of action: KILL or NONE.
  /// The default action is KILL. If the failure action is KILL, the container is subject to the container restart policy.
  public let failureAction: ContainerHealthCheckFailureAction?
  /// (HTTP only) Container health check HTTP path.
  public let path: String?
  /// (HTTP/TCP only) Container health check port.
  public let port: Int?
  /// (HTTP only) Container health check HTTP headers.
  public let headers: [HealthCheckHttpHeader]?

  public init(
    name: String? = nil,
    healthCheckType: ContainerHealthCheckType,
    initialDelayInSeconds: Int? = nil,
    intervalInSeconds: Int? = nil,
    failureThreshold: Int? = nil,
    successThreshold: Int? = nil,
    timeoutInSeconds: Int? = nil,
    failureAction: ContainerHealthCheckFailureAction? = nil,
    path: String? = nil,
    port: Int? = nil,
    headers: [HealthCheckHttpHeader]? = nil
  ) {
    self.name = name
    self.healthCheckType = healthCheckType
    self.initialDelayInSeconds = initialDelayInSeconds
    self.intervalInSeconds = intervalInSeconds
    self.failureThreshold = failureThreshold
    self.successThreshold = successThreshold
    self.timeoutInSeconds = timeoutInSeconds
    self.failureAction = failureAction
    self.path = path
    self.port = port
    self.headers = headers
  }

  /// Creates an HTTP container health check.
  public static func http(
    path: String,
    port: Int,
    name: String? = nil,
    initialDelayInSeconds: Int? = nil,
    intervalInSeconds: Int? = nil,
    failureThreshold: Int? = nil,
    successThreshold: Int? = nil,
    timeoutInSeconds: Int? = nil,
    failureAction: ContainerHealthCheckFailureAction? = nil,
    headers: [HealthCheckHttpHeader]? = nil
  ) -> CreateContainerHealthCheckDetails {
    CreateContainerHealthCheckDetails(
      name: name,
      healthCheckType: .http,
      initialDelayInSeconds: initialDelayInSeconds,
      intervalInSeconds: intervalInSeconds,
      failureThreshold: failureThreshold,
      successThreshold: successThreshold,
      timeoutInSeconds: timeoutInSeconds,
      failureAction: failureAction,
      path: path,
      port: port,
      headers: headers
    )
  }

  /// Creates a TCP container health check.
  public static func tcp(
    port: Int,
    name: String? = nil,
    initialDelayInSeconds: Int? = nil,
    intervalInSeconds: Int? = nil,
    failureThreshold: Int? = nil,
    successThreshold: Int? = nil,
    timeoutInSeconds: Int? = nil,
    failureAction: ContainerHealthCheckFailureAction? = nil
  ) -> CreateContainerHealthCheckDetails {
    CreateContainerHealthCheckDetails(
      name: name,
      healthCheckType: .tcp,
      initialDelayInSeconds: initialDelayInSeconds,
      intervalInSeconds: intervalInSeconds,
      failureThreshold: failureThreshold,
      successThreshold: successThreshold,
      timeoutInSeconds: timeoutInSeconds,
      failureAction: failureAction,
      port: port
    )
  }
}
