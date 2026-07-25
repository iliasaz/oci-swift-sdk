//
//  HealthEntityTest.swift
//  oci-swift-sdk
//
//  Created by Ilia Sazonov on 10/12/25.
//

import Foundation
import OCIKit
import Testing

struct HealthEntityTest {
  let ociConfigFilePath: String
  let ociProfileName: String

  init() throws {
    let env = ProcessInfo.processInfo.environment
    ociConfigFilePath = env["OCI_CONFIG_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(NSHomeDirectory())/.oci/config"
    ociProfileName = env["OCI_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "DEFAULT"
  }

  @Test func testHealthNER() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["HEALTH_NER_ENDPOINT"], !endpoint.isEmpty else {
      logger.info("testHealthNER not configured")
      return
    }
    logger.info("ociProfileName: \(ociProfileName)")
    let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
    let healthNER = BatchDetectHealthEntity(region: .iad, signer: signer)
    let req = BatchDetectHealthEntity.BatchDetectHealthEntityDetails(
      documents: [TextDocument(key: UUID().uuidString, languageCode: "en", text: "lung cancer")],
      endpointId: endpoint,
      isDetectAssertions: true,
      isDetectRelationships: true
    )
    let response = try await healthNER.getHealthEntities(req)
    logger.info("reponse: \(response)")
  }
}
