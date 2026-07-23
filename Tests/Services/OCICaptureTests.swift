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
// Fixture CAPTURE tool. This is the "live" half: run it once, pointed at a real
// OCI endpoint, to record a response into a JSON fixture that hermetic tests then
// replay. It self-skips unless configured, so it never runs in normal CI.
//
// Capture against real OCI:
//   OCI_CAPTURE_BASE_URL=https://objectstorage.us-ashburn-1.oraclecloud.com \
//   OCI_CONFIG_FILE=$HOME/.oci/config OCI_PROFILE=DEFAULT \
//   OCI_FIXTURE_OUT=/tmp/fixtures \
//   swift test --filter OCICaptureTests
//
// (With a real config the request is signed by APIKeySigner so OCI accepts it;
// without one it falls back to a stub signer for hitting a local/mock endpoint.)
//

import Foundation
import OCIKit
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private struct CaptureStubSigner: Signer {
  func sign(_ req: inout URLRequest) throws {
    req.setValue(#"Signature version="1""#, forHTTPHeaderField: "Authorization")
  }
}

struct OCICaptureTests {
  @Test("captures getNamespace from a live endpoint into a replayable fixture")
  func captureGetNamespace() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let base = env["OCI_CAPTURE_BASE_URL"], let out = env["OCI_FIXTURE_OUT"] else {
      logger.info("OCICaptureTests skipped — set OCI_CAPTURE_BASE_URL and OCI_FIXTURE_OUT to record.")
      return
    }

    // Real OCI needs a real signature; a local mock endpoint does not.
    let signer: Signer
    if let configFile = env["OCI_CONFIG_FILE"] {
      signer = try APIKeySigner(configFilePath: configFile, configName: env["OCI_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "DEFAULT")
    }
    else {
      signer = CaptureStubSigner()
    }

    let client = try ObjectStorageClient(
      endpoint: base,
      signer: signer,
      httpClient: .recording(into: URL(filePath: out))
    )

    let namespace = try await client.getNamespace()
    logger.info("OCICaptureTests: captured getNamespace -> \"\(namespace)\"; fixture written under \(out)")
  }

  /// Captures a real ranged `getObject` — the fix for issue #96. The `range`
  /// header makes OCI answer 206 Partial Content with only the requested window,
  /// so the committed fixture proves both the request the SDK builds and that the
  /// client accepts a 206 body. Requires a preexisting object; create one first,
  /// e.g. `oci os object put --bucket-name <b> --name <o> --file <f>`.
  @Test("captures a ranged getObject (206 Partial Content) from a live endpoint into a fixture")
  func captureGetObjectRange() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let base = env["OCI_CAPTURE_BASE_URL"], let out = env["OCI_FIXTURE_OUT"],
      let namespace = env["OCI_NAMESPACE"], let bucket = env["OCI_BUCKET"], let object = env["OCI_OBJECT"]
    else {
      logger.info(
        "captureGetObjectRange skipped — set OCI_CAPTURE_BASE_URL, OCI_FIXTURE_OUT, OCI_NAMESPACE, OCI_BUCKET, OCI_OBJECT."
      )
      return
    }
    let range = env["OCI_RANGE"] ?? "bytes=0-15"

    // Real OCI needs a real signature; a local mock endpoint does not.
    let signer: Signer
    if let configFile = env["OCI_CONFIG_FILE"] {
      signer = try APIKeySigner(configFilePath: configFile, configName: env["OCI_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "DEFAULT")
    }
    else {
      signer = CaptureStubSigner()
    }

    let client = try ObjectStorageClient(
      endpoint: base,
      signer: signer,
      httpClient: .recording(into: URL(filePath: out))
    )

    let data = try await client.getObject(
      namespaceName: namespace,
      bucketName: bucket,
      objectName: object,
      range: range
    )
    logger.info(
      "OCICaptureTests: captured ranged getObject (\(range)) -> \(data.count) bytes; fixture written under \(out)"
    )
  }

  // MARK: - Secrets Retrieval API captures

  /// Builds a live, recording `SecretsClient` for the configured profile, or
  /// returns `nil` (with a logged reason) when the required env vars are absent
  /// so the capture self-skips in CI.
  private func makeRecordingSecretsClient(_ env: [String: String]) throws -> (client: SecretsClient, out: String)? {
    guard let out = env["OCI_FIXTURE_OUT"], let configFile = env["OCI_CONFIG_FILE"] else {
      logger.info("Secrets capture skipped — set OCI_FIXTURE_OUT and OCI_CONFIG_FILE to record.")
      return nil
    }
    let profile = env["OCI_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "DEFAULT"
    let signer = try APIKeySigner(configFilePath: configFile, configName: profile)
    let region = Region.from(regionId: try extractUserRegion(from: configFile, profile: profile) ?? "") ?? .iad
    let client = try SecretsClient(
      region: region,
      signer: signer,
      httpClient: .recording(into: URL(filePath: out))
    )
    return (client, out)
  }

  @Test("captures getSecretBundle from live OCI into a fixture")
  func captureGetSecretBundle() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let secretId = env["OCI_SECRET_ID"] else {
      logger.info("captureGetSecretBundle skipped — set OCI_SECRET_ID.")
      return
    }
    guard let (client, out) = try makeRecordingSecretsClient(env) else { return }

    let bundle = try await client.getSecretBundle(secretId: secretId)
    logger.info("OCICaptureTests: captured getSecretBundle v\(bundle.versionNumber); fixture written under \(out)")
  }

  @Test("captures listSecretBundleVersions from live OCI into a fixture")
  func captureListSecretBundleVersions() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let secretId = env["OCI_SECRET_ID"] else {
      logger.info("captureListSecretBundleVersions skipped — set OCI_SECRET_ID.")
      return
    }
    guard let (client, out) = try makeRecordingSecretsClient(env) else { return }

    let versions = try await client.listSecretBundleVersions(secretId: secretId)
    logger.info("OCICaptureTests: captured listSecretBundleVersions -> \(versions.count) versions; fixture written under \(out)")
  }

  @Test("captures getSecretBundleByName from live OCI into a fixture")
  func captureGetSecretBundleByName() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let secretName = env["OCI_SECRET_NAME"], let vaultId = env["OCI_VAULT_ID"] else {
      logger.info("captureGetSecretBundleByName skipped — set OCI_SECRET_NAME and OCI_VAULT_ID.")
      return
    }
    guard let (client, out) = try makeRecordingSecretsClient(env) else { return }

    let bundle = try await client.getSecretBundleByName(secretName: secretName, vaultId: vaultId)
    logger.info("OCICaptureTests: captured getSecretBundleByName v\(bundle.versionNumber); fixture written under \(out)")
  }

  /// Captures a real 404 error body/headers. The recording transport writes the
  /// fixture before the client parses the non-2xx status and throws, so the
  /// thrown `SecretsError` is expected and ignored here.
  @Test("captures a real 404 from getSecretBundle into a fixture")
  func captureGetSecretBundleNotFound() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let badSecretId = env["OCI_BAD_SECRET_ID"] else {
      logger.info("captureGetSecretBundleNotFound skipped — set OCI_BAD_SECRET_ID.")
      return
    }
    guard let (client, out) = try makeRecordingSecretsClient(env) else { return }

    _ = try? await client.getSecretBundle(secretId: badSecretId)
    logger.info("OCICaptureTests: captured getSecretBundle 404 fixture under \(out)")
  }

  // MARK: - Logging Ingestion captures

  /// Builds a live, recording `LoggingIngestClient` for the configured profile, or
  /// returns `nil` (with a logged reason) when the required env vars are absent
  /// so the capture self-skips in CI.
  private func makeRecordingLoggingIngestClient(
    _ env: [String: String]
  ) throws -> (client: LoggingIngestClient, out: String)? {
    guard let out = env["OCI_FIXTURE_OUT"], let configFile = env["OCI_CONFIG_FILE"] else {
      logger.info("Logging Ingestion capture skipped — set OCI_FIXTURE_OUT and OCI_CONFIG_FILE to record.")
      return nil
    }
    let profile = env["OCI_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "DEFAULT"
    let signer = try APIKeySigner(configFilePath: configFile, configName: profile)
    let region = Region.from(regionId: try extractUserRegion(from: configFile, profile: profile) ?? "") ?? .iad
    let client = try LoggingIngestClient(
      region: region,
      signer: signer,
      httpClient: .recording(into: URL(filePath: out))
    )
    return (client, out)
  }

  @Test("captures putLogs from live OCI into a fixture")
  func captureLoggingIngestionPutLogs() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let logId = env["OCI_LOG_ID"] else {
      logger.info("captureLoggingIngestionPutLogs skipped — set OCI_LOG_ID.")
      return
    }
    guard let (client, out) = try makeRecordingLoggingIngestClient(env) else { return }

    let details = PutLogsDetails(
      logEntryBatches: [
        LogEntryBatch(
          entries: [LogEntry(data: "oci-swift-sdk capture probe")],
          source: "oci-swift-sdk-capture",
          type: "com.oraclecloud.oci-swift-sdk.capture",
          defaultlogentrytime: Date()
        )
      ]
    )
    try await client.putLogs(logId: logId, details: details)
    logger.info("OCICaptureTests: captured putLogs success fixture under \(out)")
  }

  /// Captures a real 404 error body/headers from a nonexistent log OCID. The
  /// recording transport writes the fixture before the client parses the
  /// non-2xx status and throws, so the thrown `LoggingIngestionError` is
  /// expected and ignored here.
  @Test("captures a real 404 from putLogs into a fixture")
  func captureLoggingIngestionPutLogsNotFound() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let badLogId = env["OCI_BAD_LOG_ID"] else {
      logger.info("captureLoggingIngestionPutLogsNotFound skipped — set OCI_BAD_LOG_ID.")
      return
    }
    guard let (client, out) = try makeRecordingLoggingIngestClient(env) else { return }

    let details = PutLogsDetails(
      logEntryBatches: [
        LogEntryBatch(
          entries: [LogEntry(data: "oci-swift-sdk capture probe (expected to fail)")],
          source: "oci-swift-sdk-capture",
          type: "com.oraclecloud.oci-swift-sdk.capture",
          defaultlogentrytime: Date()
        )
      ]
    )
    _ = try? await client.putLogs(logId: badLogId, details: details)
    logger.info("OCICaptureTests: captured putLogs 404 fixture under \(out)")
  }
}
