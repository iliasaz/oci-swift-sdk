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

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Builds a fully configured `URLRequest` for an Object Storage API operation.
///
/// This method takes an API route (conforming to `API`) and a base service
/// endpoint, then constructs a complete request by:
/// - Resolving the base URL into `URLComponents`
/// - Appending the API-specific path
/// - Adding any query parameters defined by the API route
/// - Applying HTTP method and headers
/// - Setting standard JSON request/response headers
///
/// The resulting `URLRequest` is ready to be signed by an OCI signer
/// (e.g., `APIKeySigner`) before being sent.
///
/// - Parameters:
///   - api: The API route describing the path, method,
///     query parameters, and headers for the request.
///   - endpoint: The base service endpoint for the Object Storage service,
///     typically derived from the region (e.g. `https://objectstorage.eu-frankfurt-1.oraclecloud.com`).
///
/// - Throws:
///   - `ObjectStorageError.invalidURL` if the base endpoint cannot be parsed
///     or if the final URL cannot be constructed after applying path and query items.
///
/// - Returns: A configured `URLRequest` containing the full URL, HTTP method,
///   and headers required for the API call (but not yet signed).
public func buildRequest(api: API, endpoint: URL) throws -> URLRequest {
  guard
    var components = URLComponents(
      url: endpoint,
      resolvingAgainstBaseURL: false
    )
  else {
    throw ObjectStorageError.invalidURL("Enpoint URL is invalid")
  }

  // Apply the API-specific path
  components.path = api.path

  // Add query parameters if present
  components.queryItems = api.queryItems

  // Construct the final URL
  guard let url = components.url else {
    throw ObjectStorageError.invalidURL("Could not construct final URL")
  }

  // Build the request
  var request = URLRequest(url: url)
  request.httpMethod = api.method.rawValue

  // Apply custom headers defined by the API route
  api.headers?.forEach { key, value in
    request.addValue(value, forHTTPHeaderField: key)
  }

  // Standard JSON headers
  request.setValue("application/json", forHTTPHeaderField: "accept")
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")

  return request
}
