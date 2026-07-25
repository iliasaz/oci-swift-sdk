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
// Hermetic tests for LoggingIngestClient — no ~/.oci/config, no credentials, no
// network. Two shapes are used, mirroring SecretsHermeticTests.swift:
//   • replay a committed fixture (captured once from real OCI against the
//     `ocikit-test-log` custom log, the configured OCI profile, region `us-phoenix-1`; see
//     BRIEF.md) and assert on the client's throw/no-throw behavior — locks
//     response handling for the 200-empty-body success path and the error path.
//   • inject a recording HTTPClient closure and assert on the request the
//     client built (method, path, host, headers, JSON body) — locks request
//     building.
// Both run anywhere (CI, fork PRs, offline).
//

import Foundation
import OCIKit
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// A no-op-ish signer. These tests exercise request building and response
// parsing, not signature correctness. It stamps an Authorization header so a
// request-shape test can confirm the signing path was reached.
private struct StubSigner: Signer {
  func sign(_ req: inout URLRequest) throws {
    req.setValue(#"Signature version="1""#, forHTTPHeaderField: "Authorization")
  }
}

// Sendable-safe capture of the last request the client handed to the transport.
private actor RequestRecorder {
  private(set) var last: URLRequest?
  func record(_ request: URLRequest) { last = request }
}

struct LoggingIngestionHermeticTests {
  // Well-formed placeholder OCID matching the sanitized fixtures.
  private static let logId = "ocid1.log.oc1.phx.EXAMPLE"

  // Fixtures live next to this test file; resolve via #filePath so no SwiftPM
  // resource bundling is needed (the source tree is present at test time).
  private func fixtureURL(_ name: String) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name)")
  }

  private func replayClient(_ fixture: String) throws -> LoggingIngestClient {
    let http = try HTTPClient.replaying(fromFile: fixtureURL(fixture))
    return try LoggingIngestClient(region: .phx, signer: StubSigner(), httpClient: http)
  }

  // Builds a client whose transport records the request and returns a canned response.
  private func recordingClient(
    status: Int = 200,
    body: Data = Data(),
    recorder: RequestRecorder
  ) throws -> LoggingIngestClient {
    let http = HTTPClient { request in
      await recorder.record(request)
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: [:]
      )!
      return (body, response)
    }
    return try LoggingIngestClient(region: .phx, signer: StubSigner(), httpClient: http)
  }

  private func sampleDetails(defaultlogentrytime: Date = Date()) -> PutLogsDetails {
    PutLogsDetails(
      logEntryBatches: [
        LogEntryBatch(
          entries: [LogEntry(data: "hello", id: "fixed-id")],
          source: "probe-host",
          type: "com.oraclecloud.probe",
          defaultlogentrytime: defaultlogentrytime
        )
      ]
    )
  }

  // MARK: - Response handling (replay captured responses)

  @Test("putLogs: a captured 200 with an empty body succeeds without throwing")
  func putLogsSucceedsOnEmptyBody() async throws {
    let client = try replayClient("putLogs.json")

    // putLogs returns Void; reaching this line without a throw is the assertion.
    try await client.putLogs(logId: Self.logId, details: sampleDetails())
  }

  @Test("putLogs: a captured 404 maps to LoggingIngestionError.unexpectedStatusCode with the decoded message")
  func putLogsErrorMapping() async throws {
    let client = try replayClient("putLogs_404.json")

    await #expect(throws: LoggingIngestionError.self) {
      try await client.putLogs(logId: Self.logId, details: sampleDetails())
    }

    do {
      try await client.putLogs(logId: Self.logId, details: sampleDetails())
      Issue.record("expected putLogs to throw for the captured 404 fixture")
    }
    catch let error as LoggingIngestionError {
      guard case .unexpectedStatusCode(let code, let message) = error else {
        Issue.record("expected .unexpectedStatusCode(_:_:), got \(error)")
        return
      }
      #expect(code == 404)
      #expect(message.contains("logId not found"))
    }
  }

  // MARK: - Request shape (record the outgoing request)

  @Test("putLogs: builds POST /20200831/logs/<logId>/actions/push against the ingestion.logging host")
  func putLogsRequestShape() async throws {
    let recorder = RequestRecorder()
    let client = try recordingClient(recorder: recorder)

    try await client.putLogs(logId: Self.logId, details: sampleDetails())

    let req = await recorder.last
    #expect(req?.httpMethod == "POST")
    #expect(req?.url?.host == "ingestion.logging.us-phoenix-1.oci.oraclecloud.com")
    #expect(req?.url?.path == "/20200831/logs/\(Self.logId)/actions/push")
    #expect(req?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(req?.value(forHTTPHeaderField: "Authorization") != nil)  // signer ran
  }

  @Test("putLogs: sets opc-request-id and timestamp-opc-agent-processing headers when provided")
  func putLogsRequestHeaders() async throws {
    let recorder = RequestRecorder()
    let client = try recordingClient(recorder: recorder)

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let agentTime = iso.date(from: "2026-02-02T02:40:00.123Z")!

    try await client.putLogs(
      logId: Self.logId,
      details: sampleDetails(),
      opcRequestId: "req-abc",
      timestampOpcAgentProcessing: agentTime
    )

    let req = await recorder.last
    #expect(req?.value(forHTTPHeaderField: "opc-request-id") == "req-abc")
    #expect(req?.value(forHTTPHeaderField: "timestamp-opc-agent-processing") == "2026-02-02T02:40:00.123Z")
  }

  @Test("putLogs: omits opc-request-id and timestamp-opc-agent-processing headers when not provided")
  func putLogsRequestNoOptionalHeaders() async throws {
    let recorder = RequestRecorder()
    let client = try recordingClient(recorder: recorder)

    try await client.putLogs(logId: Self.logId, details: sampleDetails())

    let req = await recorder.last
    #expect(req?.value(forHTTPHeaderField: "opc-request-id") == nil)
    #expect(req?.value(forHTTPHeaderField: "timestamp-opc-agent-processing") == nil)
  }

  @Test("putLogs: sends the exact PutLogsDetails JSON as the request body")
  func putLogsRequestBody() async throws {
    let recorder = RequestRecorder()
    let client = try recordingClient(recorder: recorder)

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let entryTime = iso.date(from: "2026-02-02T02:40:00.123Z")!

    try await client.putLogs(logId: Self.logId, details: sampleDetails(defaultlogentrytime: entryTime))

    let req = await recorder.last
    let bodyData = try #require(req?.httpBody)
    let decoded = try JSONDecoder().decode(PutLogsDetails.self, from: bodyData)

    #expect(decoded.specversion == "1.0")
    #expect(decoded.logEntryBatches.count == 1)
    #expect(decoded.logEntryBatches.first?.source == "probe-host")
    #expect(decoded.logEntryBatches.first?.type == "com.oraclecloud.probe")
    #expect(decoded.logEntryBatches.first?.subject == nil)
    #expect(decoded.logEntryBatches.first?.defaultlogentrytime == "2026-02-02T02:40:00.123Z")
    #expect(decoded.logEntryBatches.first?.entries.first?.data == "hello")
    #expect(decoded.logEntryBatches.first?.entries.first?.id == "fixed-id")

    let json = String(data: bodyData, encoding: .utf8) ?? ""
    #expect(json.contains(#""specversion":"1.0""#))
    #expect(!json.contains("subject"))
  }
}
