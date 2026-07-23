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
// Diagnostics for the reported issue: on Linux `putObject` threw even though
// the object was successfully uploaded. Root cause: response-header casing.
//
// The SDK used to look up response headers with exact-case keys against a plain,
// case-sensitive `[String: String]` built from `HTTPURLResponse.allHeaderFields`.
// swift-corelibs-foundation (Linux) normalizes response header names to capitalized
// "Http-Header-Case" (e.g. `Opc-Request-Id`), while Darwin preserves the server's
// original casing for custom headers (`opc-request-id`). The lowercase lookups
// therefore missed on Linux and `putObject` threw `.invalidResponse("Missing
// required response headers")` AFTER the server already returned 200.
//
// The fix reads every header via `HTTPURLResponse.value(forHTTPHeaderField:)`,
// which is case-insensitive on both platforms. These tests both reproduce the
// original failure and prove the fix: run them on macOS and Linux and compare.
//

import Foundation
import OCIKit
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite(.enabled(if: destructiveTestsEnabled, Comment(rawValue: destructiveTestsSkipComment)))
struct PutObjectHeaderCasingDiagnostics {
  let configPath: String
  let profile: String
  let bucketName: String

  init() {
    let env = ProcessInfo.processInfo.environment
    configPath = env["OCI_CONFIG_FILE"] ?? "\(NSHomeDirectory())/.oci/config"
    profile = env["OCI_PROFILE"] ?? "DEFAULT"
    bucketName = env["OCI_TEST_BUCKET"] ?? "myTestBucket"
  }

  private var platform: String {
    #if os(Linux)
      return "Linux"
    #else
      return "Darwin"
    #endif
  }

  /// Builds the signer and a service endpoint from the DEFAULT profile.
  private func makeSignerAndEndpoint() throws -> (signer: APIKeySigner, endpoint: URL, region: Region) {
    let regionId = (try extractUserRegion(from: configPath, profile: profile)) ?? "us-ashburn-1"
    let region = Region.from(regionId: regionId) ?? .iad
    let signer = try APIKeySigner(configFilePath: configPath, configName: profile)
    // Same endpoint shape the client builds internally: https://<host>/n
    guard let endpoint = URL(string: "https://objectstorage.\(regionId).oraclecloud.com/n") else {
      throw ObjectStorageError.invalidURL("Could not build endpoint for region \(regionId)")
    }
    return (signer, endpoint, region)
  }

  // MARK: - 1. Dump the real response-header casing from a live PutObject
  //
  // Performs the SAME request `putObject` performs, but prints the headers
  // verbatim so the exact casing Foundation produces on this platform is visible.
  @Test("Dump real PutObject response-header casing")
  func dumpRealResponseHeaderCasing() async throws {
    let (signer, endpoint, region) = try makeSignerAndEndpoint()
    let client = try ObjectStorageClient(region: region, signer: signer)
    let namespace = try await client.getNamespace()

    logger.info("\n========== [\(platform)] PutObject header-casing diagnostic ==========")
    logger.info("namespace: \(namespace)  bucket: \(bucketName)")

    let objectName = "linux-header-casing-test.txt"
    let body = Data("Hello from \(platform)".utf8)

    // Mirror ObjectStorageClient.putObject request construction.
    let api = ObjectStorageAPI.putObject(
      namespaceName: namespace,
      bucketName: bucketName,
      objectName: objectName
    )
    var req = try buildRequest(api: api, endpoint: endpoint)
    req.httpBody = body
    try signer.sign(&req)

    let (data, response) = try await URLSession.shared.data(for: req)
    let http = try #require(response as? HTTPURLResponse)
    logger.info("HTTP status: \(http.statusCode)  (200 == server stored the object)")
    if http.statusCode != 200 {
      logger.info("response body: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
    }

    // Build the OLD case-sensitive dictionary to show how the previous code failed.
    let dict = http.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
      if let k = pair.key as? String, let v = pair.value as? String { acc[k] = v }
    }

    logger.info("--- allHeaderFields keys, verbatim (\(dict.count)) ---")
    for k in dict.keys.sorted() { logger.info("    '\(k)' = \(dict[k]!)") }

    let sdkKeys = ["etag", "last-modified", "opc-content-md5", "opc-request-id", "version-id"]
    logger.info("--- OLD case-sensitive dict lookups (what the bug did) ---")
    for key in sdkKeys {
      logger.info("    dict[\"\(key)\"] -> \(dict[key] != nil ? "FOUND" : "nil  <-- guard failed here")")
    }

    logger.info("--- NEW value(forHTTPHeaderField:) lookups (the fix) ---")
    for key in sdkKeys {
      let v = http.value(forHTTPHeaderField: key)
      logger.info("    value(\"\(key)\") -> \(v != nil ? "FOUND" : "nil")")
    }
    logger.info("======================================================================\n")

    #expect(http.statusCode == 200, "The upload itself must succeed (server returns 200)")
  }

  // MARK: - 2. Reproduce/verify through the public API
  //
  // Before the fix this threw on Linux; after the fix it must return normally
  // on both platforms even though the object was uploaded.
  @Test("client.putObject returns cleanly after a successful upload")
  func reproduceUserBug() async throws {
    let (signer, _, region) = try makeSignerAndEndpoint()
    let client = try ObjectStorageClient(region: region, signer: signer)
    let namespace = try await client.getNamespace()

    do {
      try await client.putObject(
        namespaceName: namespace,
        bucketName: bucketName,
        objectName: "linux-putobject-repro.txt",
        putObjectBody: Data("repro".utf8)
      )
      logger.info("=== [\(platform)] putObject returned normally (no error) ===")
    }
    catch {
      logger.info("=== [\(platform)] putObject THREW after a successful upload ===")
      logger.info("    error: \(error)")
      logger.info("    localizedDescription: \(error.localizedDescription)")
      Issue.record("putObject threw despite the object being uploaded: \(error.localizedDescription)")
    }
  }
}
