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

/// HTTP methods
public enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

/// Protocol description.
public protocol API {
    var path: String { get }
    var method: HTTPMethod { get }
    var queryItems: [URLQueryItem]? { get }
    var headers: [String: String]? { get }
}

public enum ObjectStorageAPI: API {
    /// Creates bucket
    case createBucket(namespaceName: String)
    /// Gets bucket
    case getBucket(namespaceName: String, bucketName: String)
    /// Gets Namespace
    case getNamespace(compartmentId: String? = nil, opcClientRequestId: String? = nil)
    /// Lists buckets
    case listBuckets(namespaceName: String, compartmentId: String)
    
    /// path
    public var path: String {
        switch self {
        case .getNamespace:
            return "/n"
        case .createBucket(let namespaceName),
                .listBuckets(let namespaceName, _):
            return "/n/\(namespaceName)/b"
        case .getBucket(let namespaceName, let bucketName):
            return "/n/\(namespaceName)/b/\(bucketName)"
        }
    }
    
    /// HTTPMethod
    public var method: HTTPMethod {
        switch self {
        case .createBucket:
            return .post
        case .getNamespace,
                .getBucket,
                .listBuckets:
            return .get
        }
    }
    
    /// QueryItems
    public var queryItems: [URLQueryItem]? {
        switch self {
        case .createBucket,
                .getBucket:
            return nil
        case .getNamespace(let compartmentId, _):
            if let compartmentId {
                return [URLQueryItem(name: "compartmentId", value: compartmentId)]
            }
            return nil
        case .listBuckets(_, let compartmentId):
            return [URLQueryItem(name: "compartmentId", value: compartmentId)]
        }
    }
    
    public var headers: [String: String]? {
        switch self {
        case .getNamespace(_, let opcClientRequestId):
            if let opcClientRequestId {
                return ["opc-client-request-id": opcClientRequestId]
            }
            return nil
        case .createBucket,
                .getBucket,
                .listBuckets:
            return nil
        }
    }
}

/// Build url from components defined in ObjectStorageAPIRouter
public func buildRequest(objectStorageAPI: API, endpoint: URL) throws -> URLRequest {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
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
