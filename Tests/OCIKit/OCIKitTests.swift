//
//  OCIKitTests.swift
//
//
//  Created by Ilia Sazonov on 5/8/24.
//

import Foundation
import XCTest

@testable import OCIKit

#if canImport(FoundationNetworking)
   import FoundationNetworking
#endif

final class OCIKitTests: XCTestCase {
  let ociConfigFilePath = ProcessInfo.processInfo.environment["OCI_CONFIG_FILE"] ?? "\(NSHomeDirectory())/.oci/config"
  let ociProfileName = ProcessInfo.processInfo.environment["OCI_PROFILE"] ?? "DEFAULT"

  func test_if_config_file_exists() {
    let fileExists = FileManager.default.fileExists(atPath: ociConfigFilePath)
    XCTAssertTrue(fileExists, "OCI config file does not exist at path: \(ociConfigFilePath)")
  }

  func test_if_namespace_returns_valid_string() async throws {
    // The tenancy OCID is tenancy-specific: supplied by the test plan.
    guard let tenancyId = ProcessInfo.processInfo.environment["OCI_TENANCY_ID"], !tenancyId.isEmpty else {
      throw XCTSkip("Set OCI_TENANCY_ID to run this live test.")
    }
    let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
    // Derive the region from the configured profile rather than pinning one.
    let regionId = try extractUserRegion(from: ociConfigFilePath, profile: ociProfileName)
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let objectStorage = try ObjectStorageClient(region: region, signer: signer)
    let namespace = try await objectStorage.getNamespace(compartmentId: tenancyId)

    XCTAssertFalse(namespace.isEmpty, "Namespace should not be empty")
  }

  func test_if_config_file_is_valid() async throws {
    let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
    guard let userRegion = try extractUserRegion(from: ociConfigFilePath) else {
      XCTFail("Could not extract user region from config file")
      return
    }

    var req = URLRequest(url: URL(string: "https://objectstorage.\(userRegion).oraclecloud.com/n")!)
    try signer.sign(&req)
    logger.info(">>> All Headers: >>> \n\(req.allHTTPHeaderFields ?? [:])\n>>>>>>>>\n")

    let (data, response) = try await URLSession.shared.data(for: req)

    guard let httpResponse = response as? HTTPURLResponse else {
      XCTFail("Invalid HTTP response")
      return
    }

    XCTAssertEqual(httpResponse.statusCode, 200, "Expected HTTP 200 OK, got \(httpResponse.statusCode)")

    let responseBody = String(data: data, encoding: .utf8)
    logger.info("Response: \(responseBody ?? "<no body>")")
  }
}
