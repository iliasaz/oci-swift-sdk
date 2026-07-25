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
import Testing

@testable import OCIKit

// MARK: - Model Decoding Tests

struct SecretBundleDecodingTests {

  @Test("Decodes SecretBundle with Base64 content")
  func decodesSecretBundleWithBase64Content() throws {
    let json = """
      {
        "secretId": "ocid1.secret.oc1..example",
        "versionNumber": 1,
        "versionName": "v1",
        "secretBundleContent": {
          "contentType": "BASE64",
          "content": "SGVsbG8gV29ybGQh"
        },
        "stages": ["CURRENT", "LATEST"],
        "metadata": {"key": "value"},
        "timeCreated": "2025-01-15T10:30:00.000Z"
      }
      """

    let data = json.data(using: .utf8)!
    let bundle = try JSONDecoder().decode(SecretBundle.self, from: data)

    #expect(bundle.secretId == "ocid1.secret.oc1..example")
    #expect(bundle.versionNumber == 1)
    #expect(bundle.versionName == "v1")
    #expect(bundle.stages?.count == 2)
    #expect(bundle.stages?.contains(.current) == true)
    #expect(bundle.stages?.contains(.latest) == true)
    #expect(bundle.metadata?["key"] == "value")
    #expect(bundle.timeCreated != nil)
  }

  @Test("Decodes SecretBundle without optional fields")
  func decodesSecretBundleMinimal() throws {
    let json = """
      {
        "secretId": "ocid1.secret.oc1..example",
        "versionNumber": 5
      }
      """

    let data = json.data(using: .utf8)!
    let bundle = try JSONDecoder().decode(SecretBundle.self, from: data)

    #expect(bundle.secretId == "ocid1.secret.oc1..example")
    #expect(bundle.versionNumber == 5)
    #expect(bundle.versionName == nil)
    #expect(bundle.secretBundleContent == nil)
    #expect(bundle.stages == nil)
    #expect(bundle.metadata == nil)
    #expect(bundle.timeCreated == nil)
    #expect(bundle.timeOfDeletion == nil)
    #expect(bundle.timeOfExpiry == nil)
  }

  @Test("Decodes SecretBundle with all date fields")
  func decodesSecretBundleWithDates() throws {
    let json = """
      {
        "secretId": "ocid1.secret.oc1..example",
        "versionNumber": 1,
        "timeCreated": "2025-01-15T10:30:00.000Z",
        "timeOfDeletion": "2026-01-15T10:30:00.000Z",
        "timeOfExpiry": "2025-12-31T23:59:59.000Z"
      }
      """

    let data = json.data(using: .utf8)!
    let bundle = try JSONDecoder().decode(SecretBundle.self, from: data)

    #expect(bundle.timeCreated != nil)
    #expect(bundle.timeOfDeletion != nil)
    #expect(bundle.timeOfExpiry != nil)
  }
}

struct SecretBundleContentDetailsDecodingTests {

  @Test("Decodes Base64 content details")
  func decodesBase64Content() throws {
    let json = """
      {
        "contentType": "BASE64",
        "content": "SGVsbG8gV29ybGQh"
      }
      """

    let data = json.data(using: .utf8)!
    let content = try JSONDecoder().decode(SecretBundleContentDetails.self, from: data)

    #expect(content.contentType == .base64)
    #expect(content.content == "SGVsbG8gV29ybGQh")
  }

  @Test("Decodes Base64 content to string")
  func decodesBase64ContentToString() throws {
    let json = """
      {
        "contentType": "BASE64",
        "content": "SGVsbG8gV29ybGQh"
      }
      """

    let data = json.data(using: .utf8)!
    let content = try JSONDecoder().decode(SecretBundleContentDetails.self, from: data)

    #expect(content.decodedString == "Hello World!")
  }

  @Test("Decodes Base64 content to Data")
  func decodesBase64ContentToData() throws {
    let json = """
      {
        "contentType": "BASE64",
        "content": "SGVsbG8gV29ybGQh"
      }
      """

    let data = json.data(using: .utf8)!
    let content = try JSONDecoder().decode(SecretBundleContentDetails.self, from: data)

    let decodedData = content.decodedData
    #expect(decodedData != nil)
    #expect(decodedData?.count == 12)
  }

  @Test("Handles empty content")
  func handlesEmptyContent() throws {
    let json = """
      {
        "contentType": "BASE64",
        "content": ""
      }
      """

    let data = json.data(using: .utf8)!
    let content = try JSONDecoder().decode(SecretBundleContentDetails.self, from: data)

    #expect(content.content == "")
    #expect(content.decodedString == "")
  }

  @Test("Handles missing content field")
  func handlesMissingContentField() throws {
    let json = """
      {
        "contentType": "BASE64"
      }
      """

    let data = json.data(using: .utf8)!
    let content = try JSONDecoder().decode(SecretBundleContentDetails.self, from: data)

    #expect(content.content == "")
  }

  @Test("Encodes Base64 content details")
  func encodesBase64Content() throws {
    let content = SecretBundleContentDetails.base64(content: "SGVsbG8=")

    let data = try JSONEncoder().encode(content)
    let json = String(data: data, encoding: .utf8)!

    #expect(json.contains("\"contentType\":\"BASE64\""))
    #expect(json.contains("\"content\":\"SGVsbG8=\""))
  }
}

struct SecretBundleVersionSummaryDecodingTests {

  @Test("Decodes SecretBundleVersionSummary")
  func decodesVersionSummary() throws {
    let json = """
      {
        "secretId": "ocid1.secret.oc1..example",
        "versionNumber": 3,
        "versionName": "v3-release",
        "stages": ["PREVIOUS"],
        "timeCreated": "2025-01-10T08:00:00.000Z"
      }
      """

    let data = json.data(using: .utf8)!
    let summary = try JSONDecoder().decode(SecretBundleVersionSummary.self, from: data)

    #expect(summary.secretId == "ocid1.secret.oc1..example")
    #expect(summary.versionNumber == 3)
    #expect(summary.versionName == "v3-release")
    #expect(summary.stages?.count == 1)
    #expect(summary.stages?.contains(.previous) == true)
    #expect(summary.timeCreated != nil)
  }

  @Test("Decodes array of SecretBundleVersionSummary")
  func decodesVersionSummaryArray() throws {
    let json = """
      [
        {
          "secretId": "ocid1.secret.oc1..example",
          "versionNumber": 1,
          "stages": ["DEPRECATED"]
        },
        {
          "secretId": "ocid1.secret.oc1..example",
          "versionNumber": 2,
          "stages": ["PREVIOUS"]
        },
        {
          "secretId": "ocid1.secret.oc1..example",
          "versionNumber": 3,
          "stages": ["CURRENT", "LATEST"]
        }
      ]
      """

    let data = json.data(using: .utf8)!
    let summaries = try JSONDecoder().decode([SecretBundleVersionSummary].self, from: data)

    #expect(summaries.count == 3)
    #expect(summaries[0].versionNumber == 1)
    #expect(summaries[1].versionNumber == 2)
    #expect(summaries[2].versionNumber == 3)
  }
}

struct SecretsEnumsTests {

  @Test("SecretStage encodes correctly")
  func secretStageEncodes() throws {
    let stages: [SecretStage] = [.current, .pending, .latest, .previous, .deprecated]
    let data = try JSONEncoder().encode(stages)
    let json = String(data: data, encoding: .utf8)!

    #expect(json.contains("CURRENT"))
    #expect(json.contains("PENDING"))
    #expect(json.contains("LATEST"))
    #expect(json.contains("PREVIOUS"))
    #expect(json.contains("DEPRECATED"))
  }

  @Test("SecretStage decodes correctly")
  func secretStageDecodes() throws {
    let json = "[\"CURRENT\", \"PENDING\", \"LATEST\", \"PREVIOUS\", \"DEPRECATED\"]"
    let data = json.data(using: .utf8)!
    let stages = try JSONDecoder().decode([SecretStage].self, from: data)

    #expect(stages.count == 5)
    #expect(stages[0] == .current)
    #expect(stages[1] == .pending)
    #expect(stages[2] == .latest)
    #expect(stages[3] == .previous)
    #expect(stages[4] == .deprecated)
  }

  @Test("SecretVersionSortBy encodes correctly")
  func secretVersionSortByEncodes() throws {
    let sortBy = SecretVersionSortBy.versionNumber
    let data = try JSONEncoder().encode(sortBy)
    let json = String(data: data, encoding: .utf8)!

    #expect(json.contains("VERSION_NUMBER"))
  }

  @Test("SecretContentType encodes correctly")
  func secretContentTypeEncodes() throws {
    let contentType = SecretContentType.base64
    let data = try JSONEncoder().encode(contentType)
    let json = String(data: data, encoding: .utf8)!

    #expect(json.contains("BASE64"))
  }
}

// MARK: - Router Tests

struct SecretsRouterTests {

  @Test("getSecretBundle path is correct")
  func getSecretBundlePath() {
    let api = SecretsAPI.getSecretBundle(secretId: "ocid1.secret.oc1..abc123")

    #expect(api.path == "/20190301/secretbundles/ocid1.secret.oc1..abc123")
    #expect(api.method == .get)
  }

  @Test("getSecretBundle query items with all parameters")
  func getSecretBundleQueryItems() {
    let api = SecretsAPI.getSecretBundle(
      secretId: "ocid1.secret.oc1..abc123",
      versionNumber: 5,
      secretVersionName: "v5-release",
      stage: .current
    )

    let queryItems = api.queryItems
    #expect(queryItems != nil)
    #expect(queryItems?.count == 3)

    let queryDict = Dictionary(uniqueKeysWithValues: queryItems!.map { ($0.name, $0.value) })
    #expect(queryDict["versionNumber"] == "5")
    #expect(queryDict["secretVersionName"] == "v5-release")
    #expect(queryDict["stage"] == "CURRENT")
  }

  @Test("getSecretBundle query items with no optional parameters")
  func getSecretBundleNoQueryItems() {
    let api = SecretsAPI.getSecretBundle(secretId: "ocid1.secret.oc1..abc123")

    #expect(api.queryItems == nil)
  }

  @Test("getSecretBundleByName path is correct")
  func getSecretBundleByNamePath() {
    let api = SecretsAPI.getSecretBundleByName(
      secretName: "my-secret",
      vaultId: "ocid1.vault.oc1..xyz789"
    )

    #expect(api.path == "/20190301/secretbundles/actions/getByName")
    #expect(api.method == .post)
  }

  @Test("getSecretBundleByName query items")
  func getSecretBundleByNameQueryItems() {
    let api = SecretsAPI.getSecretBundleByName(
      secretName: "my-secret",
      vaultId: "ocid1.vault.oc1..xyz789",
      versionNumber: 2,
      stage: .latest
    )

    let queryItems = api.queryItems
    #expect(queryItems != nil)

    let queryDict = Dictionary(uniqueKeysWithValues: queryItems!.map { ($0.name, $0.value) })
    #expect(queryDict["secretName"] == "my-secret")
    #expect(queryDict["vaultId"] == "ocid1.vault.oc1..xyz789")
    #expect(queryDict["versionNumber"] == "2")
    #expect(queryDict["stage"] == "LATEST")
  }

  @Test("listSecretBundleVersions path is correct")
  func listSecretBundleVersionsPath() {
    let api = SecretsAPI.listSecretBundleVersions(secretId: "ocid1.secret.oc1..abc123")

    #expect(api.path == "/20190301/secretbundles/ocid1.secret.oc1..abc123/versions")
    #expect(api.method == .get)
  }

  @Test("listSecretBundleVersions query items with pagination")
  func listSecretBundleVersionsQueryItems() {
    let api = SecretsAPI.listSecretBundleVersions(
      secretId: "ocid1.secret.oc1..abc123",
      limit: 10,
      page: "next-page-token",
      sortBy: .versionNumber,
      sortOrder: .desc
    )

    let queryItems = api.queryItems
    #expect(queryItems != nil)

    let queryDict = Dictionary(uniqueKeysWithValues: queryItems!.map { ($0.name, $0.value) })
    #expect(queryDict["limit"] == "10")
    #expect(queryDict["page"] == "next-page-token")
    #expect(queryDict["sortBy"] == "VERSION_NUMBER")
    #expect(queryDict["sortOrder"] == "DESC")
  }

  @Test("Headers include opc-request-id when provided")
  func headersWithOpcRequestId() {
    let api = SecretsAPI.getSecretBundle(
      secretId: "ocid1.secret.oc1..abc123",
      opcRequestId: "test-request-123"
    )

    let headers = api.headers
    #expect(headers != nil)
    #expect(headers?["opc-request-id"] == "test-request-123")
  }

  @Test("Headers are nil when opc-request-id not provided")
  func headersWithoutOpcRequestId() {
    let api = SecretsAPI.getSecretBundle(secretId: "ocid1.secret.oc1..abc123")

    #expect(api.headers == nil)
  }
}

// MARK: - Error Tests

struct SecretsErrorTests {

  @Test("SecretsError descriptions are correct")
  func errorDescriptions() {
    let invalidResponse = SecretsError.invalidResponse("Bad response")
    #expect(invalidResponse.localizedDescription.contains("Bad response"))

    let invalidURL = SecretsError.invalidURL("https://bad.url")
    #expect(invalidURL.localizedDescription.contains("https://bad.url"))

    let jsonError = SecretsError.jsonDecodingError("Missing field")
    #expect(jsonError.localizedDescription.contains("Missing field"))

    let missingParam = SecretsError.missingRequiredParameter("secretId")
    #expect(missingParam.localizedDescription.contains("secretId"))

    let unexpectedStatus = SecretsError.unexpectedStatusCode(404, "Not found")
    #expect(unexpectedStatus.localizedDescription.contains("404"))
    #expect(unexpectedStatus.localizedDescription.contains("Not found"))
  }
}

// MARK: - Client Initialization Tests

struct SecretsClientInitTests {

  @Test("Client initializes with region")
  func initWithRegion() throws {
    let signer = try APIKeySigner(
      configFilePath: "\(NSHomeDirectory())/.oci/config",
      configName: "DEFAULT"
    )

    let client = try SecretsClient(region: .fra, signer: signer)

    #expect(client.endpoint != nil)
    #expect(client.endpoint?.absoluteString.contains("secrets.vaults.eu-frankfurt-1") == true)
  }

  @Test("Client initializes with custom endpoint")
  func initWithEndpoint() throws {
    let signer = try APIKeySigner(
      configFilePath: "\(NSHomeDirectory())/.oci/config",
      configName: "DEFAULT"
    )

    let client = try SecretsClient(
      endpoint: "https://custom.secrets.endpoint.com",
      signer: signer
    )

    #expect(client.endpoint?.absoluteString == "https://custom.secrets.endpoint.com")
  }

  @Test("Client throws when no region or endpoint")
  func initThrowsWithoutRegionOrEndpoint() throws {
    let signer = try APIKeySigner(
      configFilePath: "\(NSHomeDirectory())/.oci/config",
      configName: "DEFAULT"
    )

    #expect(throws: SecretsError.self) {
      _ = try SecretsClient(signer: signer)
    }
  }
}

// MARK: - Integration Tests

/// Live Secrets tests. The secret/vault they read are tenancy-specific, so they
/// come from the environment (see the test plan) and the suite self-skips when
/// `OCI_SECRET_ID` is not set.
@Suite(
  .enabled(
    if: !(ProcessInfo.processInfo.environment["OCI_SECRET_ID"] ?? "").isEmpty,
    "Set OCI_SECRET_ID / OCI_VAULT_ID / OCI_SECRET_NAME to run the Secrets live suite."
  ))
struct SecretsIntegrationTest {
  let ociConfigFilePath: String
  let ociProfileName: String

  // Tenancy-specific test resources, supplied by the test plan.
  let testSecretId: String
  let testVaultId: String
  let testSecretName: String

  init() throws {
    let env = ProcessInfo.processInfo.environment
    ociConfigFilePath = env["OCI_CONFIG_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(NSHomeDirectory())/.oci/config"
    ociProfileName = env["OCI_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "DEFAULT"
    testSecretId = env["OCI_SECRET_ID"] ?? ""
    testVaultId = env["OCI_VAULT_ID"] ?? ""
    testSecretName = env["OCI_SECRET_NAME"] ?? ""
  }

  // MARK: - Get Secret Bundle

  @Test("Gets secret bundle by OCID with API key signer")
  func getSecretBundleWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try SecretsClient(region: region, signer: signer)
    let secretBundle = try? await sut.getSecretBundle(secretId: testSecretId)

    // Print secret info (not the actual content for security)
    if let bundle = secretBundle {
      logger.info("Secret ID: \(bundle.secretId)")
      logger.info("Version: \(bundle.versionNumber)")
      logger.info("Stages: \(bundle.stages ?? [])")
    }

    #expect(secretBundle != nil, "Secret bundle should not be nil")
  }

  @Test("Gets secret bundle with specific version number")
  func getSecretBundleWithVersionNumber() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try SecretsClient(region: region, signer: signer)
    let secretBundle = try? await sut.getSecretBundle(
      secretId: testSecretId,
      versionNumber: 1
    )

    if let bundle = secretBundle {
      logger.info("Retrieved version: \(bundle.versionNumber)")
      #expect(bundle.versionNumber == 1, "Should retrieve version 1")
    }

    #expect(secretBundle != nil, "Secret bundle should not be nil")
  }

  @Test("Gets secret bundle with stage parameter")
  func getSecretBundleWithStage() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try SecretsClient(region: region, signer: signer)
    let secretBundle = try? await sut.getSecretBundle(
      secretId: testSecretId,
      stage: .current
    )

    if let bundle = secretBundle {
      logger.info("Stages: \(bundle.stages ?? [])")
      #expect(bundle.stages?.contains(.current) == true, "Should contain CURRENT stage")
    }

    #expect(secretBundle != nil, "Secret bundle should not be nil")
  }

  // MARK: - Get Secret Bundle By Name

  @Test("Gets secret bundle by name with API key signer")
  func getSecretBundleByNameWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try SecretsClient(region: region, signer: signer)
    let secretBundle = try? await sut.getSecretBundleByName(
      secretName: testSecretName,
      vaultId: testVaultId
    )

    if let bundle = secretBundle {
      logger.info("Secret ID: \(bundle.secretId)")
      logger.info("Version: \(bundle.versionNumber)")
    }

    #expect(secretBundle != nil, "Secret bundle should not be nil")
  }

  // MARK: - List Secret Bundle Versions

  @Test("Lists secret bundle versions with API key signer")
  func listSecretBundleVersionsWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try SecretsClient(region: region, signer: signer)
    let versions = try? await sut.listSecretBundleVersions(secretId: testSecretId)

    if let versions {
      logger.info("Found \(versions.count) version(s)")
      for version in versions {
        logger.info("  Version \(version.versionNumber): \(version.stages ?? [])")
      }
    }

    #expect(versions != nil, "Versions list should not be nil")
  }

  @Test("Lists secret bundle versions with limit")
  func listSecretBundleVersionsWithLimit() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try SecretsClient(region: region, signer: signer)
    let versions = try? await sut.listSecretBundleVersions(
      secretId: testSecretId,
      limit: 5
    )

    if let versions {
      logger.info("Found \(versions.count) version(s) (limit 5)")
      #expect(versions.count <= 5, "Should return at most 5 versions")
    }

    #expect(versions != nil, "Versions list should not be nil")
  }

  @Test("Lists secret bundle versions with sorting")
  func listSecretBundleVersionsWithSorting() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try SecretsClient(region: region, signer: signer)
    let versions = try? await sut.listSecretBundleVersions(
      secretId: testSecretId,
      sortBy: .versionNumber,
      sortOrder: .asc
    )

    if let versions, versions.count > 1 {
      // Verify ascending order
      for i in 1..<versions.count {
        #expect(
          versions[i].versionNumber >= versions[i - 1].versionNumber,
          "Versions should be in ascending order"
        )
      }
    }

    #expect(versions != nil, "Versions list should not be nil")
  }

  // MARK: - Decode Secret Content

  @Test("Decodes Base64 secret content")
  func decodeBase64SecretContent() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try SecretsClient(region: region, signer: signer)
    let secretBundle = try? await sut.getSecretBundle(secretId: testSecretId)

    if let bundle = secretBundle, let content = bundle.secretBundleContent {
      #expect(content.contentType == .base64, "Content type should be BASE64")

      // Verify we can decode it
      let decodedData = content.decodedData
      #expect(decodedData != nil, "Should be able to decode Base64 content")

      // Don't print actual secret value for security
      logger.info("Secret content length: \(decodedData?.count ?? 0) bytes")
    }

    #expect(secretBundle != nil, "Secret bundle should not be nil")
  }
}
