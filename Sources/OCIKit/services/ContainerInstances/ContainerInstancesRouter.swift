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

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// API routes for the OCI Container Instances service (API version `20210415`).
///
/// Use Container Instances to run containers directly on OCI without managing
/// any servers. See the
/// [Container Instances documentation](https://docs.oracle.com/en-us/iaas/Content/container-instances/home.htm).
public enum ContainerInstancesAPI: API {
  /// The service API version path segment shared by every route.
  static let version = "/20210415"

  // MARK: Container instances

  /// Creates a new container instance.
  case createContainerInstance(opcRetryToken: String? = nil, opcRequestId: String? = nil)
  /// Gets a single container instance by OCID.
  case getContainerInstance(containerInstanceId: String, opcRequestId: String? = nil)
  /// Lists the container instances in a compartment.
  case listContainerInstances(
    compartmentId: String,
    lifecycleState: ContainerInstanceLifecycleState? = nil,
    displayName: String? = nil,
    availabilityDomain: String? = nil,
    limit: Int? = nil,
    page: String? = nil,
    sortOrder: SortOrder? = nil,
    sortBy: ContainerInstanceSortBy? = nil,
    opcRequestId: String? = nil
  )
  /// Updates the mutable fields of a container instance.
  case updateContainerInstance(containerInstanceId: String, ifMatch: String? = nil, opcRequestId: String? = nil)
  /// Deletes a container instance and its containers.
  case deleteContainerInstance(containerInstanceId: String, ifMatch: String? = nil, opcRequestId: String? = nil)
  /// Moves a container instance to a different compartment.
  case changeContainerInstanceCompartment(containerInstanceId: String, ifMatch: String? = nil, opcRequestId: String? = nil)
  /// Starts a previously-stopped container instance.
  case startContainerInstance(containerInstanceId: String, ifMatch: String? = nil, opcRequestId: String? = nil)
  /// Stops a running container instance.
  case stopContainerInstance(containerInstanceId: String, ifMatch: String? = nil, opcRequestId: String? = nil)
  /// Restarts a container instance.
  case restartContainerInstance(containerInstanceId: String, ifMatch: String? = nil, opcRequestId: String? = nil)

  // MARK: Shapes

  /// Lists the available container instance shapes in a compartment.
  case listContainerInstanceShapes(
    compartmentId: String,
    availabilityDomain: String? = nil,
    limit: Int? = nil,
    page: String? = nil,
    opcRequestId: String? = nil
  )

  // MARK: Containers

  /// Gets a single container by OCID.
  case getContainer(containerId: String, opcRequestId: String? = nil)
  /// Lists the containers in a compartment.
  case listContainers(
    compartmentId: String,
    lifecycleState: ContainerInstanceLifecycleState? = nil,
    displayName: String? = nil,
    containerInstanceId: String? = nil,
    availabilityDomain: String? = nil,
    limit: Int? = nil,
    page: String? = nil,
    sortOrder: SortOrder? = nil,
    sortBy: ContainerInstanceSortBy? = nil,
    opcRequestId: String? = nil
  )
  /// Updates the mutable fields of a container.
  case updateContainer(containerId: String, ifMatch: String? = nil, opcRequestId: String? = nil)
  /// Retrieves the most recent logs (up to 256 KB) emitted by a container.
  case retrieveLogs(containerId: String, isPrevious: Bool? = nil, opcRequestId: String? = nil)

  // MARK: Work requests

  /// Gets the status of a work request.
  case getWorkRequest(workRequestId: String, opcRequestId: String? = nil)
  /// Lists the work requests in a compartment.
  case listWorkRequests(
    compartmentId: String,
    workRequestId: String? = nil,
    resourceId: String? = nil,
    availabilityDomain: String? = nil,
    status: ContainerInstanceWorkRequestStatus? = nil,
    limit: Int? = nil,
    page: String? = nil,
    sortOrder: SortOrder? = nil,
    sortBy: String? = nil,
    opcRequestId: String? = nil
  )
  /// Lists the errors for a work request.
  case listWorkRequestErrors(
    workRequestId: String,
    limit: Int? = nil,
    page: String? = nil,
    sortOrder: SortOrder? = nil,
    sortBy: String? = nil,
    opcRequestId: String? = nil
  )
  /// Lists the logs for a work request.
  case listWorkRequestLogs(
    workRequestId: String,
    limit: Int? = nil,
    page: String? = nil,
    sortOrder: SortOrder? = nil,
    sortBy: String? = nil,
    opcRequestId: String? = nil
  )

  // MARK: - Path

  public var path: String {
    let v = Self.version
    switch self {
    case .createContainerInstance, .listContainerInstances:
      return "\(v)/containerInstances"
    case .getContainerInstance(let id, _),
      .updateContainerInstance(let id, _, _),
      .deleteContainerInstance(let id, _, _):
      return "\(v)/containerInstances/\(id)"
    case .changeContainerInstanceCompartment(let id, _, _):
      return "\(v)/containerInstances/\(id)/actions/changeCompartment"
    case .startContainerInstance(let id, _, _):
      return "\(v)/containerInstances/\(id)/actions/start"
    case .stopContainerInstance(let id, _, _):
      return "\(v)/containerInstances/\(id)/actions/stop"
    case .restartContainerInstance(let id, _, _):
      return "\(v)/containerInstances/\(id)/actions/restart"
    case .listContainerInstanceShapes:
      return "\(v)/containerInstanceShapes"
    case .getContainer(let id, _),
      .updateContainer(let id, _, _):
      return "\(v)/containers/\(id)"
    case .listContainers:
      return "\(v)/containers"
    case .retrieveLogs(let id, _, _):
      return "\(v)/containers/\(id)/actions/retrieveLogs"
    case .getWorkRequest(let id, _):
      return "\(v)/workRequests/\(id)"
    case .listWorkRequests:
      return "\(v)/workRequests"
    case .listWorkRequestErrors(let id, _, _, _, _, _):
      return "\(v)/workRequests/\(id)/errors"
    case .listWorkRequestLogs(let id, _, _, _, _, _):
      return "\(v)/workRequests/\(id)/logs"
    }
  }

  // MARK: - HTTP Method

  public var method: HTTPMethod {
    switch self {
    case .getContainerInstance,
      .listContainerInstances,
      .listContainerInstanceShapes,
      .getContainer,
      .listContainers,
      .getWorkRequest,
      .listWorkRequests,
      .listWorkRequestErrors,
      .listWorkRequestLogs:
      return .get
    case .createContainerInstance,
      .changeContainerInstanceCompartment,
      .startContainerInstance,
      .stopContainerInstance,
      .restartContainerInstance,
      .retrieveLogs:
      return .post
    case .updateContainerInstance,
      .updateContainer:
      return .put
    case .deleteContainerInstance:
      return .delete
    }
  }

  // MARK: - Query Items

  public var queryItems: [URLQueryItem]? {
    let pairs: [(String, String?)]
    switch self {
    case .listContainerInstances(
      let compartmentId, let lifecycleState, let displayName, let availabilityDomain,
      let limit, let page, let sortOrder, let sortBy, _):
      pairs = [
        ("compartmentId", compartmentId),
        ("lifecycleState", lifecycleState?.rawValue),
        ("displayName", displayName),
        ("availabilityDomain", availabilityDomain),
        ("limit", limit.map(String.init)),
        ("page", page),
        ("sortOrder", sortOrder?.rawValue),
        ("sortBy", sortBy?.rawValue),
      ]
    case .listContainers(
      let compartmentId, let lifecycleState, let displayName, let containerInstanceId,
      let availabilityDomain, let limit, let page, let sortOrder, let sortBy, _):
      pairs = [
        ("compartmentId", compartmentId),
        ("lifecycleState", lifecycleState?.rawValue),
        ("displayName", displayName),
        ("containerInstanceId", containerInstanceId),
        ("availabilityDomain", availabilityDomain),
        ("limit", limit.map(String.init)),
        ("page", page),
        ("sortOrder", sortOrder?.rawValue),
        ("sortBy", sortBy?.rawValue),
      ]
    case .listContainerInstanceShapes(let compartmentId, let availabilityDomain, let limit, let page, _):
      pairs = [
        ("compartmentId", compartmentId),
        ("availabilityDomain", availabilityDomain),
        ("limit", limit.map(String.init)),
        ("page", page),
      ]
    case .retrieveLogs(_, let isPrevious, _):
      pairs = [("isPrevious", isPrevious.map { $0 ? "true" : "false" })]
    case .listWorkRequests(
      let compartmentId, let workRequestId, let resourceId, let availabilityDomain,
      let status, let limit, let page, let sortOrder, let sortBy, _):
      pairs = [
        ("compartmentId", compartmentId),
        ("workRequestId", workRequestId),
        ("resourceId", resourceId),
        ("availabilityDomain", availabilityDomain),
        ("status", status?.rawValue),
        ("limit", limit.map(String.init)),
        ("page", page),
        ("sortOrder", sortOrder?.rawValue),
        ("sortBy", sortBy),
      ]
    case .listWorkRequestErrors(_, let limit, let page, let sortOrder, let sortBy, _),
      .listWorkRequestLogs(_, let limit, let page, let sortOrder, let sortBy, _):
      pairs = [
        ("limit", limit.map(String.init)),
        ("page", page),
        ("sortOrder", sortOrder?.rawValue),
        ("sortBy", sortBy),
      ]
    default:
      return nil
    }

    let items = pairs.compactMap { key, value in
      value.map { URLQueryItem(name: key, value: $0) }
    }
    return items.isEmpty ? nil : items
  }

  // MARK: - Headers

  public var headers: [String: String]? {
    var headers: [String: String] = [:]
    switch self {
    case .createContainerInstance(let opcRetryToken, let opcRequestId):
      if let opcRetryToken { headers["opc-retry-token"] = opcRetryToken }
      if let opcRequestId { headers["opc-request-id"] = opcRequestId }
    case .getContainerInstance(_, let opcRequestId),
      .getContainer(_, let opcRequestId),
      .getWorkRequest(_, let opcRequestId):
      if let opcRequestId { headers["opc-request-id"] = opcRequestId }
    case .updateContainerInstance(_, let ifMatch, let opcRequestId),
      .deleteContainerInstance(_, let ifMatch, let opcRequestId),
      .changeContainerInstanceCompartment(_, let ifMatch, let opcRequestId),
      .startContainerInstance(_, let ifMatch, let opcRequestId),
      .stopContainerInstance(_, let ifMatch, let opcRequestId),
      .restartContainerInstance(_, let ifMatch, let opcRequestId),
      .updateContainer(_, let ifMatch, let opcRequestId):
      if let ifMatch { headers["if-match"] = ifMatch }
      if let opcRequestId { headers["opc-request-id"] = opcRequestId }
    case .listContainerInstances(_, _, _, _, _, _, _, _, let opcRequestId),
      .listContainers(_, _, _, _, _, _, _, _, _, let opcRequestId),
      .listContainerInstanceShapes(_, _, _, _, let opcRequestId),
      .retrieveLogs(_, _, let opcRequestId),
      .listWorkRequests(_, _, _, _, _, _, _, _, _, let opcRequestId),
      .listWorkRequestErrors(_, _, _, _, _, let opcRequestId),
      .listWorkRequestLogs(_, _, _, _, _, let opcRequestId):
      if let opcRequestId { headers["opc-request-id"] = opcRequestId }
    }
    return headers.isEmpty ? nil : headers
  }
}
