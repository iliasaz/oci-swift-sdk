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
// Live, credential-gated end-to-end check for MonitoringClient. Self-skips
// (returns before constructing any signer) unless MONITORING_COMPARTMENT_OCID
// is set, so it is safe to leave in the tree — it never runs in CI. Posts a
// single, well-formed data point to a probe namespace; not destructive.
//

import Foundation
import OCIKit
import Testing

struct MonitoringLiveTest {
  @Test("postMetricData: posts one datapoint to a live probe namespace")
  func postsOneDatapointLive() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let compartmentId = env["MONITORING_COMPARTMENT_OCID"], !compartmentId.isEmpty else {
      logger.info("MonitoringLiveTest skipped — set MONITORING_COMPARTMENT_OCID to run")
      return
    }
    let configFilePath = env["OCI_CONFIG_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(NSHomeDirectory())/.oci/config"
    let profile = env["OCI_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "DEFAULT"
    let namespace = env["MONITORING_NAMESPACE"] ?? "ocikit_probe"

    // Post to the region the credentials belong to, otherwise the datapoint
    // lands in a region the maintainer never looks at. OCI_REGION wins, then
    // the profile's own region, then us-phoenix-1.
    let profileRegionId = try extractUserRegion(from: configFilePath, profile: profile)
    let regionId = env["OCI_REGION"] ?? profileRegionId ?? "us-phoenix-1"
    guard let region = Region.from(regionId: regionId) else {
      Issue.record("MonitoringLiveTest: unknown region id '\(regionId)'")
      return
    }

    let signer = try APIKeySigner(configFilePath: configFilePath, configName: profile)
    let client = try MonitoringClient(region: region, signer: signer)

    let details = PostMetricDataDetails(
      metricData: [
        MetricDataDetails(
          namespace: namespace,
          compartmentId: compartmentId,
          name: "ocikit_sdk_live_test",
          dimensions: ["source": "MonitoringLiveTest"],
          datapoints: [MonitoringDatapoint(timestamp: Date(), value: 1)]
        )
      ]
    )

    let response = try await client.postMetricData(details: details)
    logger.info("MonitoringLiveTest postMetricData response: \(response)")
    #expect(response.failedMetricsCount == 0)
  }
}
