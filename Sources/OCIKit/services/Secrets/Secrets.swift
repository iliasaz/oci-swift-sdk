//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2025 Ilia Sazonov and the oci-swift-sdk project authors
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

/// Client for the OCI Secrets Retrieval API.
///
/// Use the Secret Retrieval API to retrieve secrets and secret versions from vaults.
/// For more information, see [Managing Secrets](https://docs.oracle.com/en-us/iaas/Content/KeyManagement/Tasks/managingsecrets.htm).
///
/// ## Example Usage
///
/// ```swift
/// let signer = try APIKeySigner(configFilePath: "~/.oci/config")
/// let client = try SecretsClient(region: .fra, signer: signer)
///
/// // Get a secret by OCID
/// let bundle = try await client.getSecretBundle(secretId: "ocid1.secret.oc1...")
/// if let content = bundle.secretBundleContent?.decodedString {
///     print("Secret value: \(content)")
/// }
/// ```
public struct SecretsClient: Sendable {
  let endpoint: URL?
  let region: Region?
  let retryConfig: RetryConfig?
  let signer: Signer
  let logger: Logger

  // MARK: - Initialization

  /// Initialize the Secrets client.
  ///
  /// - Parameters:
  ///   - region: A region used to determine the service endpoint.
  ///   - endpoint: The fully qualified endpoint URL. If provided, this takes precedence over the region.
  ///   - signer: A signer implementation used for authenticating requests.
  ///   - retryConfig: Optional retry configuration for this service client.
  ///   - logger: Optional logger for debugging and diagnostics.
  ///
  /// - Throws: `SecretsError.missingRequiredParameter` if neither endpoint nor region is specified.
  ///
  /// - Note: Either a region or an endpoint must be specified.
  ///   If an endpoint is specified, it will be used instead of the region.
  public init(
    region: Region? = nil,
    endpoint: String? = nil,
    signer: Signer,
    retryConfig: RetryConfig? = nil,
    logger: Logger = Logger(label: "SecretsClient")
  ) throws {
    self.signer = signer
    self.retryConfig = retryConfig
    self.logger = logger

    if let endpoint, let endpointURL = URL(string: endpoint) {
      self.endpoint = endpointURL
      self.region = nil
    } else {
      guard let region else {
        throw SecretsError.missingRequiredParameter("Either endpoint or region must be specified.")
      }
      self.region = region
      let host = Service.secrets.getHost(in: region)
      self.endpoint = URL(string: "https://\(host)")
    }
  }

  // MARK: - Get Secret Bundle

  /// Gets a secret bundle that matches either the specified `stage`, `secretVersionName`,
  /// or `versionNumber` parameter.
  ///
  /// If none of these parameters are provided, the bundle for the secret version
  /// marked as `CURRENT` will be returned.
  ///
  /// - Parameters:
  ///   - secretId: The OCID of the secret.
  ///   - versionNumber: The version number of the secret.
  ///   - secretVersionName: The name of the secret version. Names are unique across
  ///     the different versions of a secret.
  ///   - stage: The rotation state of the secret version.
  ///   - opcRequestId: Unique identifier for the request.
  ///
  /// - Returns: A `SecretBundle` containing the secret content and metadata.
  ///
  /// - Throws: `SecretsError` if the request fails.
  public func getSecretBundle(
    secretId: String,
    versionNumber: Int? = nil,
    secretVersionName: String? = nil,
    stage: SecretStage? = nil,
    opcRequestId: String? = nil
  ) async throws -> SecretBundle {
    guard let endpoint else {
      throw SecretsError.missingRequiredParameter("No endpoint has been set")
    }

    let api = SecretsAPI.getSecretBundle(
      secretId: secretId,
      versionNumber: versionNumber,
      secretVersionName: secretVersionName,
      stage: stage,
      opcRequestId: opcRequestId
    )

    var req = try buildRequest(api: api, endpoint: endpoint)
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw SecretsError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      logger.error("[getSecretBundle] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw SecretsError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    do {
      let secretBundle = try JSONDecoder().decode(SecretBundle.self, from: data)
      return secretBundle
    } catch {
      throw SecretsError.jsonDecodingError("Failed to decode response data to SecretBundle: \(error)")
    }
  }

  // MARK: - Get Secret Bundle By Name

  /// Gets a secret bundle by secret name and vault ID.
  ///
  /// The secret version returned matches either the specified `stage`, `secretVersionName`,
  /// or `versionNumber` parameter. If none of these parameters are provided, the bundle
  /// for the secret version marked as `CURRENT` is returned.
  ///
  /// - Parameters:
  ///   - secretName: A user-friendly name for the secret. Secret names are unique within a vault
  ///     and are case-sensitive.
  ///   - vaultId: The OCID of the vault that contains the secret.
  ///   - versionNumber: The version number of the secret.
  ///   - secretVersionName: The name of the secret version. Names are unique across
  ///     the different versions of a secret.
  ///   - stage: The rotation state of the secret version.
  ///   - opcRequestId: Unique identifier for the request.
  ///
  /// - Returns: A `SecretBundle` containing the secret content and metadata.
  ///
  /// - Throws: `SecretsError` if the request fails.
  public func getSecretBundleByName(
    secretName: String,
    vaultId: String,
    versionNumber: Int? = nil,
    secretVersionName: String? = nil,
    stage: SecretStage? = nil,
    opcRequestId: String? = nil
  ) async throws -> SecretBundle {
    guard let endpoint else {
      throw SecretsError.missingRequiredParameter("No endpoint has been set")
    }

    let api = SecretsAPI.getSecretBundleByName(
      secretName: secretName,
      vaultId: vaultId,
      versionNumber: versionNumber,
      secretVersionName: secretVersionName,
      stage: stage,
      opcRequestId: opcRequestId
    )

    var req = try buildRequest(api: api, endpoint: endpoint)
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw SecretsError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      logger.error("[getSecretBundleByName] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw SecretsError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    do {
      let secretBundle = try JSONDecoder().decode(SecretBundle.self, from: data)
      return secretBundle
    } catch {
      throw SecretsError.jsonDecodingError("Failed to decode response data to SecretBundle: \(error)")
    }
  }

  // MARK: - List Secret Bundle Versions

  /// Lists all secret bundle versions for the specified secret.
  ///
  /// - Parameters:
  ///   - secretId: The OCID of the secret.
  ///   - limit: The maximum number of items to return in a paginated list call.
  ///   - page: The value of the `opc-next-page` response header from a previous list call.
  ///   - sortBy: The field to sort by. The default order for `VERSION_NUMBER` is descending.
  ///   - sortOrder: The sort order to use, either ascending (`ASC`) or descending (`DESC`).
  ///   - opcRequestId: Unique identifier for the request.
  ///
  /// - Returns: An array of `SecretBundleVersionSummary` objects describing each version.
  ///
  /// - Throws: `SecretsError` if the request fails.
  public func listSecretBundleVersions(
    secretId: String,
    limit: Int? = nil,
    page: String? = nil,
    sortBy: SecretVersionSortBy? = nil,
    sortOrder: SortOrder? = nil,
    opcRequestId: String? = nil
  ) async throws -> [SecretBundleVersionSummary] {
    guard let endpoint else {
      throw SecretsError.missingRequiredParameter("No endpoint has been set")
    }

    let api = SecretsAPI.listSecretBundleVersions(
      secretId: secretId,
      limit: limit,
      page: page,
      sortBy: sortBy,
      sortOrder: sortOrder,
      opcRequestId: opcRequestId
    )

    var req = try buildRequest(api: api, endpoint: endpoint)
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw SecretsError.invalidResponse("Invalid HTTP response")
    }

    if httpResponse.statusCode != 200 {
      let errorBody = try JSONDecoder().decode(DataBody.self, from: data)
      logger.error("[listSecretBundleVersions] \(errorBody.code) (\(httpResponse.statusCode)): \(errorBody.message)")
      throw SecretsError.unexpectedStatusCode(httpResponse.statusCode, errorBody.message)
    }

    do {
      let versions = try JSONDecoder().decode([SecretBundleVersionSummary].self, from: data)
      return versions
    } catch {
      throw SecretsError.jsonDecodingError("Failed to decode response data to [SecretBundleVersionSummary]: \(error)")
    }
  }
}
