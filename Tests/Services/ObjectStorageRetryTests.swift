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
// End-to-end proof that ObjectStorageClient honors its retryConfig — the core
// retry loop itself is covered in Tests/OCIKit/RetryTests.swift. Hermetic: a
// scripted transport plays a canned response per attempt; no credentials, no
// network.
//

import Foundation
import OCIKit
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private struct StubSigner: Signer {
  func sign(_ req: inout URLRequest) throws {
    req.setValue(#"Signature version="1""#, forHTTPHeaderField: "Authorization")
  }
}

/// Plays one `(status, body)` per attempt and counts the attempts.
private actor ScriptedResponses {
  private var script: [(status: Int, body: Data)]
  private(set) var attemptCount = 0

  init(_ script: [(status: Int, body: Data)]) { self.script = script }

  func next(for request: URLRequest) throws -> (Data, URLResponse) {
    attemptCount += 1
    guard !script.isEmpty else { throw URLError(.unsupportedURL) }
    let step = script.removeFirst()
    let response = HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: "HTTP/1.1", headerFields: [:])!
    return (step.body, response)
  }
}

private let errorBody = Data(#"{"code":"ServiceUnavailable","message":"please retry"}"#.utf8)
private let fastRetry = RetryConfig(maxAttempts: 3, baseDelay: 0.001, maxDelay: 0.005)

private func makeClient(script: ScriptedResponses, retryConfig: RetryConfig?) throws -> ObjectStorageClient {
  let http = HTTPClient { request in try await script.next(for: request) }
  return try ObjectStorageClient(region: .iad, signer: StubSigner(), retryConfig: retryConfig, httpClient: http)
}

struct ObjectStorageRetryTests {

  @Test("getNamespace succeeds after a 503 when the client has a retryConfig")
  func clientLevelRetry() async throws {
    let script = ScriptedResponses([
      (503, errorBody),
      (200, Data(#""examplenamespace""#.utf8)),
    ])
    let client = try makeClient(script: script, retryConfig: fastRetry)

    let namespace = try await client.getNamespace()

    #expect(namespace == "examplenamespace")
    #expect(await script.attemptCount == 2)
  }

  @Test("without a retryConfig a 503 fails on the first attempt (historical behavior)")
  func noConfigNoRetry() async throws {
    let script = ScriptedResponses([
      (503, errorBody),
      (200, Data(#""examplenamespace""#.utf8)),
    ])
    let client = try makeClient(script: script, retryConfig: nil)

    await #expect(throws: ObjectStorageError.self) {
      _ = try await client.getNamespace()
    }
    #expect(await script.attemptCount == 1)
  }

  @Test("per-operation retryConfig overrides the client-level configuration")
  func perOperationOverride() async throws {
    let script = ScriptedResponses([
      (503, errorBody),
      (204, Data()),
    ])
    // Client would retry three times, but the call disables retries.
    let client = try makeClient(script: script, retryConfig: fastRetry)

    await #expect(throws: ObjectStorageError.self) {
      try await client.deleteObject(
        namespaceName: "examplenamespace",
        bucketName: "test_bucket_by_sdk",
        objectName: "greeting.txt",
        retryConfig: RetryConfig(maxAttempts: 1)
      )
    }
    #expect(await script.attemptCount == 1)
  }

  @Test("PAR operations (unsigned) also retry through the client retryConfig")
  func parOperationRetries() async throws {
    let payload = Data("Hello, OCI!".utf8)
    let script = ScriptedResponses([
      (503, errorBody),
      (200, payload),
    ])
    let client = try makeClient(script: script, retryConfig: fastRetry)

    let data = try await client.getObject(
      parURL: URL(string: "https://objectstorage.us-ashburn-1.oraclecloud.com/p/token/n/ns/b/bucket/o/")!,
      objectName: "greeting.txt"
    )

    #expect(data == payload)
    #expect(await script.attemptCount == 2)
  }
}
