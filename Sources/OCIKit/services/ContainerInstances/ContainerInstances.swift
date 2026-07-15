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
import Logging

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Client for the OCI Container Instances service.
///
/// Container Instances lets you run containers directly on OCI-managed compute
/// without provisioning or managing servers. This client creates and manages
/// container instances, their containers, shapes, and the work requests that
/// track asynchronous operations.
///
/// A common use is to launch a container that authenticates back to OCI using
/// ``ResourcePrincipalSigner`` (Resource Principals v2.2), which OCI wires into
/// the container's environment automatically.
///
/// ## Example
/// ```swift
/// let signer = try APIKeySigner(configFilePath: "~/.oci/config")
/// let client = try ContainerInstancesClient(region: .fra, signer: signer)
///
/// let details = CreateContainerInstanceDetails(
///   compartmentId: compartmentId,
///   availabilityDomain: "AD-1",
///   shape: "CI.Standard.E4.Flex",
///   shapeConfig: CreateContainerInstanceShapeConfigDetails(ocpus: 1, memoryInGBs: 4),
///   containers: [CreateContainerDetails(imageUrl: "hello-world")],
///   vnics: [CreateContainerVnicDetails(subnetId: subnetId)]
/// )
/// let instance = try await client.createContainerInstance(createContainerInstanceDetails: details)
/// ```
public struct ContainerInstancesClient: Sendable {
  let endpoint: URL?
  let region: Region?
  let retryConfig: RetryConfig?
  let signer: Signer
  let logger: Logger

  // MARK: - Initialization

  /// Initializes the Container Instances client.
  ///
  /// - Parameters:
  ///   - region: A region used to determine the service endpoint.
  ///   - endpoint: A fully-qualified endpoint URL. Takes precedence over `region`.
  ///   - signer: A signer used to authenticate requests.
  ///   - retryConfig: Optional retry configuration.
  ///   - logger: Optional logger.
  /// - Throws: ``ContainerInstancesError/missingRequiredParameter(_:)`` if neither
  ///   `region` nor `endpoint` is provided.
  public init(
    region: Region? = nil,
    endpoint: String? = nil,
    signer: Signer,
    retryConfig: RetryConfig? = nil,
    logger: Logger = Logger(label: "ContainerInstancesClient")
  ) throws {
    self.signer = signer
    self.retryConfig = retryConfig
    self.logger = logger

    if let endpoint, let endpointURL = URL(string: endpoint) {
      self.endpoint = endpointURL
      self.region = nil
    }
    else {
      guard let region else {
        throw ContainerInstancesError.missingRequiredParameter("Either endpoint or region must be specified.")
      }
      self.region = region
      let host = Service.containerinstances.getHost(in: region)
      self.endpoint = URL(string: "https://\(host)")
    }
  }

  // MARK: - Container instances

  /// Creates a new container instance. Returns the newly-created (provisioning)
  /// instance; poll ``getContainerInstance(containerInstanceId:opcRequestId:)``
  /// until its `lifecycleState` is `.active`.
  public func createContainerInstance(
    createContainerInstanceDetails: CreateContainerInstanceDetails,
    opcRetryToken: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> ContainerInstance {
    let body = try encode(createContainerInstanceDetails, op: "createContainerInstance")
    let (data, _) = try await execute(
      .createContainerInstance(opcRetryToken: opcRetryToken, opcRequestId: opcRequestId),
      body: body,
      expectedStatus: 200
    )
    return try decode(ContainerInstance.self, from: data, op: "createContainerInstance")
  }

  /// Gets a container instance by OCID.
  public func getContainerInstance(
    containerInstanceId: String,
    opcRequestId: String? = nil
  ) async throws -> ContainerInstance {
    let (data, _) = try await execute(
      .getContainerInstance(containerInstanceId: containerInstanceId, opcRequestId: opcRequestId),
      expectedStatus: 200
    )
    return try decode(ContainerInstance.self, from: data, op: "getContainerInstance")
  }

  /// Lists the container instances in a compartment.
  public func listContainerInstances(
    compartmentId: String,
    lifecycleState: ContainerInstanceLifecycleState? = nil,
    displayName: String? = nil,
    availabilityDomain: String? = nil,
    limit: Int? = nil,
    page: String? = nil,
    sortOrder: SortOrder? = nil,
    sortBy: ContainerInstanceSortBy? = nil,
    opcRequestId: String? = nil
  ) async throws -> ContainerInstanceCollection {
    let (data, _) = try await execute(
      .listContainerInstances(
        compartmentId: compartmentId, lifecycleState: lifecycleState, displayName: displayName,
        availabilityDomain: availabilityDomain, limit: limit, page: page, sortOrder: sortOrder,
        sortBy: sortBy, opcRequestId: opcRequestId),
      expectedStatus: 200
    )
    return try decode(ContainerInstanceCollection.self, from: data, op: "listContainerInstances")
  }

  /// Updates the mutable fields of a container instance. Returns the
  /// `opc-work-request-id` for the asynchronous operation.
  @discardableResult
  public func updateContainerInstance(
    containerInstanceId: String,
    updateContainerInstanceDetails: UpdateContainerInstanceDetails,
    ifMatch: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> String? {
    let body = try encode(updateContainerInstanceDetails, op: "updateContainerInstance")
    let (_, http) = try await execute(
      .updateContainerInstance(containerInstanceId: containerInstanceId, ifMatch: ifMatch, opcRequestId: opcRequestId),
      body: body,
      expectedStatus: 202
    )
    return http.value(forHTTPHeaderField: "opc-work-request-id")
  }

  /// Deletes a container instance. Returns the `opc-work-request-id`.
  @discardableResult
  public func deleteContainerInstance(
    containerInstanceId: String,
    ifMatch: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> String? {
    let (_, http) = try await execute(
      .deleteContainerInstance(containerInstanceId: containerInstanceId, ifMatch: ifMatch, opcRequestId: opcRequestId),
      expectedStatus: 202
    )
    return http.value(forHTTPHeaderField: "opc-work-request-id")
  }

  /// Moves a container instance to a different compartment. Returns the `opc-work-request-id`.
  @discardableResult
  public func changeContainerInstanceCompartment(
    containerInstanceId: String,
    changeContainerInstanceCompartmentDetails: ChangeContainerInstanceCompartmentDetails,
    ifMatch: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> String? {
    let body = try encode(changeContainerInstanceCompartmentDetails, op: "changeContainerInstanceCompartment")
    let (_, http) = try await execute(
      .changeContainerInstanceCompartment(containerInstanceId: containerInstanceId, ifMatch: ifMatch, opcRequestId: opcRequestId),
      body: body,
      expectedStatus: 202
    )
    return http.value(forHTTPHeaderField: "opc-work-request-id")
  }

  /// Starts a stopped container instance. Returns the `opc-work-request-id`.
  @discardableResult
  public func startContainerInstance(
    containerInstanceId: String,
    ifMatch: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> String? {
    let (_, http) = try await execute(
      .startContainerInstance(containerInstanceId: containerInstanceId, ifMatch: ifMatch, opcRequestId: opcRequestId),
      expectedStatus: 202
    )
    return http.value(forHTTPHeaderField: "opc-work-request-id")
  }

  /// Stops a running container instance. Returns the `opc-work-request-id`.
  @discardableResult
  public func stopContainerInstance(
    containerInstanceId: String,
    ifMatch: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> String? {
    let (_, http) = try await execute(
      .stopContainerInstance(containerInstanceId: containerInstanceId, ifMatch: ifMatch, opcRequestId: opcRequestId),
      expectedStatus: 202
    )
    return http.value(forHTTPHeaderField: "opc-work-request-id")
  }

  /// Restarts a container instance. Returns the `opc-work-request-id`.
  @discardableResult
  public func restartContainerInstance(
    containerInstanceId: String,
    ifMatch: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> String? {
    let (_, http) = try await execute(
      .restartContainerInstance(containerInstanceId: containerInstanceId, ifMatch: ifMatch, opcRequestId: opcRequestId),
      expectedStatus: 202
    )
    return http.value(forHTTPHeaderField: "opc-work-request-id")
  }

  // MARK: - Shapes

  /// Lists the available container instance shapes in a compartment.
  public func listContainerInstanceShapes(
    compartmentId: String,
    availabilityDomain: String? = nil,
    limit: Int? = nil,
    page: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> ContainerInstanceShapeCollection {
    let (data, _) = try await execute(
      .listContainerInstanceShapes(
        compartmentId: compartmentId, availabilityDomain: availabilityDomain, limit: limit, page: page,
        opcRequestId: opcRequestId),
      expectedStatus: 200
    )
    return try decode(ContainerInstanceShapeCollection.self, from: data, op: "listContainerInstanceShapes")
  }

  // MARK: - Containers

  /// Gets a container by OCID.
  public func getContainer(containerId: String, opcRequestId: String? = nil) async throws -> Container {
    let (data, _) = try await execute(
      .getContainer(containerId: containerId, opcRequestId: opcRequestId),
      expectedStatus: 200
    )
    return try decode(Container.self, from: data, op: "getContainer")
  }

  /// Lists the containers in a compartment.
  public func listContainers(
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
  ) async throws -> ContainerCollection {
    let (data, _) = try await execute(
      .listContainers(
        compartmentId: compartmentId, lifecycleState: lifecycleState, displayName: displayName,
        containerInstanceId: containerInstanceId, availabilityDomain: availabilityDomain, limit: limit,
        page: page, sortOrder: sortOrder, sortBy: sortBy, opcRequestId: opcRequestId),
      expectedStatus: 200
    )
    return try decode(ContainerCollection.self, from: data, op: "listContainers")
  }

  /// Updates the mutable fields of a container. Returns the `opc-work-request-id`.
  @discardableResult
  public func updateContainer(
    containerId: String,
    updateContainerDetails: UpdateContainerDetails,
    ifMatch: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> String? {
    let body = try encode(updateContainerDetails, op: "updateContainer")
    let (_, http) = try await execute(
      .updateContainer(containerId: containerId, ifMatch: ifMatch, opcRequestId: opcRequestId),
      body: body,
      expectedStatus: 202
    )
    return http.value(forHTTPHeaderField: "opc-work-request-id")
  }

  /// Retrieves the most recent logs (up to 256 KB) emitted by a container.
  ///
  /// - Parameter isPrevious: When `true`, returns the logs of the previous run of
  ///   a restarted container instead of the current run.
  /// - Returns: The raw log text.
  public func retrieveLogs(
    containerId: String,
    isPrevious: Bool? = nil,
    opcRequestId: String? = nil
  ) async throws -> String {
    guard let endpoint else {
      throw ContainerInstancesError.missingRequiredParameter("No endpoint has been set")
    }
    var req = try buildRequest(
      api: ContainerInstancesAPI.retrieveLogs(containerId: containerId, isPrevious: isPrevious, opcRequestId: opcRequestId),
      endpoint: endpoint
    )
    // Logs are returned as text, not JSON.
    req.setValue("application/json, text/plain", forHTTPHeaderField: "accept")
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else {
      throw ContainerInstancesError.invalidResponse("Invalid HTTP response")
    }
    guard http.statusCode == 200 else {
      throw ContainerInstancesError.unexpectedStatusCode(http.statusCode, Self.errorMessage(from: data))
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  // MARK: - Work requests

  /// Gets a work request by OCID.
  public func getWorkRequest(workRequestId: String, opcRequestId: String? = nil) async throws -> ContainerInstanceWorkRequest {
    let (data, _) = try await execute(
      .getWorkRequest(workRequestId: workRequestId, opcRequestId: opcRequestId),
      expectedStatus: 200
    )
    return try decode(ContainerInstanceWorkRequest.self, from: data, op: "getWorkRequest")
  }

  /// Lists the work requests in a compartment.
  public func listWorkRequests(
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
  ) async throws -> ContainerInstanceWorkRequestSummaryCollection {
    let (data, _) = try await execute(
      .listWorkRequests(
        compartmentId: compartmentId, workRequestId: workRequestId, resourceId: resourceId,
        availabilityDomain: availabilityDomain, status: status, limit: limit, page: page,
        sortOrder: sortOrder, sortBy: sortBy, opcRequestId: opcRequestId),
      expectedStatus: 200
    )
    return try decode(ContainerInstanceWorkRequestSummaryCollection.self, from: data, op: "listWorkRequests")
  }

  /// Lists the errors for a work request.
  public func listWorkRequestErrors(
    workRequestId: String,
    limit: Int? = nil,
    page: String? = nil,
    sortOrder: SortOrder? = nil,
    sortBy: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> ContainerInstanceWorkRequestErrorCollection {
    let (data, _) = try await execute(
      .listWorkRequestErrors(
        workRequestId: workRequestId, limit: limit, page: page, sortOrder: sortOrder, sortBy: sortBy,
        opcRequestId: opcRequestId),
      expectedStatus: 200
    )
    return try decode(ContainerInstanceWorkRequestErrorCollection.self, from: data, op: "listWorkRequestErrors")
  }

  /// Lists the logs for a work request.
  public func listWorkRequestLogs(
    workRequestId: String,
    limit: Int? = nil,
    page: String? = nil,
    sortOrder: SortOrder? = nil,
    sortBy: String? = nil,
    opcRequestId: String? = nil
  ) async throws -> ContainerInstanceWorkRequestLogEntryCollection {
    let (data, _) = try await execute(
      .listWorkRequestLogs(
        workRequestId: workRequestId, limit: limit, page: page, sortOrder: sortOrder, sortBy: sortBy,
        opcRequestId: opcRequestId),
      expectedStatus: 200
    )
    return try decode(ContainerInstanceWorkRequestLogEntryCollection.self, from: data, op: "listWorkRequestLogs")
  }

  // MARK: - Private helpers

  /// Builds, signs, and executes a request, validating the HTTP status code.
  private func execute(
    _ api: ContainerInstancesAPI,
    body: Data? = nil,
    expectedStatus: Int
  ) async throws -> (Data, HTTPURLResponse) {
    guard let endpoint else {
      throw ContainerInstancesError.missingRequiredParameter("No endpoint has been set")
    }
    var req = try buildRequest(api: api, endpoint: endpoint)
    if let body { req.httpBody = body }
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else {
      throw ContainerInstancesError.invalidResponse("Invalid HTTP response")
    }
    guard http.statusCode == expectedStatus else {
      let message = Self.errorMessage(from: data)
      logger.error("[ContainerInstances] HTTP \(http.statusCode): \(message)")
      throw ContainerInstancesError.unexpectedStatusCode(http.statusCode, message)
    }
    return (data, http)
  }

  private func encode<T: Encodable>(_ value: T, op: String) throws -> Data {
    do {
      return try JSONEncoder().encode(value)
    }
    catch {
      throw ContainerInstancesError.jsonEncodingError("Failed to encode \(T.self) in \(op): \(error)")
    }
  }

  private func decode<T: Decodable>(_ type: T.Type, from data: Data, op: String) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: data)
    }
    catch {
      throw ContainerInstancesError.jsonDecodingError("Failed to decode \(T.self) in \(op): \(error)")
    }
  }

  /// Extracts a human-readable message from an OCI error body, falling back to raw text.
  private static func errorMessage(from data: Data) -> String {
    if let body = try? JSONDecoder().decode(DataBody.self, from: data) {
      return body.message
    }
    return String(data: data, encoding: .utf8) ?? ""
  }
}
