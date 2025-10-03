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

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// HTTP methods
public enum HTTPMethod: String {
  case get = "GET"
  case post = "POST"
  case put = "PUT"
  case delete = "DELETE"
  case head = "HEAD"
}

// Protocol description
public protocol API {
  var path: String { get }
  var method: HTTPMethod { get }
  var queryItems: [URLQueryItem]? { get }
  var headers: [String: String]? { get }
}

// API
public enum ObjectStorageAPI: API {
  /// Copies object
  case copyObject(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Creates bucket
  case createBucket(namespaceName: String, opcClientRequestId: String? = nil)
  /// Creates replication policy
  case createReplicationPolicy(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Creates retention rule
  case createRetentionRule(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Creates preauthenticated request
  case createPreauthenticatedRequest(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Deletes bucket
  case deleteBucket(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Deletes object
  case deleteObject(namespaceName: String, bucketName: String, objectName: String, opcClientRequestId: String? = nil, versionId: String? = nil)
  /// Deletes replication policy
  case deleteReplicationPolicy(namespaceName: String, bucketName: String, replicationId: String, opcClientRequestId: String? = nil)
  /// Deletes retention rule
  case deleteRetentionRule(namespaceName: String, bucketName: String, retentionId: String, opcClientRequestId: String? = nil)
  /// Deletes preauthenticated request
  case deletePreauthenticatedRequest(namespaceName: String, bucketName: String, parId: String, opcClientRequestId: String? = nil)
  /// Gets bucket
  case getBucket(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Gets object
  case getObject(
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
    httpResponseExpires: String? = nil
  )
  /// Gets replication policy
  case getReplicationPolicy(namespaceName: String, bucketName: String, replicationId: String, opcClientRequestId: String? = nil)
  /// Gets object using PAR
  case getObjectWithPAR(
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
    httpResponseExpires: String? = nil
  )
  /// Gets preauthenticated request
  case getPreauthenticatedRequest(namespaceName: String, bucketName: String, parId: String, opcClientRequestId: String? = nil)
  /// HEAD bucket
  case headBucket(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// HEAD object
  case headObject(
    namespaceName: String,
    bucketName: String,
    objectName: String,
    versionId: String? = nil,
    opcClientRequestId: String? = nil,
    opcSseCustomerAlgorithm: String? = nil,
    opcSseCustomerKey: String? = nil,
    opcSseCustomerKeySha256: String? = nil
  )
  /// Gets namespace
  case getNamespace(compartmentId: String? = nil, opcClientRequestId: String? = nil)
  /// Gets namespace metadata
  case getNamespaceMetadata(namespaceName: String, opcClientRequestId: String? = nil)
  /// Gets retention rule
  case getRetentionRule(namespaceName: String, bucketName: String, retentionId: String, opcClientRequestId: String? = nil)
  /// Lists buckets
  case listBuckets(namespaceName: String, compartmentId: String, opcClientRequestId: String? = nil)
  /// Lists objects
  case listObjects(
    namespaceName: String,
    bucketName: String,
    prefix: String? = nil,
    start: String? = nil,
    end: String? = nil,
    limit: Int? = nil,
    delimiter: String? = nil,
    fields: [Field],
    opcClientRequiredId: String? = nil,
    startAfter: String? = nil
  )
  /// Lists objects using PAR
  case listObjectsWithPAR(
    parURL: URL,
    prefix: String? = nil,
    start: String? = nil,
    end: String? = nil,
    limit: Int? = nil,
    delimiter: String? = nil,
    fields: [Field],
    opcClientRequiredId: String? = nil,
    startAfter: String? = nil
  )
  /// List object versions
  case listObjectVersions(
    namespaceName: String,
    bucketName: String,
    prefix: String? = nil,
    start: String? = nil,
    end: String? = nil,
    limit: Int? = nil,
    delimiter: String? = nil,
    fields: String? = nil,
    opcClientRequiredId: String? = nil,
    startAfter: String? = nil,
    page: String? = nil
  )
  /// Lists replication policies
  case listReplicationPolicies(namespaceName: String, bucketName: String, page: String? = nil, limit: Int? = 100, opcClientRequestId: String? = nil)
  /// Lists replication sources
  case listReplicationSources(namespaceName: String, bucketName: String, page: String? = nil, limit: Int? = 100, opcClientRequestId: String? = nil)
  /// Lists retention rules
  case listRetentionRules(namespaceName: String, bucketName: String, page: String? = nil, opcClientRequestId: String? = nil)
  /// Makes bucket writable
  case makeBucketWritable(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// List preauthenticated requests
  case listPreauthenticatedRequests(namespaceName: String, bucketName: String, objectNamePrefix: String? = nil, limit: Int? = nil, page: String? = nil, opcClientRequestId: String? = nil)
  /// Puts object
  case putObject(
    namespaceName: String,
    bucketName: String,
    objectName: String,
    contentLenght: Int? = nil,
    opcClientRequestId: String? = nil,
    StorageTier: String? = nil
  )
  /// Reencrypts bucket
  case reencryptBucket(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Reencrypts object
  case reencryptObject(
    namespaceName: String,
    bucketName: String,
    objectName: String,
    versionId: String? = nil,
    opcClientRequestId: String? = nil
  )
  /// Renames object
  case renameObject(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Rstores object
  case restoreObject(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Updates bucket
  case updateBucket(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Updates namespace metadata
  case updateNamespaceMetadata(namespaceName: String, opcClientRequestId: String? = nil)
  /// Updates object storage tier
  case updadateObjectStorageTier(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Updates retention rule
  case updateRetentionRule(namespaceName: String, bucketName: String, retentionId: String, opcClientRequestId: String? = nil)

  // Path
  public var path: String {
    switch self {
    case .getNamespace:
      return "/n"
    case .getNamespaceMetadata(let namespaceName, _),
      .updateNamespaceMetadata(let namespaceName, _):
      return "/n/\(namespaceName)"
    case .createBucket(let namespaceName, _),
      .listBuckets(let namespaceName, _, _):
      return "/n/\(namespaceName)/b"
    case .createReplicationPolicy(let namespaceName, let bucketName, _),
      .listReplicationPolicies(let namespaceName, let bucketName, _, _, _):
      return "/n/\(namespaceName)/b/\(bucketName)/replicationPolicies"
    case .createRetentionRule(let namespaceName, let bucketName, _),
      .listRetentionRules(let namespaceName, let bucketName, _, _):
      return "/n/\(namespaceName)/b/\(bucketName)/retentionRules"
    case .deleteReplicationPolicy(let namespaceName, let bucketName, let replicationPolicyId, _),
      .getReplicationPolicy(let namespaceName, let bucketName, let replicationPolicyId, _):
      return "/n/\(namespaceName)/b/\(bucketName)/replicationPolicies/\(replicationPolicyId)"
    case .createPreauthenticatedRequest(let namespaceName, let bucketName, _),
      .listPreauthenticatedRequests(let namespaceName, let bucketName, _, _, _, _):
      return "/n/\(namespaceName)/b/\(bucketName)/p"
    case .deleteBucket(let namespaceName, let bucketName, _),
      .getBucket(let namespaceName, let bucketName, _),
      .headBucket(let namespaceName, let bucketName, _),
      .updateBucket(let namespaceName, let bucketName, _):
      return "/n/\(namespaceName)/b/\(bucketName)"
    case .deletePreauthenticatedRequest(let namespaceName, let bucketName, let parId, _),
      .getPreauthenticatedRequest(let namespaceName, let bucketName, let parId, _):
      return "/n/\(namespaceName)/b/\(bucketName)/p/\(parId)"
    case .deleteRetentionRule(let namespaceName, let bucketName, let retentionRuleId, _),
      .getRetentionRule(let namespaceName, let bucketName, let retentionRuleId, _),
      .updateRetentionRule(let namespaceName, let bucketName, let retentionRuleId, _):
      return "/n/\(namespaceName)/b/\(bucketName)/retentionRules/\(retentionRuleId)"
    case .reencryptBucket(let namespaceName, let bucketName, _):
      return "/n/\(namespaceName)/b/\(bucketName)/actions/reencrypt"
    case .reencryptObject(let namespaceName, let bucketName, let objectName, _, _):
      return "/n/\(namespaceName)/b/\(bucketName)/actions/reencrypt/\(objectName)"
    case .renameObject(let namespaceName, let bucketName, _):
      return "/n/\(namespaceName)/b/\(bucketName)/actions/renameObject"
    case .copyObject(let namespaceName, let bucketName, _):
      return "/n/\(namespaceName)/b/\(bucketName)/actions/copyObject"
    case .listObjects(let namespaceName, let bucketName, _, _, _, _, _, _, _, _):
      return "/n/\(namespaceName)/b/\(bucketName)/o"
    case .listObjectsWithPAR(let parURL, _, _, _, _, _, _, _, _):
      return parURL.path()
    case .listObjectVersions(let namespaceName, let bucketName, _, _, _, _, _, _, _, _, _):
      return "/n/\(namespaceName)/b/\(bucketName)/objectversions"
    case .listReplicationSources(let namespaceName, let bucketName, _, _, _):
      return "/n/\(namespaceName)/b/\(bucketName)/replicationSources"
    case .makeBucketWritable(let namespaceName, let bucketName, _):
      return "/n/\(namespaceName)/b/\(bucketName)/actions/makeBucketWritable"
    case .deleteObject(let namespaceName, let bucketName, let objectName, _, _),
      .getObject(let namespaceName, let bucketName, let objectName, _, _, _, _, _, _, _, _, _, _, _, _),
      .headObject(let namespaceName, let bucketName, let objectName, _, _, _, _, _),
      .putObject(let namespaceName, let bucketName, let objectName, _, _, _):
      return "/n/\(namespaceName)/b/\(bucketName)/o/\(objectName)"
    case .getObjectWithPAR(let parURL, let objectName, _, _, _, _, _, _, _, _, _, _, _, _):
      return "\(parURL.path())\(objectName)"
    case .restoreObject(let namespaceName, let bucketName, _):
      return "/n/\(namespaceName)/b/\(bucketName)/actions/restoreObjects"
    case .updadateObjectStorageTier(let namespaceName, let bucketName, _):
      return "/n/\(namespaceName)/b/\(bucketName)/actions/updateObjectStorageTier"
    }
  }

  // HTTPMethod
  public var method: HTTPMethod {
    switch self {
    case .copyObject,
      .createBucket,
      .createReplicationPolicy,
      .createRetentionRule,
      .createPreauthenticatedRequest,
      .makeBucketWritable,
      .reencryptBucket,
      .reencryptObject,
      .renameObject,
      .restoreObject,
      .updateBucket,
      .updadateObjectStorageTier:
      return .post
    case .deleteBucket,
      .deleteObject,
      .deleteReplicationPolicy,
      .deleteRetentionRule,
      .deletePreauthenticatedRequest:
      return .delete
    case .getNamespace,
      .getBucket,
      .getObject,
      .getObjectWithPAR,
      .getNamespaceMetadata,
      .getReplicationPolicy,
      .getRetentionRule,
      .listBuckets,
      .listObjects,
      .listObjectsWithPAR,
      .listObjectVersions,
      .listReplicationPolicies,
      .listReplicationSources,
      .listRetentionRules,
      .getPreauthenticatedRequest,
      .listPreauthenticatedRequests:
      return .get
    case .headBucket,
      .headObject:
      return .head
    case .putObject,
      .updateNamespaceMetadata,
      .updateRetentionRule:
      return .put
    }
  }

  // QueryItems
  public var queryItems: [URLQueryItem]? {
    switch self {
    case .copyObject,
      .createBucket,
      .createReplicationPolicy,
      .createRetentionRule,
      .deleteBucket,
      .deleteReplicationPolicy,
      .deleteRetentionRule,
      .getBucket,
      .getNamespaceMetadata,
      .getReplicationPolicy,
      .getRetentionRule,
      .createPreauthenticatedRequest,
      .deletePreauthenticatedRequest,
      .getPreauthenticatedRequest,
      .headBucket,
      .makeBucketWritable,
      .putObject,
      .reencryptBucket,
      .renameObject,
      .restoreObject,
      .updateBucket,
      .updateNamespaceMetadata,
      .updadateObjectStorageTier,
      .updateRetentionRule:
      return nil
    case .getNamespace(let compartmentId, _):
      if let compartmentId {
        return [
          URLQueryItem(name: "compartmentId", value: compartmentId)
        ]
      }
      return nil

    case .listBuckets(_, let compartmentId, _):
      return [URLQueryItem(name: "compartmentId", value: compartmentId)]

    case .deleteObject(_, _, _, _, let versionId),
      .reencryptObject(_, _, _, let versionId, _):
      if let versionId {
        return [
          URLQueryItem(name: "versionId", value: versionId)
        ]
      }
      return nil

    case .getObject(
      _,
      _,
      _,
      let versionId,
      _,
      _,
      _,
      _,
      _,
      let httpResponseContentDisposition,
      let httpResponseCacheControl,
      let httpResponseContentType,
      let httpResponseContentLanguage,
      let httpResponseContentEncoding,
      let httpResponseExpires
    ),
      .getObjectWithPAR(
        _,
        _,
        let versionId,
        _,
        _,
        _,
        _,
        _,
        let httpResponseContentDisposition,
        let httpResponseCacheControl,
        let httpResponseContentType,
        let httpResponseContentLanguage,
        let httpResponseContentEncoding,
        let httpResponseExpires
      ):
      let keyValuePairs: [(String, String?)] = [
        ("versionId", versionId),
        ("contentDisposition", httpResponseContentDisposition),
        ("cacheControl", httpResponseCacheControl),
        ("contentType", httpResponseContentType),
        ("contentLanguage", httpResponseContentLanguage),
        ("contentEncoding", httpResponseContentEncoding),
        ("expires", httpResponseExpires),
      ]

      // Convert non-nil values into URLQueryItems
      let queryItems = keyValuePairs.compactMap { key, value in
        value.map { URLQueryItem(name: key, value: $0) }
      }

      return queryItems.isEmpty ? nil : queryItems

    case .headObject(_, _, _, let versionId, _, _, _, _):
      if let versionId {
        return [
          URLQueryItem(name: "versionId", value: versionId)
        ]
      }
      return nil

    case .listReplicationPolicies(_, _, let page, let limit, _),
      .listReplicationSources(_, _, let page, let limit, _):
      let keyValuePairs: [(String, String?)] = [
        ("page", page),
        ("limit", limit.map { String($0) }),
      ]

      // Convert non-nil values into URLQueryItems
      let queryItems = keyValuePairs.compactMap { key, value in
        value.map { URLQueryItem(name: key, value: $0) }
      }

      return queryItems.isEmpty ? nil : queryItems

    case .listObjects(_, _, let prefix, let start, let end, let limit, let delimiter, let fields, _, let startAfter),
      .listObjectsWithPAR(_, let prefix, let start, let end, let limit, let delimiter, let fields, _, let startAfter):
      let keyValuePairs: [(String, String?)] = [
        ("prefix", prefix),
        ("start", start),
        ("end", end),
        ("limit", limit.map { String($0) }),
        ("delimiter", delimiter),
        ("fields", fields.queryValue),
        ("startAfter", startAfter),
      ]

      // Convert non-nil values into URLQueryItems
      let queryItems = keyValuePairs.compactMap { key, value in
        value.map { URLQueryItem(name: key, value: $0) }
      }

      return queryItems.isEmpty ? nil : queryItems

    case .listObjectVersions(_, _, let prefix, let start, let end, let limit, let delimiter, let fields, _, let startAfter, let page):
      let keyValuePairs: [(String, String?)] = [
        ("prefix", prefix),
        ("start", start),
        ("end", end),
        ("limit", limit.map { String($0) }),
        ("delimiter", delimiter),
        ("fields", fields),
        ("startAfter", startAfter),
        ("page", page),
      ]

      // Convert non-nil values into URLQueryItems
      let queryItems = keyValuePairs.compactMap { key, value in
        value.map { URLQueryItem(name: key, value: $0) }
      }

      return queryItems.isEmpty ? nil : queryItems

    case .listRetentionRules(_, _, let page, _):
      if let page {
        return [
          URLQueryItem(name: "page", value: page)
        ]
      }
      return nil

    case .listPreauthenticatedRequests(_, _, let objectNamePrefix, let limit, let page, _):
      let keyValuePairs: [(String, String?)] = [
        ("objectNamePrefix", objectNamePrefix),
        ("limit", limit.map { String($0) }),
        ("page", page),
      ]

      // Convert non-nil values into URLQueryItems
      let queryItems = keyValuePairs.compactMap { key, value in
        value.map { URLQueryItem(name: key, value: $0) }
      }

      return queryItems.isEmpty ? nil : queryItems
    }
  }

  // Headers
  public var headers: [String: String]? {
    switch self {
    case .copyObject(_, _, let opcClientRequestId),
      .createBucket(_, let opcClientRequestId),
      .createReplicationPolicy(_, _, let opcClientRequestId),
      .createRetentionRule(_, _, let opcClientRequestId),
      .deleteBucket(_, _, let opcClientRequestId),
      .deleteObject(_, _, _, let opcClientRequestId, _),
      .deleteReplicationPolicy(_, _, _, let opcClientRequestId),
      .deleteRetentionRule(_, _, _, let opcClientRequestId),
      .createPreauthenticatedRequest(_, _, let opcClientRequestId),
      .deletePreauthenticatedRequest(_, _, _, let opcClientRequestId),
      .getBucket(_, _, let opcClientRequestId),
      .getObject(_, _, _, _, let opcClientRequestId, _, _, _, _, _, _, _, _, _, _),
      .getObjectWithPAR(_, _, _, let opcClientRequestId, _, _, _, _, _, _, _, _, _, _),
      .getNamespace(_, let opcClientRequestId),
      .getNamespaceMetadata(_, let opcClientRequestId),
      .getReplicationPolicy(_, _, _, let opcClientRequestId),
      .getRetentionRule(_, _, _, let opcClientRequestId),
      .getPreauthenticatedRequest(_, _, _, let opcClientRequestId),
      .headBucket(_, _, let opcClientRequestId),
      .headObject(_, _, _, _, let opcClientRequestId, _, _, _),
      .listBuckets(_, _, let opcClientRequestId),
      .listReplicationPolicies(_, _, _, _, let opcClientRequestId),
      .listReplicationSources(_, _, _, _, let opcClientRequestId),
      .listObjects(_, _, _, _, _, _, _, _, let opcClientRequestId, _),
      .listObjectsWithPAR(_, _, _, _, _, _, _, let opcClientRequestId, _),
      .listObjectVersions(_, _, _, _, _, _, _, _, let opcClientRequestId, _, _),
      .listRetentionRules(_, _, _, let opcClientRequestId),
      .makeBucketWritable(_, _, let opcClientRequestId),
      .listPreauthenticatedRequests(_, _, _, _, _, let opcClientRequestId),
      .reencryptBucket(_, _, let opcClientRequestId),
      .reencryptObject(_, _, _, _, let opcClientRequestId),
      .renameObject(_, _, let opcClientRequestId),
      .restoreObject(_, _, let opcClientRequestId),
      .updateBucket(_, _, let opcClientRequestId),
      .updateNamespaceMetadata(_, let opcClientRequestId),
      .updadateObjectStorageTier(_, _, let opcClientRequestId),
      .updateRetentionRule(_, _, _, let opcClientRequestId):
      if let opcClientRequestId {
        return ["opc-client-request-id": opcClientRequestId]
      }
      return nil
    case .putObject(_, _, _, let contentLength, let opcClientRequestId, let storageTier):
      let keyValuePairs: [(String, String)] = [
        ("content-length", contentLength.map { String($0) }),
        ("opc-client-request-id", opcClientRequestId),
        ("storage-tier", storageTier),
      ].compactMap { key, value in
        value.map { (key, $0) }
      }

      let headers = Dictionary(uniqueKeysWithValues: keyValuePairs)
      return headers.isEmpty ? nil : headers
    }
  }
}

/// Build request from components defined in ObjectStorageAPIRouter
public func buildRequest(objectStorageAPI: API, endpoint: URL) throws -> URLRequest {
  guard
    var components = URLComponents(
      url: endpoint,
      resolvingAgainstBaseURL: false
    )
  else {
    throw ObjectStorageError.invalidURL("Enpoint URL is invalid")
  }

  // Build path
  components.path = objectStorageAPI.path

  // Add query items
  components.queryItems = objectStorageAPI.queryItems
  guard let url = components.url else {
    throw ObjectStorageError.invalidURL("Could not construct final URL")
  }

  // Build request
  var request = URLRequest(url: url)
  request.httpMethod = objectStorageAPI.method.rawValue

  // Add headers
  objectStorageAPI.headers?.forEach { key, value in
    request.addValue(value, forHTTPHeaderField: key)
  }
  request.setValue("application/json", forHTTPHeaderField: "accept")
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")

  return request
}
