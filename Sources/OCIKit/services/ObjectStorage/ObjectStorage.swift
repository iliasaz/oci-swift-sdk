//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2025 Szabolcs Toth and the oci-swift-sdk project authors
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

public struct ObjectStorageClient: Sendable {
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
  ///
  ///  TODO:
  ///     - proxySettings: If your environment requires you to use a proxy server for outgoing HTTP requests the details for the proxy can be provided in this parameter
  ///     - retryConfig: The retry configuration for this service client
  ///
  ///     Either a region or an endpoint must be specified. If an endpoint is specified, it will be used instead of the region.
  public init(region: Region? = nil, endpoint: String? = nil, signer: Signer, retryConfig: RetryConfig? = nil, logger: Logger = Logger(label: "ObjectStorageClient")) throws {
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
      let host = Service.objectstorage.getHost(in: region)
      self.endpoint = URL(string: "https://\(host)/n")
    }
  }

  // MARK: - Cancels work request
  /// Cancels a work request.
  ///
  /// - Parameters:
  ///   - workRequestId: The ID of the asynchronous request.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  public func cancelWorkRequest(
    workRequestId: String,
    opcClientRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.cancelWorkRequest(workRequestId: workRequestId, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 202 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[cancelWorkRequest] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let opcRequestId = headers["opc-request-id"],
      let opcClientRequestId = headers["opc-client-request-id"]
    {
      logger.debug("opc-request-id: \(opcRequestId), opc-client-request-id: \(opcClientRequestId)")
    }
  }

  // MARK: - Copies object
  /// Creates a request to copy an object within a region or to another region.
  ///
  /// See [Object Names](https://docs.cloud.oracle.com/Content/Object/Tasks/managingobjects.htm#namerequirements)
  /// for object naming requirements.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - copyObjectDetails: The source and destination of the object to be copied.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// TODO:
  ///   - retryConfig: The retry configuration to apply to this operation. If no value is provided, the service-level retry configuration will be used. If `nil` is explicitly provided, the operation will not retry.
  ///   - opcSseCustomerAlgorithm: Optional header specifying `"AES256"` as the encryption algorithm. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSseCustomerKey: Optional header specifying the base64-encoded 256-bit encryption key to encrypt or decrypt the data. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSseCustomerKeySha256: Optional header specifying the base64-encoded SHA256 hash of the encryption key to verify its integrity. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSourceSseCustomerAlgorithm: Optional header specifying `"AES256"` as the encryption algorithm to decrypt the source object. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSourceSseCustomerKey: Optional header specifying the base64-encoded 256-bit encryption key to decrypt the source object. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSourceSseCustomerKeySha256: Optional header specifying the base64-encoded SHA256 hash of the encryption key used to decrypt the source object. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSseKmsKeyId: The [OCID](https://docs.cloud.oracle.com/Content/General/Concepts/identifiers.htm) of a master encryption key used to call the Key Management service.
  public func copyObject(namespaceName: String, bucketName: String, copyObjectDetails: CopyObjectDetails, opcClientRequestId: String? = nil) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.copyObject(namespaceName: namespaceName, bucketName: bucketName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    do {
      let payload: Data
      do {
        payload = try JSONEncoder().encode(copyObjectDetails)
      }
      catch {
        throw ObjectStorageError.jsonEncodingError("CopyObjectDetails cannot be encoded to data")
      }

      req.httpBody = payload

      try signer.sign(&req)

      let (data, response) = try await URLSession.shared.data(for: req)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ObjectStorageError.invalidResponse("Invalid HTTP response")
      }

      if httpResponse.statusCode != 202 {
        let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
        self.logger.error("[copyObject] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
        throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
      }

      let headers = convertHeadersToDictionary(httpResponse)
      if let opcRequestId = headers["opc-request-id"], let opcWorkRequestId = headers["opc-work-request-id"], let opcClientRequestId = headers["opc-client-request-id"] {
        logger.debug("opc-request-id: \(opcRequestId), opc-work-request-id: \(opcWorkRequestId), opc-client-request-id: \(opcClientRequestId)")
      }
    }
    catch {
      throw error
    }
  }

  // MARK: - Creates bucket
  /// Creates a bucket in the given namespace with a bucket name and optional user-defined metadata. Avoid entering confidential information in bucket names.
  /// The request body must contain a single [CreateBucketDetails](https://docs.oracle.com/en-us/iaas/api/#/en/objectstorage/20160918/datatypes/CreateBucketDetails) resource.
  ///
  /// - Parameters:
  ///     - namespaceName: The Object Storage namespace used for the request.
  ///     - opcClientRequestId: Optional client request ID for tracing.
  ///  - Returns: The response body will contain a single Bucket resource.
  public func createBucket(namespaceName: String, createBucketDetails: CreateBucketDetails, opcClientRequestId: String? = nil) async throws -> Bucket {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.createBucket(namespaceName: namespaceName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    do {
      let payload: Data
      do {
        payload = try JSONEncoder().encode(createBucketDetails)
      }
      catch {
        throw ObjectStorageError.jsonEncodingError("CreateBucketDetails cannot be encoded to data")
      }

      req.httpBody = payload

      try signer.sign(&req)

      let (data, response) = try await URLSession.shared.data(for: req)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ObjectStorageError.invalidResponse("Invalid HTTP response")
      }

      if httpResponse.statusCode != 200 {
        let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
        self.logger.error("[createBucket] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
        throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
      }

      do {
        let bucket = try JSONDecoder().decode(Bucket.self, from: data)
        return bucket
      }
      catch {
        throw ObjectStorageError.jsonDecodingError("Failed to decode response data to Bucket")
      }
    }
    catch {
      throw error
    }
  }

  // MARK: - Creates replication policy
  /// Creates a replication policy for the specified bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - policyDetails: The replication policy details to be created.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing `ReplicationPolicy`.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation. If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func createReplicationPolicy(
    namespaceName: String,
    bucketName: String,
    policyDetails: CreateReplicationPolicyDetails,
    opcClientRequestId: String? = nil
  ) async throws -> ReplicationPolicy {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.createReplicationPolicy(
      namespaceName: namespaceName,
      bucketName: bucketName,
      opcClientRequestId: opcClientRequestId
    )

    var req = try buildRequest(api: api, endpoint: endpoint)

    let payload: Data
    do {
      payload = try JSONEncoder().encode(policyDetails)
    }
    catch {
      throw ObjectStorageError.jsonEncodingError("CreateReplicationPloicyDetails cannot be encoded to data")
    }

    req.httpBody = payload
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[createReplicationPolicy] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let replicationPolicy = try JSONDecoder().decode(ReplicationPolicy.self, from: data)
    return replicationPolicy
  }

  // MARK: - Creates retention rule
  /// Creates a new retention rule in the specified bucket.
  /// The new rule typically takes effect within 30 seconds.
  /// Note: A maximum of 100 rules are supported per bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - ruleDetails: The retention rule to create for the bucket.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing `RetentionRule`.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation. If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func createRetentionRule(
    namespaceName: String,
    bucketName: String,
    ruleDetails: CreateRetentionRuleDetails,
    opcClientRequestId: String? = nil
  ) async throws -> RetentionRule {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.createRetentionRule(
      namespaceName: namespaceName,
      bucketName: bucketName,
      opcClientRequestId: opcClientRequestId
    )

    var req = try buildRequest(api: api, endpoint: endpoint)

    let payload: Data
    do {
      payload = try JSONEncoder().encode(ruleDetails)
    }
    catch {
      throw ObjectStorageError.jsonEncodingError("CreateRetentionRuleDetails cannot be encoded to data")
    }

    req.httpBody = payload
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[createRetentionRule] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let retentionRule = try JSONDecoder().decode(RetentionRule.self, from: data)
    return retentionRule
  }

  // MARK: - Creates preauthenticated request
  /// Creates a pre-authenticated request specific to the bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - requestDetails: Information needed to create the pre-authenticated request.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing `PreauthenticatedRequest`.
  public func createPreauthenticatedRequest(
    namespaceName: String,
    bucketName: String,
    requestDetails: CreatePreauthenticatedRequestDetails,
    opcClientRequestId: String? = nil
  ) async throws -> PreauthenticatedRequest {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.createPreauthenticatedRequest(
      namespaceName: namespaceName,
      bucketName: bucketName,
      opcClientRequestId: opcClientRequestId
    )

    var req = try buildRequest(api: api, endpoint: endpoint)

    let payload: Data
    do {
      payload = try JSONEncoder().encode(requestDetails)
    }
    catch {
      throw ObjectStorageError.jsonEncodingError("CreatePreauthenticatedRequestDetails cannot be encoded to data")
    }

    req.httpBody = payload
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[createPreauthenticatedRequest] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let preauthRequest = try JSONDecoder().decode(PreauthenticatedRequest.self, from: data)
    return preauthRequest
  }

  // MARK: - Deletes bucket
  /// Deletes a bucket if the bucket is already empty.
  /// If the bucket is not empty, use `deleteObject` first.
  /// You cannot delete a bucket that has a multipart upload in progress or a pre-authenticated request associated with it.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A `Response` object with data of type `Void`.
  ///
  /// TODO:
  /// - retryConfig: The retry configuration to apply to this operation. If no value is provided,
  /// the service-level retry configuration will be used. If `nil` is explicitly provided,
  /// the operation will not retry.
  ///  - ifMatch: The entity tag (ETag) to match with the ETag of an existing resource.
  ///  If the specified ETag matches, GET and HEAD requests will return the resource,
  ///  and PUT and POST requests will upload the resource.
  public func deleteBucket(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.deleteBucket(namespaceName: namespaceName, bucketName: bucketName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 204 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[deleteBucket] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let opcRequestId = headers["opc-request-id"] {
      logger.debug("The \(bucketName) bucket was delete from \(namespaceName) namespace. RequestID: \(opcRequestId)")
    }
  }

  // MARK: - Deletes object
  /// Deletes an object from Object Storage.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - objectName: The name of the object to delete. Avoid entering confidential information. Example: `"test/object1.log"`
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///   - versionId: Optional version ID used to identify a particular version of the object.
  ///
  /// - Returns: A `Response` object with no data payload (`Void`).
  ///
  /// TODO:
  ///   - retryConfig: The retry configuration to apply to this operation. If no value is provided, the service-level retry configuration will be used. If `nil` is explicitly provided, the operation will not retry.
  ///   - ifMatch: The entity tag (ETag) to match with the ETag of an existing resource. If the specified ETag matches, GET and HEAD requests will return the resource, and PUT and POST requests will upload the resource.
  public func deleteObject(
    namespaceName: String,
    bucketName: String,
    objectName: String,
    opcClientRequestId: String? = nil,
    versionId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.deleteObject(namespaceName: namespaceName, bucketName: bucketName, objectName: objectName, opcClientRequestId: opcClientRequestId, versionId: versionId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 204 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[deleteObject] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let isDeleteMarker = headers["is-delete-marker"], let lastModified = headers["last-modified"], let opcClientRequestId = headers["opc-client-request-id"],
      let opcRequestId = headers["opc-request-id"], let versionId = headers["version-id"]
    {
      logger.debug("is-delete-marker: \(isDeleteMarker), last-modified: \(lastModified), opc-client-request-id: \(opcClientRequestId), opc-request-id: \(opcRequestId), version-id: \(versionId)")
    }
  }

  // MARK: - Deletes replication policy
  /// Deletes the replication policy associated with the specified source bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - replicationId: The ID of the replication policy to delete.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object with no data (void).
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation. If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func deleteReplicationPolicy(
    namespaceName: String,
    bucketName: String,
    replicationId: String,
    opcClientRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.deleteReplicationPolicy(
      namespaceName: namespaceName,
      bucketName: bucketName,
      replicationId: replicationId,
      opcClientRequestId: opcClientRequestId
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 204 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[deleteReplicationPolicy] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let opcRequestId = headers["opc-request-id"],
      let opcClientRequestId = headers["opc-client-request-id"]
    {
      logger.debug("opc-request-id: \(opcRequestId), opc-client-request-id: \(opcClientRequestId)")
    }
  }

  // MARK: - Deletes retention rule
  /// Deletes the specified retention rule from the bucket.
  /// The deletion typically takes effect within 30 seconds.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - retentionRuleId: The ID of the retention rule to delete.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object with no data (void).
  ///
  /// TODO:
  ///   - ifMatch: Optional ETag value for optimistic concurrency control.
  ///   - retryConfig: Optional retry configuration for this operation.
  public func deleteRetentionRule(
    namespaceName: String,
    bucketName: String,
    retentionRuleId: String,
    opcClientRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.deleteRetentionRule(
      namespaceName: namespaceName,
      bucketName: bucketName,
      retentionId: retentionRuleId,
      opcClientRequestId: opcClientRequestId
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 204 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[deleteRetentionRule] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let opcRequestId = headers["opc-request-id"],
      let opcClientRequestId = headers["opc-client-request-id"]
    {
      logger.debug("opc-request-id: \(opcRequestId), opc-client-request-id: \(opcClientRequestId)")
    }
  }

  // MARK: - Deletes preauthenticated request
  /// Deletes the pre-authenticated request for the specified bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - parId: The unique identifier for the pre-authenticated request.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object with no data (void).
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation.
  public func deletePreauthenticatedRequest(
    namespaceName: String,
    bucketName: String,
    parId: String,
    opcClientRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.deletePreauthenticatedRequest(
      namespaceName: namespaceName,
      bucketName: bucketName,
      parId: parId,
      opcClientRequestId: opcClientRequestId
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 204 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[deletePreauthenticatedRequest] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)

    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let opcClientRequestId = headers["opc-client-request-id"],
      let opcRequestId = headers["opc-request-id"]
    {
      logger.debug("opc-client-request-id: \(opcClientRequestId), opc-request-id: \(opcRequestId)")
    }
  }

  // MARK: - Gets bucket
  /// Gets the current representation of the given bucket in the given Object Storage namespace.
  /// - Parameters:
  ///     - namespaceName: The Object Storage namespace used for the request.
  ///     - bucketName: The name of the bucket. Avoid entering confidential information.
  ///     - opcClientRequestId: Optional client request ID for tracing.
  /// - Returns: A bucket representation for the requested bucket.
  ///
  /// TODO:
  ///     - retryConfig: Optional The retry configuration to apply to this operation. If no key is provided,
  ///     then the service-level retry configuration defined by `retryConfig` will be used.
  ///     If an explicit `nil` value is provided, the operation will not retry.
  ///   - ifMatch: Optional The entity tag (ETag) to match with the ETag of an existing resource.
  ///     If the specified ETag matches the ETag of the existing resource, `GET` and `HEAD` requests
  ///     will return the resource, and `PUT` and `POST` requests will upload the resource.
  ///   - ifNoneMatch: Optional The entity tag (ETag) to avoid matching. Wildcards ('*') are not allowed.
  ///     If the specified ETag does not match the ETag of the existing resource, the request returns
  ///     the expected response. If the ETag matches, the request returns an HTTP 304 status without a response body.
  ///   - opcClientRequestId: Optional The client request ID for tracing.
  ///   - fields: Optional A list of fields to include in the bucket summary. Possible values are:
  ///     - `approximateCount`: Approximate number of objects in the bucket.
  ///     - `approximateSize`: Total approximate size in bytes of all objects in the bucket.
  ///     - `autoTiering`: State of auto tiering on the bucket.
  ///
  public func getBucket(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil) async throws -> Bucket {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.getBucket(namespaceName: namespaceName, bucketName: bucketName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[getBucket] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    do {
      let bucket = try JSONDecoder().decode(Bucket.self, from: data)
      return bucket
    }
    catch {
      throw ObjectStorageError.jsonDecodingError("Failed to decode response data to Bucket")
    }
  }

  // MARK: - Gets namespace
  /// Each Oracle Cloud Infrastructure tenant is assigned one unique and uneditable Object Storage namespace. The namespace
  /// is a system-generated string assigned during account creation. For some older tenancies, the namespace string may be
  /// the tenancy name in all lower-case letters. You cannot edit a namespace.
  ///
  /// GetNamespace returns the name of the Object Storage namespace for the user making the request.
  /// If an optional compartmentId query parameter is provided, GetNamespace returns the namespace name of the corresponding
  /// tenancy, provided the user has access to it.
  ///
  /// - Parameters:
  ///   - compartmentId: his is an optional field representing either the tenancy [OCID](https://docs.cloud.oracle.com/Content/General/Concepts/identifiers.htm) or the compartment [OCID](https://docs.cloud.oracle.com/Content/General/Concepts/identifiers.htm) within the tenancy whose Object Storage namespace is to be retrieved.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///   - retryConfig: Optional retry configuration to apply to this operation. If `nil`, the default service-level retry configuration is used. If explicitly set to `nil`, the operation will not retry.
  ///
  /// - Returns: A `String` containing the Object Storage namespace.
  public func getNamespace(compartmentId: String? = nil) async throws -> String {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.getNamespace()
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[getNamespace] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    guard let responseBody = String(data: data, encoding: .utf8) else {
      throw ObjectStorageError.invalidUTF8
    }

    return responseBody.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }

  // MARK: - Gets namespace metadata
  /// Retrieves metadata for the Object Storage namespace, including `defaultS3CompartmentId` and `defaultSwiftCompartmentId`.
  ///
  /// Any user with the `OBJECTSTORAGE_NAMESPACE_READ` permission can view the current metadata.
  /// If you are not authorized, contact an administrator. Administrators can refer to
  /// [Getting Started with Policies](https://docs.cloud.oracle.com/Content/Identity/Concepts/policygetstarted.htm)
  /// for guidance on granting access.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - opcClientRequestId: The client request ID for tracing.
  ///
  /// - Returns: A `Response` object containing `NamespaceMetadata`.
  ///
  /// TODO:
  ///   - retryConfig: The retry configuration to apply to this operation. If no value is provided, the service-level retry configuration will be used. If `nil` is explicitly provided, the operation will not retry.
  public func getNamespaceMetadata(namespaceName: String, opcClientRequestId: String? = nil) async throws -> NamespaceMetadata {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.getNamespaceMetadata(namespaceName: namespaceName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[getNamespaceMetadata] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let namespaceMetadata = try JSONDecoder().decode(NamespaceMetadata.self, from: data)

    return namespaceMetadata
  }

  // MARK: - Get object
  /// Retrieves the metadata and body of an object from Object Storage.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - objectName: The name of the object. Avoid entering confidential information. Example: `"test/object1.log"`
  ///   - versionId: The version ID used to identify a particular version of the object.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///   - range: Optional byte range to fetch, as described in [RFC 7233](https://tools.ietf.org/html/rfc7233#section-2.1). Only a single range is supported.
  ///   - opcSseCustomerAlgorithm: Optional header specifying `"AES256"` as the encryption algorithm. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSseCustomerKey: Optional header specifying the base64-encoded 256-bit encryption key to encrypt or decrypt the data. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSseCustomerKeySha256: Optional header specifying the base64-encoded SHA256 hash of the encryption key to verify its integrity. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - httpResponseContentDisposition: Query parameter to override the `Content-Disposition` response header.
  ///   - httpResponseCacheControl: Query parameter to override the `Cache-Control` response header.
  ///   - httpResponseContentType: Query parameter to override the `Content-Type` response header.
  ///   - httpResponseContentLanguage: Query parameter to override the `Content-Language` response header.
  ///   - httpResponseContentEncoding: Query parameter to override the `Content-Encoding` response header.
  ///   - httpResponseExpires: Query parameter to override the `Expires` response header.
  ///
  /// - Returns: A `Data` object containing the raw contents of the object.
  public func getObject(
    namespaceName: String,
    bucketName: String,
    objectName: String,
    versionId: String? = nil,
    opcClientRequestId: String? = nil,
    range: String? = nil,
    opcSseCustomerAlgorithm: String? = nil,
    opcSseCustomerKey: String? = nil,
    opcSseCustomerKeySha256: String? = nil,
    httpResponseContentDisposition: String? = nil,
    httpResponseCacheControl: String? = nil,
    httpResponseContentType: String? = nil,
    httpResponseContentLanguage: String? = nil,
    httpResponseContentEncoding: String? = nil,
    httpResponseExpires: String? = nil,
    withObjectIntegrityCheck: Bool = false
  ) async throws -> Data {

    let api = ObjectStorageAPI.getObject(
      namespaceName: namespaceName,
      bucketName: bucketName,
      objectName: objectName,
      versionId: versionId,
      opcClientRequestId: opcClientRequestId,
      range: range,
      opcSseCustomerAlgorithm: opcSseCustomerAlgorithm,
      opcSseCustomerKey: opcSseCustomerKey,
      opcSseCustomerKeySha256: opcSseCustomerKeySha256,
      httpResponseContentDisposition: httpResponseContentDisposition,
      httpResponseCacheControl: httpResponseCacheControl,
      httpResponseContentType: httpResponseContentType,
      httpResponseContentLanguage: httpResponseContentLanguage,
      httpResponseContentEncoding: httpResponseContentEncoding,
      httpResponseExpires: httpResponseExpires
    )
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[getObject] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    if withObjectIntegrityCheck {
      try validateObjectIntegrity(data: data, httpResponse: httpResponse)
    }

    return data
  }

  // MARK: - Get object (PAR)
  /// Retrieves the metadata and body of an object from Object Storage using a
  /// Pre‑Authenticated Request (PAR) URL.
  ///
  /// This variant of `getObject` allows access without requiring namespace or bucket
  /// parameters, since those are already encoded in the PAR URL.
  ///
  /// - Parameters:
  ///   - parURL: The full Pre‑Authenticated Request (PAR) URL that grants access to the object.
  ///   - objectName: The name of the object. Avoid entering confidential information. Example: `"test/object1.log"`.
  ///   - versionId: The version ID used to identify a particular version of the object.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///   - range: Optional byte range to fetch, as described in
  ///     [RFC 7233](https://tools.ietf.org/html/rfc7233#section-2.1). Only a single range is supported.
  ///   - opcSseCustomerAlgorithm: Optional header specifying `"AES256"` as the encryption algorithm.
  ///     [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSseCustomerKey: Optional header specifying the base64‑encoded 256‑bit encryption key
  ///     to encrypt or decrypt the data. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSseCustomerKeySha256: Optional header specifying the base64‑encoded SHA256 hash of the
  ///     encryption key to verify its integrity. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - httpResponseContentDisposition: Query parameter to override the `Content‑Disposition` response header.
  ///   - httpResponseCacheControl: Query parameter to override the `Cache‑Control` response header.
  ///   - httpResponseContentType: Query parameter to override the `Content‑Type` response header.
  ///   - httpResponseContentLanguage: Query parameter to override the `Content‑Language` response header.
  ///   - httpResponseContentEncoding: Query parameter to override the `Content‑Encoding` response header.
  ///   - httpResponseExpires: Query parameter to override the `Expires` response header.
  ///   - withObjectIntegrityCheck: If `true`, validates the object length and MD5 checksum against
  ///     values reported by Object Storage.
  ///
  /// - Returns: A `Data` object containing the raw contents of the object.
  public func getObject(
    parURL: URL,
    objectName: String,
    versionId: String? = nil,
    opcClientRequestId: String? = nil,
    range: String? = nil,
    opcSseCustomerAlgorithm: String? = nil,
    opcSseCustomerKey: String? = nil,
    opcSseCustomerKeySha256: String? = nil,
    httpResponseContentDisposition: String? = nil,
    httpResponseCacheControl: String? = nil,
    httpResponseContentType: String? = nil,
    httpResponseContentLanguage: String? = nil,
    httpResponseContentEncoding: String? = nil,
    httpResponseExpires: String? = nil,
    withObjectIntegrityCheck: Bool = false
  ) async throws -> Data {

    // The endpoint here is different from the above implementation because it already contains /p, /n, and /b in it.
    guard let host = parURL.host(), let baseURL = URL(string: "https://\(host)") else {
      throw ObjectStorageError.invalidURL("Malformed PAR URL")
    }

    let api = ObjectStorageAPI.getObjectWithPAR(
      parURL: parURL,
      objectName: objectName,
      versionId: versionId,
      opcClientRequestId: opcClientRequestId,
      range: range,
      opcSseCustomerAlgorithm: opcSseCustomerAlgorithm,
      opcSseCustomerKey: opcSseCustomerKey,
      opcSseCustomerKeySha256: opcSseCustomerKeySha256,
      httpResponseContentDisposition: httpResponseContentDisposition,
      httpResponseCacheControl: httpResponseCacheControl,
      httpResponseContentType: httpResponseContentType,
      httpResponseContentLanguage: httpResponseContentLanguage,
      httpResponseContentEncoding: httpResponseContentEncoding,
      httpResponseExpires: httpResponseExpires
    )

    let req = try buildRequest(api: api, endpoint: baseURL)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[getObjectPAR] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    if withObjectIntegrityCheck {
      try validateObjectIntegrity(data: data, httpResponse: httpResponse)
    }

    return data
  }

  private func validateObjectIntegrity(data: Data, httpResponse: HTTPURLResponse) throws {
    // byte length check if available
    if let contentLengthString = httpResponse.value(forHTTPHeaderField: "content-length"), let contentLength = Int(contentLengthString) {
      guard contentLength == data.count else {
        throw ObjectStorageError.objectLengthMismatch(data.count, contentLength)
      }
    }

    // MD5 check if available. Object Storage returns base64-encoded MD5 hash (RFC2616)
    // https://docs.oracle.com/en-us/iaas/api/#/en/objectstorage/20160918/Object/GetObject
    // https://datatracker.ietf.org/doc/html/rfc2616#section-14.15
    if let md5Original = httpResponse.value(forHTTPHeaderField: "content-md5") {
      let objectMD5 = data.md5base64
      guard md5Original == objectMD5 else {
        throw ObjectStorageError.objectMD5Mismatch(objectMD5, md5Original)
      }
    }
  }

  // MARK: - Get replication policy
  /// Retrieves the replication policy for the specified bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - replicationId: The ID of the replication policy to retrieve.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing `ReplicationPolicy`.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation. If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func getReplicationPolicy(
    namespaceName: String,
    bucketName: String,
    replicationId: String,
    opcClientRequestId: String? = nil
  ) async throws -> ReplicationPolicy {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.getReplicationPolicy(
      namespaceName: namespaceName,
      bucketName: bucketName,
      replicationId: replicationId,
      opcClientRequestId: opcClientRequestId
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[getReplicationPolicy] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let replicationPolicy = try JSONDecoder().decode(ReplicationPolicy.self, from: data)
    return replicationPolicy
  }

  // MARK: - Gets retention rule
  /// Retrieves the specified retention rule from the given bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - retentionRuleId: The ID of the retention rule to retrieve.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing `RetentionRule`.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation.
  ///     If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func getRetentionRule(
    namespaceName: String,
    bucketName: String,
    retentionRuleId: String,
    opcClientRequestId: String? = nil
  ) async throws -> RetentionRule {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.getRetentionRule(
      namespaceName: namespaceName,
      bucketName: bucketName,
      retentionId: retentionRuleId,
      opcClientRequestId: opcClientRequestId
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[getRetentionRule] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let retentionRule = try JSONDecoder().decode(RetentionRule.self, from: data)
    return retentionRule
  }

  // MARK: - Gets preauthenticated request
  /// Retrieves the pre-authenticated request for the specified bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - parId: The unique identifier for the pre-authenticated request.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing `PreauthenticatedRequestSummary`.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation.
  ///     If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func getPreauthenticatedRequest(
    namespaceName: String,
    bucketName: String,
    parId: String,
    opcClientRequestId: String? = nil
  ) async throws -> PreauthenticatedRequestSummary {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.getPreauthenticatedRequest(
      namespaceName: namespaceName,
      bucketName: bucketName,
      parId: parId,
      opcClientRequestId: opcClientRequestId
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[getPreauthenticatedReques] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let preauthenticatedRequestSummary = try JSONDecoder().decode(PreauthenticatedRequestSummary.self, from: data)
    return preauthenticatedRequestSummary
  }

  // MARK: - Gets work request
  /// Gets the status of the work request for the given ID.
  ///
  /// - Parameters:
  ///   - workRequestId: The ID of the asynchronous request.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A `WorkRequest` object containing the status of the work request.
  public func getWorkRequestStatus(
    workRequestId: String,
    opcClientRequestId: String? = nil
  ) async throws -> WorkRequest {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.getWorkRequest(workRequestId: workRequestId, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[getWorkRequestStatus] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let workRequest = try JSONDecoder().decode(WorkRequest.self, from: data)
    return workRequest
  }

  // MARK: - Heads bucket
  /// Efficiently checks whether a bucket exists and retrieves the current entity tag (ETag) for the bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A `Response` object with no data payload (`Void`).
  ///
  /// TODO:
  ///  - retryConfig: The retry configuration to apply to this operation. If no value is provided,
  ///  the service-level retry configuration will be used. If `nil` is explicitly provided, the operation will not retry.
  ///  - ifMatch: The entity tag (ETag) to match with the ETag of an existing resource.
  ///  If the specified ETag matches, GET and HEAD requests will return the resource,
  ///  and PUT and POST requests will upload the resource.
  ///  - ifNoneMatch: The entity tag (ETag) to avoid matching. Wildcards (`*`) are not allowed.
  ///  If the specified ETag does not match the existing resource, the request returns the expected response.
  ///  If it matches, the request returns HTTP 304 without a response body.
  public func headBucket(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.headBucket(namespaceName: namespaceName, bucketName: bucketName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[headBucket] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let etag = headers["ETag"], let opcRequestId = headers["opc-request-id"] {
      logger.debug("ETag: \(etag), opc-request-id: \(opcRequestId)")
    }
  }

  // MARK: - Heads object
  /// Retrieves the user-defined metadata and entity tag (ETag) for an object.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - objectName: The name of the object. Avoid entering confidential information. Example: `"test/object1.log"`
  ///   - versionId: Optional version ID used to identify a particular version of the object.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///   - opcSseCustomerAlgorithm: Optional header specifying `"AES256"` as the encryption algorithm. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSseCustomerKey: Optional header specifying the base64-encoded 256-bit encryption key to encrypt or decrypt the data. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///   - opcSseCustomerKeySha256: Optional header specifying the base64-encoded SHA256 hash of the encryption key to verify its integrity. [More info](https://docs.cloud.oracle.com/Content/Object/Tasks/usingyourencryptionkeys.htm).
  ///
  /// - Returns: A `Response` object with no data payload (`Void`).
  ///
  /// TODO:
  ///   - retryConfig: The retry configuration to apply to this operation. If no value is provided, the service-level retry configuration will be used. If `nil` is explicitly provided, the operation will not retry.
  ///   - ifMatch: The entity tag (ETag) to match with the ETag of an existing resource. If the specified ETag matches, GET and HEAD requests will return the resource, and PUT and POST requests will upload the resource.
  ///   - ifNoneMatch: The entity tag (ETag) to avoid matching. Wildcards (`*`) are not allowed. If the specified ETag does not match, the request returns the expected response. If it matches, the request returns HTTP 304 without a response body.
  public func headObject(
    namespaceName: String,
    bucketName: String,
    objectName: String,
    versionId: String? = nil,
    opcClientRequestId: String? = nil,
    opcSseCustomerAlgorithm: String? = nil,
    opcSseCustomerKey: String? = nil,
    opcSseCustomerKeySha256: String? = nil
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.headObject(
      namespaceName: namespaceName,
      bucketName: bucketName,
      objectName: objectName,
      versionId: versionId,
      opcClientRequestId: opcClientRequestId,
      opcSseCustomerAlgorithm: opcSseCustomerAlgorithm,
      opcSseCustomerKey: opcSseCustomerKey,
      opcSseCustomerKeySha256: opcSseCustomerKeySha256
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[headObject] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)

    if let etag = headers["ETag"],
      let archivalState = headers["archival-state"],
      let cacheControl = headers["cache-control"],
      let contentDisposition = headers["content-disposition"],
      let contentEncoding = headers["content-encoding"],
      let contentLanguage = headers["content-language"],
      let contentLength = headers["content-length"],
      let contentMd5 = headers["content-md5"],
      let contentType = headers["content-type"],
      let lastModified = headers["last-modified"],
      let opcClientRequestId = headers["opc-client-request-id"],
      let opcMultipartMd5 = headers["opc-multipart-md5"],
      let opcRequestId = headers["opc-request-id"],
      let storageTier = headers["storage-tier"],
      let timeOfArchival = headers["time-of-archival"],
      let versionId = headers["version-id"]
    {

      // Extract all user-defined metadata headers
      let opcMeta = headers.filter { $0.key.hasPrefix("opc-meta-") }

      logger.debug(
        """
        ETag: \(etag)
        Archival-State: \(archivalState)
        Cache-Control: \(cacheControl)
        Content-Disposition: \(contentDisposition)
        Content-Encoding: \(contentEncoding)
        Content-Language: \(contentLanguage)
        Content-Length: \(contentLength)
        Content-MD5: \(contentMd5)
        Content-Type: \(contentType)
        Last-Modified: \(lastModified)
        opc-client-request-id: \(opcClientRequestId)
        opc-multipart-md5: \(opcMultipartMd5)
        opc-request-id: \(opcRequestId)
        Storage-Tier: \(storageTier)
        Time-Of-Archival: \(timeOfArchival)
        Version-Id: \(versionId)
        opc-meta: \(opcMeta)
        """
      )
    }
  }

  // MARK: - Lists buckets
  /// Gets a list of all BucketSummary items in a compartment. A BucketSummary contains only summary fields for the bucket
  /// and does not contain fields like the user-defined metadata.
  ///
  /// ListBuckets returns a BucketSummary containing at most 1000 buckets. To paginate through more buckets, use the returned
  /// `opc-next-page` value with the `page` request parameter.
  ///
  /// To use this and other API operations, you must be authorized in an IAM policy. If you are not authorized,
  /// talk to an administrator. If you are an administrator who needs to write policies to give users access, see
  /// [Getting Started with Policies](https://docs.cloud.oracle.com/Content/Identity/Concepts/policygetstarted.htm).
  ///
  /// - Parameters:
  ///     - namespaceName: The Object Storage namespace used for the request.
  ///     - compartmentId: The ID of the compartment in which to list buckets.
  ///     - limit: Optional maximum number of results per page, or items to return in a paginated "List" call.
  ///     - page: Optional value of the opc-next-page response header from the previous "List" call.
  ///     - fields:  The only supported value of this parameter is 'tags' for now.
  ///     - opcClientRequestId: Optional client request ID for tracing.
  ///  - Returns: The response body will contain an array of BucketSummary resources.
  public func listBuckets(namespaceName: String, compartmentId: String, limit: Int? = nil, page: String? = nil, fields: [String] = ["tags"], opcClientRequestId: String? = nil) async throws
    -> [BucketSummary]
  {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.listBuckets(namespaceName: namespaceName, compartmentId: compartmentId, limit: limit, page: page, fields: fields, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listBuckets] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let bucketSummary = try JSONDecoder().decode([BucketSummary].self, from: data)

    return bucketSummary
  }

  // MARK: - Lists replication policies
  /// Lists the replication policies associated with the specified bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - page: Optional pagination token from the previous response's `opc-next-page` header.
  ///   - limit: Optional maximum number of results per page. Defaults to 100.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing an array of `ReplicationPolicySummary`.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation. If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func listReplicationPolicies(
    namespaceName: String,
    bucketName: String,
    page: String? = nil,
    limit: Int? = 100,
    opcClientRequestId: String? = nil
  ) async throws -> [ReplicationPolicySummary] {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.listReplicationPolicies(namespaceName: namespaceName, bucketName: bucketName, page: page, limit: limit, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listReplicationPolicies] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let replicationPolicySummaries = try JSONDecoder().decode([ReplicationPolicySummary].self, from: data)
    return replicationPolicySummaries
  }

  // MARK: - Lists replications sources
  /// Lists the replication sources of the specified destination bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the destination bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - page: Optional pagination token from the previous response's `opc-next-page` header.
  ///   - limit: Optional maximum number of results per page. Defaults to 100.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing an array of `ReplicationSource`.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation. If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func listReplicationSources(
    namespaceName: String,
    bucketName: String,
    page: String? = nil,
    limit: Int? = 100,
    opcClientRequestId: String? = nil
  ) async throws -> [ReplicationSource] {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.listReplicationSources(namespaceName: namespaceName, bucketName: bucketName, page: page, limit: limit, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listReplicationSources] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let replicationSources = try JSONDecoder().decode([ReplicationSource].self, from: data)
    return replicationSources
  }

  // MARK: - List retention rules
  /// Lists the retention rules for the specified bucket.
  /// The rules are sorted by creation time, with the most recently created rule returned first.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - page: Optional pagination token from the previous response's `opc-next-page` header.

  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing `RetentionRuleCollection`.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation. If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func listRetentionRules(
    namespaceName: String,
    bucketName: String,
    page: String? = nil,
    opcClientRequestId: String? = nil
  ) async throws -> RetentionRuleCollection {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.listRetentionRules(namespaceName: namespaceName, bucketName: bucketName, page: page, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listRetentionRules] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let retentionRuleCollection = try JSONDecoder().decode(RetentionRuleCollection.self, from: data)
    return retentionRuleCollection
  }

  // MARK: - Lists objects
  /// Lists the objects in a bucket. By default, only object names are returned.
  /// Use the `fields` parameter to include additional metadata in the response.
  ///
  /// The operation returns at most 1000 objects. To paginate through more objects,
  /// use the `nextStartWith` value from the response with the `start` parameter.
  /// To filter results, use the `start` and `end` parameters.
  ///
  /// You must be authorized via an IAM policy to use this API. If unauthorized,
  /// contact an administrator. For policy guidance, see:
  /// [Getting Started with Policies](https://docs.cloud.oracle.com/Content/Identity/Concepts/policygetstarted.htm).
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - prefix: Optional string to match against the start of object names in the list query.
  ///   - start: Optional returns object names lexicographically greater than or equal to this value.
  ///   - end: Optional returns object names lexicographically strictly less than this value.
  ///   - limit: Optional maximum number of results per page. See [List Pagination](https://docs.cloud.oracle.com/iaas/Content/API/Concepts/usingapi.htm#nine).
  ///   - delimiter: Optional. When set, only objects without the delimiter character (after an optional prefix) are returned.
  ///     Objects with the delimiter are grouped as prefixes. Only `'/'` is supported.
  ///   - fields: Comma-separated list of additional fields to include in the response. By default
  ///   the response contains: `name`, `size`, `timeCreated` and `timeModified`
  ///     Valid values: `name`, `size`, `etag`, `md5`, `timeCreated`, `timeModified`, `storageTier`, `archivalState`.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///   - startAfter: Optional returns object names lexicographically strictly greater than this value.
  ///
  /// - Returns: A `Response` object containing `ListObjects`.
  public func listObjects(
    namespaceName: String,
    bucketName: String,
    prefix: String? = nil,
    start: String? = nil,
    end: String? = nil,
    limit: Int? = nil,
    delimiter: String? = nil,
    fields: [Field] = [],
    opcClientRequestId: String? = nil,
    startAfter: String? = nil
  ) async throws -> ListObjects {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let customFields = Array(Set(fields + [.name, .size, .timeCreated, .timeModified]))
    let api = ObjectStorageAPI.listObjects(
      namespaceName: namespaceName,
      bucketName: bucketName,
      prefix: prefix,
      start: start,
      end: end,
      limit: limit,
      delimiter: delimiter,
      fields: customFields,
      opcClientRequiredId: opcClientRequestId,
      startAfter: startAfter
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listObjects] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let listObjects = try JSONDecoder().decode(ListObjects.self, from: data)

    return listObjects
  }

  // MARK: - List objects with PAR
  /// Lists the objects in a bucket using a Pre-Authenticated Request (PAR) URL.
  /// This method allows access to bucket contents without requiring authentication headers,
  /// namespace name, or bucket name — all of which are embedded in the PAR URL.
  ///
  /// The operation returns at most 1000 objects. To paginate through more objects,
  /// use the `nextStartWith` value from the response with the `start` parameter.
  /// To filter results, use the `start` and `end` parameters.
  ///
  /// Use the `fields` parameter to include additional metadata in the response.
  /// By default, the response includes: `name`, `size`, `timeCreated`, and `timeModified`.
  ///
  /// - Parameters:
  ///   - parURL: The Pre-Authenticated Request URL pointing to the target bucket.
  ///   - prefix: Optional string to match against the start of object names in the list query.
  ///   - start: Optional returns object names lexicographically greater than or equal to this value.
  ///   - end: Optional returns object names lexicographically strictly less than this value.
  ///   - limit: Optional maximum number of results per page. See [List Pagination](https://docs.cloud.oracle.com/iaas/Content/API/Concepts/usingapi.htm#nine).
  ///   - delimiter: Optional. When set, only objects without the delimiter character (after an optional prefix) are returned.
  ///     Objects with the delimiter are grouped as prefixes. Only `'/'` is supported.
  ///   - fields: Comma-separated list of additional fields to include in the response. By default
  ///   the response contains: `name`, `size`, `timeCreated` and `timeModified`
  ///     Valid values: `name`, `size`, `etag`, `md5`, `timeCreated`, `timeModified`, `storageTier`, `archivalState`.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///   - startAfter: Optional returns object names lexicographically strictly greater than this value.
  ///
  /// - Returns: A `Response` object containing `ListObjects`.

  public func listObjects(
    parURL: URL,
    prefix: String? = nil,
    start: String? = nil,
    end: String? = nil,
    limit: Int? = nil,
    delimiter: String? = nil,
    fields: [Field] = [],
    opcClientRequestId: String? = nil,
    startAfter: String? = nil
  ) async throws -> ListObjects {

    let customFields = Array(Set(fields + [.name, .size, .timeCreated, .timeModified]))
    let api = ObjectStorageAPI.listObjectsWithPAR(
      parURL: parURL,
      prefix: prefix,
      start: start,
      end: end,
      limit: limit,
      delimiter: delimiter,
      fields: customFields,
      opcClientRequiredId: opcClientRequestId,
      startAfter: startAfter
    )

    // The endpoint here is different from the above implementation because it already contains /p, /n, and /b in it.
    guard let host = parURL.host(), let baseURL = URL(string: "https://\(host)") else {
      throw ObjectStorageError.missingRequiredParameter("Malformed PAR URL")
    }
    let req = try buildRequest(api: api, endpoint: baseURL)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listObjectsPAR] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let listObjects = try JSONDecoder().decode(ListObjects.self, from: data)

    return listObjects
  }

  // MARK: - Lists object versions
  /// Lists the object versions in a bucket.
  ///
  /// Returns an `ObjectVersionCollection` containing up to 1000 object versions.
  /// To paginate through more results, use the `page` parameter with the value from the `opc-next-page` response header.
  ///
  /// You must be authorized via an IAM policy to use this operation. For guidance, see:
  /// [Getting Started with Policies](https://docs.cloud.oracle.com/Content/Identity/Concepts/policygetstarted.htm)
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - prefix: Optional string to match against the start of object names in the list query.
  ///   - start: Optional returns object names lexicographically greater than or equal to this value.
  ///   - end: Optional returns object names lexicographically strictly less than this value.
  ///   - limit: Optinal maximum number of results per page.
  ///   - delimiter: Optinal set, only objects without the delimiter character are returned. Only `'/'` is supported.
  ///   - fields: Optional omma-separated list of additional fields to include. Valid values: `name`, `size`, `etag`, `md5`, `timeCreated`, `timeModified`, `storageTier`, `archivalState`.
  ///   - opcClientRequestId: Optional client request ID for tracing. Optional.
  ///   - startAfter: Returns object names lexicographically strictly greater than this value.
  ///   - page: Optional pagination, use the value from the previous response's `opc-next-page` header.
  ///
  /// - Returns: A `Response` object containing `ObjectVersionCollection`.
  ///
  /// TODO:
  ///   - retryConfig: Retry configuration for the operation.
  public func listObjectVersions(
    namespaceName: String,
    bucketName: String,
    prefix: String? = nil,
    start: String? = nil,
    end: String? = nil,
    limit: Int? = nil,
    delimiter: String? = nil,
    fields: String? = nil,
    opcClientRequestId: String? = nil,
    startAfter: String? = nil,
    page: String? = nil,
  ) async throws -> ObjectVersionCollection {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.listObjectVersions(
      namespaceName: namespaceName,
      bucketName: bucketName,
      prefix: prefix,
      start: start,
      end: end,
      limit: limit,
      delimiter: delimiter,
      fields: fields,
      opcClientRequiredId: opcClientRequestId,
      startAfter: startAfter,
      page: page
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listObjectVersions] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let listObjectVersions = try JSONDecoder().decode(ObjectVersionCollection.self, from: data)
    return listObjectVersions
  }

  // MARK: - List preauthenticated requests
  /// Lists pre-authenticated requests for the specified bucket.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - objectNamePrefix: Optional user-specified object name prefix to filter the list of pre-authenticated requests.
  ///   - limit: Optional maximum number of results per page for pagination.
  ///   - page: Optional pagination token from a previous response's `opc-next-page` header.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing an array of `PreauthenticatedRequestSummary`.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation. If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func listPreauthenticatedRequests(
    namespaceName: String,
    bucketName: String,
    objectNamePrefix: String? = nil,
    limit: Int? = nil,
    page: String? = nil,
    opcClientRequestId: String? = nil
  ) async throws -> [PreauthenticatedRequestSummary] {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.listPreauthenticatedRequests(
      namespaceName: namespaceName,
      bucketName: bucketName,
      objectNamePrefix: objectNamePrefix,
      limit: limit,
      page: page,
      opcClientRequestId: opcClientRequestId
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listPreauthenticatedRequests] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let preauthenticatedRequestSummaryList = try JSONDecoder().decode([PreauthenticatedRequestSummary].self, from: data)

    return preauthenticatedRequestSummaryList
  }

  // MARK: - Lists work requests
  /// Lists the work requests in a compartment.
  ///
  /// - Parameters:
  ///   - compartmentId: The OCID of the compartment in which to list work requests.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///   - page: Optional pagination token from a previous list response (`opc-next-page`).
  ///   - limit: Optional maximum number of results to return per page.
  ///
  /// - Returns: A `[WorkRequestSummary]` containing the list of work requests.
  public func listWorkRequests(
    compartmentId: String,
    opcClientRequestId: String? = nil,
    page: String? = nil,
    limit: Int? = nil,
  ) async throws -> [WorkRequestSummary] {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.listWorkRequests(compartmentId: compartmentId, opcCLientRequestId: opcClientRequestId, page: page, limit: limit)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[listWorkRequests] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let workRequestSummaries = try JSONDecoder().decode([WorkRequestSummary].self, from: data)

    return workRequestSummaries
  }

  // MARK: - Makes bucket writable
  /// Stops replication to the destination bucket and removes the replication policy.
  /// Once removed, the bucket becomes writable again, allowing users to modify its contents.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the destination bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object with no data (void).
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for this operation. If not provided, the service-level retry config will be used. If `nil`, no retry will occur.
  public func makeBucketWritable(
    namespaceName: String,
    bucketName: String,
    opcClientRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.makeBucketWritable(
      namespaceName: namespaceName,
      bucketName: bucketName,
      opcClientRequestId: opcClientRequestId
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 204 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[makeBucketWritable] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)

    if let opcClientRequestId = headers["opc-client-request-id"],
      let opcRequestId = headers["opc-request-id"]
    {
      logger.debug("opc-client-request-id: \(opcClientRequestId), opc-request-id: \(opcRequestId)")
    }
  }

  // MARK: - Puts object
  /// Creates a new object or overwrites an existing object with the same name in Object Storage.
  ///
  /// The maximum object size allowed is 50 GiB.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - objectName: The name of the object. Avoid entering confidential information. Example: `"test/object1.log"`
  ///   - putObjectBody: The object data to upload.
  ///   - toFolder: Optional parameter to specify a folder within the bucket where the object will be stored.
  ///   - contentLength: Optional content length of the body.
  ///  - contentMD5: Optional header that defines the base64-encoded MD5 hash of the body.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///   - storageTier: Optional storage tier for the object (e.g., Standard, Archive).
  public func putObject(
    namespaceName: String,
    bucketName: String,
    objectName: String,
    putObjectBody: Data,
    toFolder: String? = nil,
    contentLength: Int? = nil,
    contentMD5: String? = nil,
    opcClientRequestId: String? = nil,
    storageTier: String? = nil,
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let fullObjectName: String
    if let folder = toFolder, !folder.isEmpty {
      fullObjectName = folder.hasSuffix("/") ? folder + objectName : folder + "/" + objectName
    }
    else {
      fullObjectName = objectName
    }

    let api = ObjectStorageAPI.putObject(
      namespaceName: namespaceName,
      bucketName: bucketName,
      objectName: fullObjectName,
      contentLenght: contentLength,
      contentMD5: contentMD5,
      opcClientRequestId: opcClientRequestId,
      StorageTier: storageTier
    )
    var req = try buildRequest(api: api, endpoint: endpoint)

    req.httpBody = putObjectBody

    try signer.sign(&req)

    self.logger.info("[putObject] Starting upload of \(objectName) to folder: \(toFolder ?? "/")")
    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[putObject] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)

    guard let etag = headers["Etag"],
      let lastModified = headers["Last-Modified"],
      let opcContentMd5 = headers["opc-content-md5"],
      let opcRequestId = headers["opc-request-id"],
      let versionId = headers["version-id"]
    else {
      throw ObjectStorageError.invalidResponse("Missing required response headers")
    }

    let opcClientRequestId = headers["opc-client-request-id"] ?? "nil"

    self.logger.info(
      """
      [putObject] Upload of \(objectName) to folder: \(toFolder ?? "root") was successfull.
      ETag: \(etag)
      Last-Modified: \(lastModified)
      opc-client-request-id: \(opcClientRequestId)
      opc-content-md5: \(opcContentMd5)
      opc-request-id: \(opcRequestId)
      Version-Id: \(versionId)
      """
    )
  }

  // MARK: - Puts object (PAR)
  /// Creates a new object or overwrites an existing object with the same name in Object Storage using a Pre-Authenticated Request(PAR) URL.
  ///
  /// The maximum object size allowed is 50 GiB.
  ///
  /// - Parameters:
  ///    - parURL: The full Pre‑Authenticated Request (PAR) URL that grants access to the object.
  ///   - objectName: The name of the object. Avoid entering confidential information. Example: `"test/object1.log"`
  ///   - putObjectBody: The object data to upload.
  ///   - toFolder: Optional parameter to specify a folder within the bucket where the object will be stored.
  ///   - contentLength: Optional content length of the body.
  ///  - contentMD5: Optional header that defines the base64-encoded MD5 hash of the body.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///   - storageTier: Optional storage tier for the object (e.g., Standard, Archive).
  public func putObject(
    parURL: URL,
    objectName: String,
    putObjectBody: Data,
    toFolder: String? = nil,
    contentLength: Int? = nil,
    contentMD5: String? = nil,
    opcClientRequestId: String? = nil,
    storageTier: String? = nil,
  ) async throws {
    // The endpoint here is different from the above implementation because it already contains /p, /n, and /b in it.
    guard let host = parURL.host(), let baseURL = URL(string: "https://\(host)") else {
      throw ObjectStorageError.invalidURL("Malformed PAR URL")
    }

    let fullObjectName: String
    if let folder = toFolder, !folder.isEmpty {
      fullObjectName = folder.hasSuffix("/") ? folder + objectName : folder + "/" + objectName
    }
    else {
      fullObjectName = objectName
    }

    let api = ObjectStorageAPI.putObjectWithPar(
      parURL: parURL,
      objectName: fullObjectName,
      contentLenght: contentLength,
      contentMD5: contentMD5,
      opcClientRequestId: opcClientRequestId,
      StorageTier: storageTier
    )

    var req = try buildRequest(api: api, endpoint: baseURL)

    req.httpBody = putObjectBody

    self.logger.info("[putObjectPAR] Starting upload of \(objectName) to folder: \(toFolder ?? "/")")

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("[putObjectPAR] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)

    guard let etag = headers["Etag"],
      let lastModified = headers["Last-Modified"],
      let opcContentMd5 = headers["opc-content-md5"],
      let opcRequestId = headers["opc-request-id"],
      let versionId = headers["version-id"]
    else {
      throw ObjectStorageError.invalidResponse("Missing required response headers")
    }

    let opcClientRequestId = headers["opc-client-request-id"] ?? "nil"

    self.logger.info(
      """
      [putObjectPAR] Upload of \(objectName) to folder: \(toFolder ?? "root") was successfull.
      ETag: \(etag)
      Last-Modified: \(lastModified)
      opc-client-request-id: \(opcClientRequestId)
      opc-content-md5: \(opcContentMd5)
      opc-request-id: \(opcRequestId)
      Version-Id: \(versionId)
      """
    )
  }

  // MARK: - Reencrypts bucket
  /// Re-encrypts the unique data encryption key used for each object in the bucket using the most recent
  /// version of the master encryption key assigned to the bucket.
  ///
  /// All data encryption keys are encrypted by a master encryption key. By default, Oracle manages these keys,
  /// but you can assign a custom key through the Oracle Cloud Infrastructure Key Management service.
  /// The `kmsKeyId` property of the bucket determines which master encryption key is assigned.
  /// If you assign a new master encryption key, you can call this API to re-encrypt all data encryption keys
  /// with the newly assigned key. You may also want to re-encrypt if the assigned key has been rotated
  /// since objects were last added. If no `kmsKeyId` is associated with the bucket, the call will fail.
  ///
  /// This API initiates a work request to re-encrypt the data encryption keys of all objects created
  /// before the time of the call. The operation may take a long time depending on the number and size of objects.
  /// All versions of objects will be re-encrypted, regardless of whether versioning is enabled or suspended.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A `Response` object with no data payload (`Void`).
  ///
  /// TODO:
  ///- retryConfig: The retry configuration to apply to this operation. If no value is provided, the service-level retry configuration will be used. If `nil` is explicitly provided, the operation will not retry.
  public func reencryptBucket(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.reencryptBucket(namespaceName: namespaceName, bucketName: bucketName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ObjectStorageError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 202 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      self.logger.error("reencryptBucket] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    let headers = convertHeadersToDictionary(httpResponse)
    if let opcRequestId = headers["opc-request-id"], let opcWorkRequestId = headers["opc-work-request-id"] {
      logger.debug("opc-request-id: \(opcRequestId), opc-work-request-id: \(opcWorkRequestId)")
    }
  }

  // MARK: - Reencrypts object
  /// Re-encrypts the data encryption keys that protect the object and its chunks.
  ///
  /// By default, Object Storage manages the master encryption key used to encrypt each object's data encryption keys.
  /// You can alternatively:
  /// - Assign a key that you control via Oracle Cloud Infrastructure Vault.
  /// - Encrypt the object using a customer-provided encryption key (SSE-C).
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - objectName: The name of the object. Avoid entering confidential information. Example: `"test/object1.log"`
  ///   - reencryptObjectDetails: Request object containing re-encryption configuration.
  ///   - versionId: Version ID used to identify a specific version of the object. Optional.
  ///   - opcClientRequestId: Client request ID for tracing. Optional.
  ///
  /// - Returns: A `Response` object with no data payload (`Void`).
  ///
  /// TODO:
  ///   - retryConfig: Retry configuration for the operation. Optional.
  public func reencryptObject(
    namespaceName: String,
    bucketName: String,
    objectName: String,
    reencryptObjectDetails: ReencryptObjectDetails,
    versionId: String? = nil,
    opcClientRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.reencryptObject(namespaceName: namespaceName, bucketName: bucketName, objectName: objectName, versionId: versionId, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    do {
      let payload: Data
      do {
        payload = try JSONEncoder().encode(reencryptObjectDetails)
      }
      catch {
        throw ObjectStorageError.jsonEncodingError("ReencryptObjectDetails cannot be encoded to data")
      }

      req.httpBody = payload

      try signer.sign(&req)

      let (data, response) = try await URLSession.shared.data(for: req)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ObjectStorageError.invalidResponse("Invalid HTTP response")
      }

      if httpResponse.statusCode != 200 {
        let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
        self.logger.error("[reencryptObject] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
        throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
      }

      let headers = convertHeadersToDictionary(httpResponse)
      if let opcClientRequestId = headers["opc-client-request-id"], let opcRequestId = headers["opc-request-id"] {
        logger.debug("opc-client-request-id: \(opcClientRequestId), opc-request-id: \(opcRequestId)")
      }
    }
  }

  // MARK: - Renames object
  /// Renames an object in the specified Object Storage namespace.
  ///
  /// See [Object Names](https://docs.cloud.oracle.com/Content/Object/Tasks/managingobjects.htm#namerequirements)
  /// for object naming requirements.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - renameObjectDetails: The source and destination object names for the rename operation. Avoid entering confidential information.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object with no data payload.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for the operation. If not provided, the service-level retry configuration will be used. If `nil`, the operation will not retry.
  public func renameObject(
    namespaceName: String,
    bucketName: String,
    renameObjectDetails: RenameObjectDetails,
    opcClientRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.renameObject(namespaceName: namespaceName, bucketName: bucketName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    do {
      let payload: Data
      do {
        payload = try JSONEncoder().encode(renameObjectDetails)
      }
      catch {
        throw ObjectStorageError.jsonEncodingError("RenameObjectDetails cannot be encoded to data")
      }

      req.httpBody = payload

      try signer.sign(&req)

      let (data, response) = try await URLSession.shared.data(for: req)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ObjectStorageError.invalidResponse("Invalid HTTP response")
      }

      if httpResponse.statusCode != 200 {
        let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
        self.logger.error("[renameObject] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
        throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
      }

      let headers = convertHeadersToDictionary(httpResponse)

      if let etag = headers["ETag"],
        let lastModified = headers["last-modified"],
        let opcClientRequestId = headers["opc-client-request-id"],
        let opcRequestId = headers["opc-request-id"],
        let versionId = headers["version-id"]
      {

        logger.debug(
          """
          ETag: \(etag)
          Last-Modified: \(lastModified)
          opc-client-request-id: \(opcClientRequestId)
          opc-request-id: \(opcRequestId)
          Version-Id: \(versionId)
          """
        )
      }
    }
  }

  // MARK: - Restores object
  /// Restores the object specified by the `objectName` parameter.
  /// By default, the object will be restored for 24 hours. You can configure the duration using the `hours` parameter.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - restoreObjectsDetails: The request payload containing the object name and restore duration.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object with no data payload.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for the operation. If not provided, the service-level retry configuration will be used. If `nil`, the operation will not retry.
  public func restoreObject(namespaceName: String, bucketName: String, restoreObjectsDetails: RestoreObjectsDetails, opcClientRequestId: String? = nil) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.restoreObject(namespaceName: namespaceName, bucketName: bucketName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    do {
      let payload: Data
      do {
        payload = try JSONEncoder().encode(restoreObjectsDetails)
      }
      catch {
        throw ObjectStorageError.jsonEncodingError("RestoreObjectDetails cannot be encoded to data")
      }

      req.httpBody = payload

      try signer.sign(&req)

      let (data, response) = try await URLSession.shared.data(for: req)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ObjectStorageError.invalidResponse("Invalid HTTP response")
      }

      if httpResponse.statusCode != 202 {
        let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
        self.logger.error("[restoreObject] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
        throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
      }

      let headers = convertHeadersToDictionary(httpResponse)

      if let opcClientRequestId = headers["opc-client-request-id"], let opcRequestId = headers["opc-request-id"] {
        logger.debug(
          """
          opc-client-request-id: \(opcClientRequestId)
          opc-request-id: \(opcRequestId)d)
          """
        )
      }
    }
  }

  // MARK: - Updates bucket
  /// Performs a partial or full update of a bucket's user-defined metadata.
  ///
  /// Use `updateBucket` to move a bucket from one compartment to another within the same tenancy.
  /// Provide the `compartmentId` of the target compartment. For more details, see:
  /// [Moving Resources to a Different Compartment](https://docs.cloud.oracle.com/iaas/Content/Identity/Tasks/managingcompartments.htm#moveRes).
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - updateBucketDetails: The request object containing metadata updates for the bucket.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A `Response` object containing the updated `Bucket`.
  ///
  /// TODO:
  ///  - ifMatch: The entity tag (ETag) to match with the ETag of an existing resource. If the specified ETag matches, GET and HEAD requests will return the resource, and PUT and POST requests will upload the resource.
  ///  - retryConfig: The retry configuration to apply to this operation. If no value is provided, the service-level retry configuration will be used. If `nil` is explicitly provided, the operation will not retry.
  public func updateBucket(
    namespaceName: String,
    bucketName: String,
    updateBucketDetails: UpdateBucketDetails,
    opcClientRequestId: String? = nil
  ) async throws -> Bucket {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.updateBucket(namespaceName: namespaceName, bucketName: bucketName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    do {
      let payload: Data
      do {
        payload = try JSONEncoder().encode(updateBucketDetails)
      }
      catch {
        throw ObjectStorageError.jsonEncodingError("CreateBucketDetails cannot be encoded to data")
      }

      req.httpBody = payload

      try signer.sign(&req)

      let (data, response) = try await URLSession.shared.data(for: req)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ObjectStorageError.invalidResponse("Invalid HTTP response")
      }

      if httpResponse.statusCode != 200 {
        let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
        self.logger.error("[updateBucket] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
        throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
      }

      do {
        let bucket = try JSONDecoder().decode(Bucket.self, from: data)
        return bucket
      }
      catch {
        throw ObjectStorageError.jsonDecodingError("Failed to decode response data to Bucket")
      }
    }
    catch {
      throw error
    }
  }

  // MARK: - Updates namespace metadata
  /// Updates the default compartment designation for buckets created using the Amazon S3 Compatibility API or the Swift API.
  ///
  /// By default, such buckets are created in the root compartment of the Oracle Cloud Infrastructure tenancy.
  /// You can change this default to a different `compartmentId`. All future bucket creations will use the new default,
  /// but previously created buckets will remain unchanged.
  ///
  /// To perform this operation, the user must have the `OBJECTSTORAGE_NAMESPACE_UPDATE` permission.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - updateNamespaceMetadataDetails: The request object containing the new default compartment settings.
  ///   - opcClientRequestId: The client request ID for tracing.
  ///
  /// - Returns: A `Response` object containing `NamespaceMetadata`.
  ///
  /// TODO:
  ///
  ///   - retryConfig: The retry configuration to apply to this operation. If no value is provided, the service-level retry configuration will be used. If `nil` is explicitly provided, the operation will not retry.
  public func updateNamespaceMetadata(
    namespaceName: String,
    metadata: UpdateNamespaceMetadataDetails,
    opcClientRequestId: String? = nil
  ) async throws -> NamespaceMetadata {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.updateNamespaceMetadata(namespaceName: namespaceName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    do {
      let payload: Data
      do {
        payload = try JSONEncoder().encode(metadata)
      }
      catch {
        throw ObjectStorageError.jsonEncodingError("CreateBucketDetails cannot be encoded to data")
      }

      req.httpBody = payload

      try signer.sign(&req)

      let (data, response) = try await URLSession.shared.data(for: req)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ObjectStorageError.invalidResponse("Invalid HTTP response")
      }

      if httpResponse.statusCode != 200 {
        let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
        self.logger.error("[updateNamespaceMetadata] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
        throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
      }

      // TODO: this decoding fails, beacuse the response from the server doesn't contain `namespace`.🤷‍♂️
      ///
      /// https://docs.oracle.com/en-us/iaas/api/#/en/objectstorage/20160918/Namespace/UpdateNamespaceMetadata
      ///
      /// ```
      ///  let responseBody = String(data: data, encoding: .utf8)
      ///  print("Response: \(responseBody ?? "<no body>")")
      /// ```
      /// The response is:
      ///
      /// ``` {"defaultS3CompartmentId":"ocid1.compartment.oc1..aaaaaaaar3gnsxd7vomtvklspmmmjl5i43vd6umbuqa3f6vtgsfmmk4oeuwa","defaultSwiftCompartmentId":"ocid1.compartment.oc1..aaaaaaaar3gnsxd7vomtvklspmmmjl5i43vd6umbuqa3f6vtgsfmmk4oeuwa","namespace":null}
      /// ```
      /// `namespace` is `null`

      do {
        let nameSpaceMetadata = try JSONDecoder().decode(NamespaceMetadata.self, from: data)
        return nameSpaceMetadata
      }
      catch {
        throw ObjectStorageError.jsonDecodingError("Failed to decode response data to Bucket")
      }
    }
    catch {
      throw error
    }
  }

  // MARK: - Updates object storage tier
  /// Changes the storage tier of the object specified by the `objectName` parameter.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - updateObjectStorageTierDetails: The object name and the desired storage tier.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object with no data payload.
  ///
  /// TODO:
  ///   - retryConfig: Optional retry configuration for the operation. If not provided, the service-level retry configuration will be used. If `nil`, the operation will not retry.
  public func updateObjectStorageTier(
    namespaceName: String,
    bucketName: String,
    updateObjectStorageTierDetails: UpdateObjectStorageTierDetails,
    opcClientRequestId: String? = nil
  ) async throws {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.updadateObjectStorageTier(namespaceName: namespaceName, bucketName: bucketName, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    do {
      let payload: Data
      do {
        payload = try JSONEncoder().encode(updateObjectStorageTierDetails)
      }
      catch {
        throw ObjectStorageError.jsonEncodingError("RestoreObjectDetails cannot be encoded to data")
      }

      req.httpBody = payload

      try signer.sign(&req)

      let (data, response) = try await URLSession.shared.data(for: req)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ObjectStorageError.invalidResponse("Invalid HTTP response")
      }

      if httpResponse.statusCode != 200 {
        let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
        self.logger.error("[updateStorageTier] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
        throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
      }

      let headers = convertHeadersToDictionary(httpResponse)

      if let opcClientRequestId = headers["opc-client-request-id"], let opcRequestId = headers["opc-request-id"] {
        logger.debug(
          """
          opc-client-request-id: \(opcClientRequestId)
          opc-request-id: \(opcRequestId)d)
          """
        )
      }
    }
  }

  // MARK: - Updates retenion rule
  /// Updates the specified retention rule. Rule changes typically take effect within 30 seconds.
  ///
  /// - Parameters:
  ///   - namespaceName: The Object Storage namespace used for the request.
  ///   - bucketName: The name of the bucket. Avoid entering confidential information. Example: `"my-new-bucket1"`
  ///   - retentionRuleId: The ID of the retention rule.
  ///   - updateRetentionRuleDetails: Request object for updating the retention rule.
  ///   - opcClientRequestId: Optional client request ID for tracing.
  ///
  /// - Returns: A response object containing the updated `RetentionRule`.
  ///
  /// TODO:
  ///   - retryConfig: (Optional) The retry configuration to apply to this operation. If not provided, the service-level retry configuration will be used. If `nil`, the operation will not retry.
  ///   - ifMatch: (Optional) The entity tag (ETag) to match with the ETag of an existing resource. If matched, GET and HEAD requests will return the resource, and PUT and POST requests will upload the resource.
  public func updateRetentionRule(
    namespaceName: String,
    bucketName: String,
    retentionRuleId: String,
    updateRetentionRuleDetails: UpdateRetentionRuleDetails,
    opcClientRequestId: String? = nil
  ) async throws -> RetentionRule {
    guard let endpoint else {
      throw ObjectStorageError.missingRequiredParameter("No endpoint has been set")
    }

    let api = ObjectStorageAPI.updateRetentionRule(namespaceName: namespaceName, bucketName: bucketName, retentionId: retentionRuleId, opcClientRequestId: opcClientRequestId)
    var req = try buildRequest(api: api, endpoint: endpoint)

    do {
      let payload: Data
      do {
        payload = try JSONEncoder().encode(updateRetentionRuleDetails)
      }
      catch {
        throw ObjectStorageError.jsonEncodingError("UpdateRetentionRuleDetails cannot be encoded to data")
      }

      req.httpBody = payload

      try signer.sign(&req)

      let (data, response) = try await URLSession.shared.data(for: req)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw ObjectStorageError.invalidResponse("Invalid HTTP response")
      }

      if httpResponse.statusCode != 200 {
        let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
        self.logger.error("[updateRetentionRule] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
        throw ObjectStorageError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
      }

      let retenetiobRule = try JSONDecoder().decode(RetentionRule.self, from: data)
      return retenetiobRule
    }
  }
}

// TODO: Find proper place for these below
// Retry configuration
public struct RetryConfig: Sendable {
  let maxAttempts: Int
  let baseDelay: TimeInterval
}

// Convert HTTPURLResponse to dictionary
// TODO: Move to utility file
func convertHeadersToDictionary(_ httpResponse: HTTPURLResponse) -> [String: String] {
  return httpResponse.allHeaderFields.reduce(into: [String: String]()) { dict, pair in
    if let key = pair.key as? String, let value = pair.value as? String {
      dict[key] = value
    }
  }
}
