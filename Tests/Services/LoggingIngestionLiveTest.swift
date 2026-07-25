//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2026 Ilia Sazonov and the oci-swift-sdk project authors
// Licensed under MIT License
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of oci-swift-sdk project authors
//
// SPDX-License-Identifier: MIT License
//
//===----------------------------------------------------------------------===//
//
// Env-guarded live test for LoggingIngestClient. Self-skips (does not fail)
// unless OCI_LOG_ID is set to a real log OCID, so it never runs in CI and never
// fails on a machine without OCI credentials. This is intentionally NOT added
// to UNIT_TEST_FILTER in .github/workflows/linux.yml.
//
// Run locally against the live log group described in BRIEF.md:
//   OCI_CONFIG_FILE=$HOME/.oci/config OCI_PROFILE=<your-profile> \
//   OCI_LOG_ID=ocid1.log.oc1.phx.<redacted> \
//   swift test --filter LoggingIngestionLiveTest
//

import Foundation
import OCIKit
import Testing

struct LoggingIngestionLiveTest {

  @Test("putLogs pushes a real log entry into the configured live log")
  func putLogsLive() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let logId = env["OCI_LOG_ID"], !logId.isEmpty else {
      logger.info("LoggingIngestionLiveTest skipped — set OCI_LOG_ID to a live log OCID to run.")
      return
    }

    let configFilePath = env["OCI_CONFIG_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(NSHomeDirectory())/.oci/config"
    let profileName = env["OCI_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "DEFAULT"

    let signer = try APIKeySigner(configFilePath: configFilePath, configName: profileName)
    let regionId = try extractUserRegion(from: configFilePath, profile: profileName)
    let region = Region.from(regionId: regionId ?? "") ?? .phx

    let client = try LoggingIngestClient(region: region, signer: signer)
    let details = PutLogsDetails(
      logEntryBatches: [
        LogEntryBatch(
          entries: [LogEntry(data: "oci-swift-sdk LoggingIngestionLiveTest probe")],
          source: "oci-swift-sdk-live-test",
          type: "com.oraclecloud.oci-swift-sdk.live-test",
          defaultlogentrytime: Date()
        )
      ]
    )

    try await client.putLogs(logId: logId, details: details)
    logger.info("LoggingIngestionLiveTest: putLogs succeeded against \(logId)")
  }
}
