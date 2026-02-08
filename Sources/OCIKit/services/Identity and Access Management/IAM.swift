//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2025 Szabolcs Tóth and the oci-swift-sdk project authors
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

public struct IAMClient: Sendable {
  let endpoint: URL?
  let region: Region?
  let retryConfig: RetryConfig?
  let signer: Signer
  let logger: Logger

  // MARK: - Initialization
  /// Initialize the object storage client
  /// Parameters:
  ///     - region: A region used to determine the service endpoint.
  ///     - endpoint: The fully qualified endpoint URL
  ///     - signer: A signer implementation which can be used by this client.
  public init(region: Region? = nil, endpoint: String? = nil, signer: Signer, retryConfig: RetryConfig? = nil, logger: Logger = Logger(label: "IAMClient")) throws {
    self.signer = signer
    self.retryConfig = retryConfig
    self.logger = logger

    if let endpoint, let endpointURL = URL(string: endpoint) {
      self.endpoint = endpointURL
      self.region = nil
    }
    else {
      guard let region = region else {
        throw ObjectStorageError.missingRequiredParameter("Either endpoint or region must be specified.")
      }
      self.region = region
      let host = Service.iam.getHost(in: region)
      self.endpoint = URL(string: "https://\(host)/n")
    }
  }

  // MARK: - Bulk delete resources
  /// Deletes multiple resources within a single compartment.
  ///
  /// All resources referenced in the request must belong to the **same compartment**,
  /// and the caller must have the required permissions to delete each resource.
  ///
  /// This operation can only be invoked from the tenancy’s
  /// **home region** (see Oracle documentation on managing regions).
  ///
  /// The request initiates a long‑running **WorkRequest**.
  /// Use `getWorkRequest` to monitor the progress and completion state of the bulk action.
  ///
  /// - Parameters:
  ///   - compartmentId:
  ///     The OCID of the compartment containing the resources to delete.
  ///   - bulkDeleteResourcesDetails:
  ///     The request payload describing the resources to delete in bulk.
  ///   - opcRequestId:
  ///     A unique Oracle‑assigned identifier for the request.
  ///     Provide this value when contacting Oracle about a specific operation.

  public func bulkdeleteResources(
    compartmentId: String,
    bulkDeleteResourcesDetails: BulkDeleteResourcesDetails,
    opcRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw IAMError.missingRequiredParameter("No endpoint has been set")
    }
    let api = IAMAPI.bulkDeleteResources(compartmentId: compartmentId, bulkDeleteResourcesDetails: bulkDeleteResourcesDetails, opcRequestId: opcRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    let payload: Data
    do {
      payload = try JSONEncoder().encode(bulkDeleteResourcesDetails)
    }
    catch {
      throw IAMError.jsonEncodingError("BulkDeleteResourcesDetails cannot be encoded to data")
    }

    req.httpBody = payload
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IAMError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 202 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[bulkDeleteResources] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw IAMError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let opcWorkRequestId = headers["opc-work-request-id"], let opcRequestId = headers["opc-request-id"] {
      logger.debug("opc-work-request-id: \(opcWorkRequestId), opc-request-id: \(opcRequestId)")
    }
  }

  // MARK: - Bulk move resources
  /// Moves multiple resources from one compartment to another.
  ///
  /// All resources referenced in the request must belong to the **same source compartment**.
  ///
  /// This operation can only be invoked from the tenancy’s **home region**.
  ///
  /// To perform a bulk move, the caller must have the required permissions in both:
  /// - the **source compartment**, and
  /// - the **target compartment**.
  ///
  /// The request initiates a long‑running **WorkRequest**.
  /// Use `getWorkRequest` to monitor the progress and completion of the bulk action.
  ///
  /// - Parameters:
  ///   - compartmentId:
  ///     The OCID of the compartment containing the resources to move.
  ///   - bulkMoveResourcesDetails:
  ///     The request payload describing the resources to move and the target compartment.
  ///   - opcRequestId:
  ///     A unique Oracle‑assigned identifier for the request.
  ///     Provide this value when contacting Oracle about a specific operation.
  ///
  /// - Returns:
  ///   A response object with no data payload.
  ///   The associated `WorkRequest` tracks the actual move operation.
  public func bulkMoveResources(
    compartmentId: String,
    bulkMoveResourcesDetails: BulkMoveResourcesDetails,
    opcRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw IAMError.missingRequiredParameter("No endpoint has been set")
    }
    let api = IAMAPI.bulkMoveResources(compartmentId: compartmentId, bulkMoveResourcesDetails: bulkMoveResourcesDetails, opcRequestId: opcRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    let payload: Data
    do {
      payload = try JSONEncoder().encode(bulkMoveResourcesDetails)
    }
    catch {
      throw IAMError.jsonEncodingError("BulkMoveResourcesDetails cannot be encoded to data")
    }

    req.httpBody = payload
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IAMError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 202 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[bulkMoveResources] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw IAMError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let opcWorkRequestId = headers["opc-work-request-id"], let opcRequestId = headers["opc-request-id"] {
      logger.debug("opc-work-request-id: \(opcWorkRequestId), opc-request-id: \(opcRequestId)")
    }
  }

  // MARK: - Creates a compartment
  /// Creates a new compartment inside the specified parent compartment.
  ///
  /// Specify the parent compartment’s OCID as the `compartmentId` in the request body.
  /// The tenancy itself is simply the root compartment.
  /// For more information about OCIDs, see
  /// [Resource Identifiers](https://docs.cloud.oracle.com/Content/General/Concepts/identifiers.htm).
  ///
  /// You must provide a **name** for the new compartment.
  /// The name must be unique across all compartments within the same parent.
  /// This name (or the OCID) can later be used when writing IAM policies that apply
  /// to the compartment. For more details, see
  /// [How Policies Work](https://docs.cloud.oracle.com/Content/Identity/policieshow/how-policies-work.htm).
  ///
  /// You must also provide a **description** for the compartment.
  /// The description does not need to be unique and can be changed at any time using
  /// `updateCompartment`.
  ///
  /// After the request is submitted, the new compartment’s `lifecycleState` will
  /// temporarily be `.CREATING`.
  /// Before using the compartment, ensure that its state has transitioned to `.ACTIVE`.
  ///
  /// - Parameters:
  ///   - compartmentDetails: The request payload describing the new compartment to create.
  ///
  /// - Returns: A response containing the newly created `Compartment`.
  public func createCompartment(
    compartmentDetails: CreateCompartmentDetails
  ) async throws -> Compartment {
    guard let endpoint else {
      throw IAMError.missingRequiredParameter("No endpoint has been set")
    }
    let api = IAMAPI.createCompartment(compartmentDetails: compartmentDetails)
    var req = try buildRequest(api: api, endpoint: endpoint)

    let payload: Data
    do {
      payload = try JSONEncoder().encode(compartmentDetails)
    }
    catch {
      throw IAMError.jsonEncodingError("CompartmentDetails cannot be encoded to data")
    }

    req.httpBody = payload
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IAMError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[createCompartment] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw IAMError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let createdCompartment = try JSONDecoder().decode(Compartment.self, from: data)
    return createdCompartment
  }

  // MARK: - Deletes a compartment
  /// Deletes the specified compartment.
  ///
  /// The compartment **must be empty** before it can be deleted.
  ///
  /// - Parameters:
  ///   - compartmentId:
  ///     The OCID of the compartment to delete.
  ///
  /// - Returns:
  ///   A response object with no associated data.
  public func deleteCompartment(
    compartmentId: String
  ) async throws {
    guard let endpoint else {
      throw IAMError.missingRequiredParameter("No endpoint has been set")
    }
    let api = IAMAPI.deleteCompartment(compartmentId: compartmentId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IAMError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 202 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[deleteCompartment] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let opcWorkRequestId = headers["opc-work-request-id"], let opcRequestId = headers["opc-request-id"] {
      logger.debug("opc-work-request-id: \(opcWorkRequestId), opc-request-id: \(opcRequestId)")
    }
  }

  //MARK: - Gets a compartment
  /// Retrieves information about the specified compartment. It doesn't work with tenancy!
  ///
  /// This operation **does not** return a list of resources inside the compartment.
  /// OCI compartments can contain many different resource types (instances, block
  /// volumes, VCNs, etc.), and there is no single API that lists everything.
  /// To discover the resources within a compartment, call the corresponding
  /// “List” operation for each service and pass the compartment’s OCID as a
  /// query parameter.
  ///
  /// For example:
  /// - Use `listInstances` in the Compute service to list instances.
  /// - Use `listVolumes` in the Block Storage service to list block volumes.
  ///
  /// - Parameters:
  ///   - compartmentId:
  ///     The OCID of the compartment whose metadata should be retrieved.
  ///
  /// - Returns:
  ///   A response containing the `Compartment` object.
  public func getCompartment(
    compartmentId: String
  ) async throws -> Compartment {
    guard let endpoint else {
      throw IAMError.missingRequiredParameter("No endpoint has been set")
    }
    let api = IAMAPI.getCompartment(compartmentId: compartmentId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IAMError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("getCompartment] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    do {
      let compartment = try JSONDecoder().decode(Compartment.self, from: data)
      return compartment
    }
    catch {
      throw IAMError.jsonDecodingError("Failed to decode response data to Compartment")
    }
  }

  // MARK: - List bulk action resource types
  /// Lists the resource types supported by compartment bulk actions.
  ///
  /// Use this operation to determine the correct `resourceType` values to supply
  /// when invoking `bulkDeleteResources` or `bulkMoveResources`.
  ///
  /// The response describes each supported resource type along with the
  /// identifying information required for bulk operations.
  /// Most resource types can be uniquely identified by an OCID, but some—such as
  /// Object Storage buckets—require additional identifying fields.
  ///
  /// - Parameters:
  ///   - bulkActionType:
  ///     The type of bulk action being performed.
  ///     Allowed values are:
  ///       - `"BULK_MOVE_RESOURCES"`
  ///       - `"BULK_DELETE_RESOURCES"`
  ///   - page:
  ///     The pagination token (`opc-next-page`) from a previous list response.
  ///   - limit:
  ///     The maximum number of items to return in a paginated list call.
  ///
  /// - Returns:
  ///   A response containing a `BulkActionResourceTypeCollection` describing all
  ///   resource types supported for the specified bulk action.
  public func listBulkActionResourceTypes(
    bulkActionType: BulkActionType,
    page: String? = nil,
    limit: Int? = nil
  ) async throws -> BulkActionResourceTypeCollection {
    guard let endpoint else {
      throw IAMError.missingRequiredParameter("No endpoint has been set")
    }
    let api = IAMAPI.listBulkActionResourceTypes(bulkActionTytpe: bulkActionType.rawValue, page: page, limit: limit)

    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)
    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IAMError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listBulkActionResourceTypes] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    do {
      let listOfBulkActionResourceTypes = try JSONDecoder().decode(BulkActionResourceTypeCollection.self, from: data)
      return listOfBulkActionResourceTypes
    }
    catch {
      throw IAMError.jsonDecodingError("Failed to decode response data to BulkActionResourceTypeCollection")
    }
  }

  // MARK: - Lists compartments
  /// Lists the compartments within a specified compartment.
  /// The returned list depends on the values of several parameters.
  ///
  /// - Note:
  ///   - For all compartments except the tenancy (root compartment), this operation returns only the first-level child compartments.
  ///   - Subcompartments of those children (i.e., grandchildren) are not included.
  ///
  /// - Parameters:
  ///   - compartmentId: The OCID of the compartment. The tenancy is simply the root compartment.
  ///   - accessLevel: Determines whether to return only compartments for which the requestor has `INSPECT` permissions on at least one resource,
  ///     either directly or indirectly (e.g., in a subcompartment). Valid values are `ANY` and `ACCESSIBLE`. Default is `ANY`.
  ///   - compartmentIdInSubtree: Applies only when listing compartments on the tenancy. When `true`, the entire hierarchy of compartments is returned.
  ///     To list all compartments and subcompartments in the tenancy, set `compartmentIdInSubtree` to `true` and `accessLevel` to `ANY`.
  ///   - page: The value of the `opc-next-page` response header from a previous list call, used for pagination.
  ///   - limit: The maximum number of items to return in a paginated list call.
  ///   - name: A filter to return only compartments that match the given name exactly.
  ///   - sortBy: The field to sort by. Valid values are `TIMECREATED` (default descending) and `NAME` (default ascending, case-sensitive).
  ///   - sortOrder: The sort order to use: `ASC` or `DESC`. The `NAME` sort order is case-sensitive.
  ///   - lifecycleState: A filter to return only compartments matching the given lifecycle state. Case-insensitive.
  ///
  /// - Returns: An array of `Compartment` objects representing the compartments in the specified compartment.
  public func listCompartments(
    compartmentId: String,
    page: String? = nil,
    limit: Int? = nil,
    accessLevel: AccessLevel? = nil,
    compartmentIdInSubtree: Bool? = nil,
    name: String? = nil,
    sortBy: SortBy? = nil,
    sortOrder: SortOrder? = nil,
    lifecycleState: String? = nil
  ) async throws -> [Compartment] {
    guard let endpoint else {
      throw IAMError.missingRequiredParameter("No endpoint has been set")
    }
    let api = IAMAPI.listCompartments(
      compartmentId: compartmentId,
      page: page,
      limit: limit,
      accessLevel: accessLevel,
      compartmentIdInSubtree: compartmentIdInSubtree,
      name: name,
      sortBy: sortBy,
      sortOrder: sortOrder,
      lifecycleState: lifecycleState
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)
    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IAMError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listCompartments] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    do {
      let listOfCompartments = try JSONDecoder().decode([Compartment].self, from: data)
      return listOfCompartments
    }
    catch {
      throw IAMError.jsonDecodingError("Failed to decode response data to Compartments")
    }
  }

  // MARK: - Moves compartment
  /// Moves a compartment to a different parent compartment within the same tenancy.
  ///
  /// When a compartment is moved, **all of its contents**—including subcompartments
  /// and resources—are moved with it.
  /// The `compartmentId` specified in the request path identifies the compartment
  /// you intend to move.
  ///
  /// **Important:**
  /// After a compartment is moved, the **access policies of the new parent**
  /// immediately take effect, and the policies of the previous parent no longer apply.
  /// Ensure you understand the policy implications for all resources contained within
  /// the compartment before performing the move.
  /// For more details, see
  /// [Moving a Compartment](https://docs.cloud.oracle.com/Content/Identity/compartments/managingcompartments.htm#MoveCompartment).
  ///
  /// - Parameters:
  ///   - compartmentId:
  ///     The OCID of the compartment to move.
  ///   - moveCompartmentDetails:
  ///     The request payload describing the new parent compartment.
  ///   - opcRequestId:
  ///     A unique Oracle‑assigned identifier for the request.
  ///     Useful when contacting Oracle support.
  ///
  /// - Returns:
  ///   A response object with no associated data.
  public func moveCompartment(
    compartmentId: String,
    moveCompartmentDetails: MoveCompartmentDetails,
    opcRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw IAMError.missingRequiredParameter("No endpoint has been set")
    }
    let api = IAMAPI.moveCompartment(compartmentId: compartmentId, moveCompartmentDetails: moveCompartmentDetails, opcRequestId: opcRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    let payload: Data
    do {
      payload = try JSONEncoder().encode(moveCompartmentDetails)
    }
    catch {
      throw IAMError.jsonEncodingError("MoveCompartmentDetails cannot be encoded to data")
    }

    req.httpBody = payload
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IAMError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 202 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[moveCompartment] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let opcWorkRequestId = headers["opc-work-request-id"], let opcRequestId = headers["opc-request-id"] {
      logger.debug("opc-work-request-id: \(opcWorkRequestId), opc-request-id: \(opcRequestId)")
    }
  }

  // MARK: - Recovers compartment
  /// Recovers a compartment from the `DELETED` state back to the `ACTIVE` state.
  ///
  /// Use this operation to restore a previously deleted compartment.
  /// The compartment must currently be in the `DELETED` lifecycle state for the
  /// recovery to succeed.
  ///
  /// - Parameters:
  ///   - compartmentId:
  ///     The OCID of the compartment to recover.
  ///   - opcRequestId:
  ///     A unique Oracle‑assigned identifier for the request.
  ///     Useful when contacting Oracle support.
  ///
  /// - Returns:
  ///   A response containing the recovered `Compartment` object.
  public func recoverCompartment(
    compartmentId: String,
    opcRequestId: String? = nil
  ) async throws -> Compartment {
    guard let endpoint else {
      throw IAMError.missingRequiredParameter("No endpoint has been set")
    }
    let api = IAMAPI.recoverCompartment(compartmentId: compartmentId, opcRequestId: opcRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)
    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IAMError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[recoverCompartment] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    do {
      let recoveredCompartment = try JSONDecoder().decode(Compartment.self, from: data)
      return recoveredCompartment
    }
    catch {
      throw IAMError.jsonDecodingError("Failed to decode response data to Compartment")
    }
  }

  // MARK: - Updates compartment
  /// Updates the specified compartment’s name or description.
  ///
  /// This operation cannot be used to modify the **root compartment**.
  /// Only non‑root compartments may be updated.
  ///
  /// - Parameters:
  ///   - compartmentId:
  ///     The OCID of the compartment to update.
  ///   - updateCompartmentDetails:
  ///     The request payload containing the updated name and/or description.
  ///
  /// - Returns:
  ///   A response containing the updated `Compartment` object.
  public func updateCompartment(
    compartmentId: String,
    updateCompartmentDetails: UpdateCompartmentDetails
  ) async throws -> Compartment {
    guard let endpoint else {
      throw IAMError.missingRequiredParameter("No endpoint has been set")
    }

    let api = IAMAPI.updateCompartment(compartmentId: compartmentId, updateCompartmentDetails: updateCompartmentDetails)
    var req = try buildRequest(api: api, endpoint: endpoint)

    let payload: Data
    do {
      payload = try JSONEncoder().encode(updateCompartmentDetails)
    }
    catch {
      throw IAMError.jsonEncodingError("UpdateCompartmentDetails cannot be encoded to data")
    }

    req.httpBody = payload
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw IAMError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[updateCompartment] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw IAMError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let updatedCompartment = try JSONDecoder().decode(Compartment.self, from: data)
    return updatedCompartment
  }
}
