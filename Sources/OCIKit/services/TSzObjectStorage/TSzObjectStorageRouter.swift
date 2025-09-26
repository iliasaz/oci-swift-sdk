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
  /// Deletes bucket
  case deleteBucket(namespaceName: String, bucketName: String, opcClientRequestId: String? = nil)
  /// Deletes object
  case deleteObject(namespaceName: String, bucketName: String, objectName: String, opcClientRequestId: String? = nil, versionId: String? = nil)
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
    fields: String? = nil,
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
    case .deleteBucket(let namespaceName, let bucketName, _),
      .getBucket(let namespaceName, let bucketName, _),
      .headBucket(let namespaceName, let bucketName, _),
      .updateBucket(let namespaceName, let bucketName, _):
      return "/n/\(namespaceName)/b/\(bucketName)"
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
    case .listObjectVersions(let namespaceName, let bucketName, _, _, _, _, _, _, _, _, _):
      return "/n/\(namespaceName)/b/\(bucketName)/objectversions"
    case .deleteObject(let namespaceName, let bucketName, let objectName, _, _),
      .getObject(let namespaceName, let bucketName, let objectName, _, _, _, _, _, _, _, _, _, _, _, _),
      .headObject(let namespaceName, let bucketName, let objectName, _, _, _, _, _),
      .putObject(let namespaceName, let bucketName, let objectName, _, _, _):
      return "/n/\(namespaceName)/b/\(bucketName)/o/\(objectName)"
    case .restoreObject(let namespaceName, let bucketName, _):
      return "/n/\(namespaceName)/b/\(bucketName)/actions/restoreObject"
    case .updadateObjectStorageTier(let namespaceName, let bucketName, _):
      return "/n/\(namespaceName)/b/\(bucketName)/actions/updateObjectStorageTier"
    }
  }

  // HTTPMethod
  public var method: HTTPMethod {
    switch self {
    case .copyObject,
      .createBucket,
      .reencryptBucket,
      .reencryptObject,
      .renameObject,
      .restoreObject,
      .updateBucket,
      .updadateObjectStorageTier:
      return .post
    case .deleteBucket,
      .deleteObject:
      return .delete
    case .getNamespace,
      .getBucket,
      .getObject,
      .getNamespaceMetadata,
      .listBuckets,
      .listObjects,
      .listObjectVersions:
      return .get
    case .headBucket,
      .headObject:
      return .head
    case .putObject,
      .updateNamespaceMetadata:
      return .put
    }
  }

  // QueryItems
  public var queryItems: [URLQueryItem]? {
    switch self {
    case .copyObject,
      .createBucket,
      .deleteBucket,
      .getBucket,
      .getNamespaceMetadata,
      .headBucket,
      .putObject,
      .reencryptBucket,
      .renameObject,
      .restoreObject,
      .updateBucket,
      .updateNamespaceMetadata,
      .updadateObjectStorageTier:
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

    case .listObjects(_, _, let prefix, let start, let end, let limit, let delimiter, let fields, _, let startAfter):
      let keyValuePairs: [(String, String?)] = [
        ("prefix", prefix),
        ("start", start),
        ("end", end),
        ("limit", limit.map { String($0) }),
        ("delimiter", delimiter),
        ("fields", fields),
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
    }
  }

  // Headers
  public var headers: [String: String]? {
    switch self {
    case .copyObject(_, _, let opcClientRequestId),
      .createBucket(_, let opcClientRequestId),
      .deleteBucket(_, _, let opcClientRequestId),
      .deleteObject(_, _, _, let opcClientRequestId, _),
      .getBucket(_, _, let opcClientRequestId),
      .getObject(_, _, _, _, let opcClientRequestId, _, _, _, _, _, _, _, _, _, _),
      .getNamespace(_, let opcClientRequestId),
      .getNamespaceMetadata(_, let opcClientRequestId),
      .headBucket(_, _, let opcClientRequestId),
      .headObject(_, _, _, _, let opcClientRequestId, _, _, _),
      .listBuckets(_, _, let opcClientRequestId),
      .listObjects(_, _, _, _, _, _, _, _, let opcClientRequestId, _),
      .listObjectVersions(_, _, _, _, _, _, _, _, let opcClientRequestId, _, _),
      .reencryptBucket(_, _, let opcClientRequestId),
      .reencryptObject(_, _, _, _, let opcClientRequestId),
      .renameObject(_, _, let opcClientRequestId),
      .restoreObject(_, _, let opcClientRequestId),
      .updateBucket(_, _, let opcClientRequestId),
      .updateNamespaceMetadata(_, let opcClientRequestId),
      .updadateObjectStorageTier(_, _, let opcClientRequestId):
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
