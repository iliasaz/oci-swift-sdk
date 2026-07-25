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
// Hermetic tests for ObjectStorageClient — no ~/.oci/config, no credentials, no
// network. They inject a fake HTTPClient that records the outgoing request and
// returns canned responses, so request-building and response-parsing are tested
// deterministically and run anywhere (CI, fork PRs, offline).
//

import Foundation
import OCIKit
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// A no-op signer. These tests exercise ObjectStorage's request/response logic,
// not signature correctness (which is covered separately with a fixed key), so
// no private key or config file is needed. It stamps an Authorization header so
// tests can confirm the signer ran.
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

// Builds a client whose transport records the request and returns a canned response.
private func makeClient(
  status: Int,
  body: Data,
  responseHeaders: [String: String] = [:],
  recorder: RequestRecorder
) throws -> ObjectStorageClient {
  let http = HTTPClient { request in
    await recorder.record(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: responseHeaders
    )!
    return (body, response)
  }
  return try ObjectStorageClient(region: .iad, signer: StubSigner(), httpClient: http)
}

struct ObjectStorageHermeticTests {

  // Response parsing + request shape, both from a canned 200.
  @Test("getNamespace: builds GET /n and parses the quoted-string body")
  func getNamespace() async throws {
    let recorder = RequestRecorder()
    let client = try makeClient(status: 200, body: Data(#""examplenamespace""#.utf8), recorder: recorder)

    let namespace = try await client.getNamespace()

    #expect(namespace == "examplenamespace")  // quotes trimmed by the client
    let req = await recorder.last
    #expect(req?.httpMethod == "GET")
    #expect(req?.url?.host == "objectstorage.us-ashburn-1.oraclecloud.com")
    #expect(req?.url?.path == "/n")
    #expect(req?.value(forHTTPHeaderField: "Authorization") != nil)  // signer ran
  }

  // Query-parameter construction + JSON array decoding + RFC3339 parsing.
  @Test("listBuckets: sends compartmentId/limit/fields query and decodes the array")
  func listBuckets() async throws {
    let recorder = RequestRecorder()
    let json = """
      [
        {"compartmentId":"ocid1.compartment.oc1..c1","createdBy":"ocid1.user.oc1..u1","etag":"e1","name":"alpha","namespace":"examplenamespace","timeCreated":"2026-07-14T12:00:00.000Z"},
        {"compartmentId":"ocid1.compartment.oc1..c1","createdBy":"ocid1.user.oc1..u1","etag":"e2","name":"beta","namespace":"examplenamespace","timeCreated":"2026-07-14T12:05:00.000Z"}
      ]
      """
    let client = try makeClient(status: 200, body: Data(json.utf8), recorder: recorder)

    let buckets = try await client.listBuckets(
      namespaceName: "examplenamespace",
      compartmentId: "ocid1.compartment.oc1..c1",
      limit: 10
    )

    #expect(buckets.map(\.name) == ["alpha", "beta"])
    #expect(buckets.first?.timeCreated != nil)  // RFC3339 -> Date parsing exercised

    let req = await recorder.last
    #expect(req?.httpMethod == "GET")
    #expect(req?.url?.path == "/n/examplenamespace/b")
    let items = req?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
    #expect(query["compartmentId"] == "ocid1.compartment.oc1..c1")
    #expect(query["limit"] == "10")
    #expect(query["fields"] == "tags")  // default
  }

  // Write-path request shape (method, path, body). putObject also parses response
  // headers case-sensitively; that is exactly the Linux header-casing behavior
  // being addressed separately, so we ignore the call's outcome and assert only
  // the request the SDK emitted (the recorder captured it before any parsing).
  @Test("putObject: builds a PUT to /o/<object> with the payload as the body")
  func putObjectRequestShape() async throws {
    let recorder = RequestRecorder()
    let client = try makeClient(status: 200, body: Data(), recorder: recorder)
    let payload = Data("Hello, OCI!".utf8)

    _ = try? await client.putObject(
      namespaceName: "examplenamespace",
      bucketName: "test_bucket_by_sdk",
      objectName: "greeting.txt",
      putObjectBody: payload
    )

    let req = await recorder.last
    #expect(req?.httpMethod == "PUT")
    #expect(req?.url?.path == "/n/examplenamespace/b/test_bucket_by_sdk/o/greeting.txt")
    #expect(req?.httpBody == payload)
  }

  // Error path: a non-2xx with an OCI error body maps to unexpectedStatusCode.
  // Trivial to exercise hermetically; nearly impossible to provoke reliably live.
  @Test("getNamespace: non-2xx maps to ObjectStorageError with the server message")
  func errorMapping() async throws {
    let recorder = RequestRecorder()
    let errorJSON = #"{"code":"NamespaceNotFound","message":"You do not have authorization"}"#
    let client = try makeClient(status: 404, body: Data(errorJSON.utf8), recorder: recorder)

    await #expect(throws: ObjectStorageError.self) {
      _ = try await client.getNamespace()
    }
  }

  // MARK: - Ranged GetObject (issue #96)

  // The core regression for #96: a ranged read must (a) put the byte window on the
  // wire as a `Range` header and (b) accept the 206 Partial Content the server
  // answers with. The old router bound `range` to `_` and emitted only
  // opc-client-request-id, and the client rejected any status != 200 — so a
  // ranged get silently over-fetched (200 + whole object) or threw on 206.
  @Test("getObject: emits the Range header and accepts a 206 partial response")
  func getObjectRangeHeader() async throws {
    let recorder = RequestRecorder()
    let partial = Data("0123".utf8)  // 4 bytes -> bytes=0-3
    let client = try makeClient(
      status: 206,
      body: partial,
      responseHeaders: ["Content-Range": "bytes 0-3/1024", "Content-Length": "4"],
      recorder: recorder
    )

    let data = try await client.getObject(
      namespaceName: "examplenamespace",
      bucketName: "test_bucket_by_sdk",
      objectName: "big.bin",
      range: "bytes=0-3"
    )

    #expect(data == partial)  // 206 accepted; only the requested window is returned
    let req = await recorder.last
    #expect(req?.httpMethod == "GET")
    #expect(req?.url?.path == "/n/examplenamespace/b/test_bucket_by_sdk/o/big.bin")
    #expect(req?.value(forHTTPHeaderField: "range") == "bytes=0-3")
  }

  // Regression guard the other way: an unranged read must NOT send a Range header
  // (else the server answers 206 for a full-object fetch).
  @Test("getObject: omits the Range header when no range is requested")
  func getObjectNoRangeHeader() async throws {
    let recorder = RequestRecorder()
    let client = try makeClient(status: 200, body: Data("full-object".utf8), recorder: recorder)

    _ = try await client.getObject(
      namespaceName: "examplenamespace",
      bucketName: "test_bucket_by_sdk",
      objectName: "big.bin"
    )

    let req = await recorder.last
    #expect(req?.value(forHTTPHeaderField: "range") == nil)
  }

  // The same router arm also dropped the SSE-C customer headers; they must reach
  // the wire so customer-supplied encryption keys are actually honored.
  @Test("getObject: emits the SSE-C customer headers when provided")
  func getObjectSSEHeaders() async throws {
    let recorder = RequestRecorder()
    let client = try makeClient(status: 200, body: Data("cipher".utf8), recorder: recorder)

    _ = try await client.getObject(
      namespaceName: "examplenamespace",
      bucketName: "test_bucket_by_sdk",
      objectName: "enc.bin",
      opcSseCustomerAlgorithm: "AES256",
      opcSseCustomerKey: "dGVzdC1rZXk=",
      opcSseCustomerKeySha256: "dGVzdC1zaGE="
    )

    let req = await recorder.last
    #expect(req?.value(forHTTPHeaderField: "opc-sse-customer-algorithm") == "AES256")
    #expect(req?.value(forHTTPHeaderField: "opc-sse-customer-key") == "dGVzdC1rZXk=")
    #expect(req?.value(forHTTPHeaderField: "opc-sse-customer-key-sha256") == "dGVzdC1zaGE=")
  }

  // The PAR variant shares the same buggy router arm (getObjectWithPAR) and the
  // same 200-only status check, so it needs its own coverage.
  @Test("getObject(parURL:): emits the Range header and accepts a 206 partial response")
  func getObjectPARRangeHeader() async throws {
    let recorder = RequestRecorder()
    let partial = Data("ab".utf8)
    let client = try makeClient(
      status: 206,
      body: partial,
      responseHeaders: ["Content-Range": "bytes 0-1/100", "Content-Length": "2"],
      recorder: recorder
    )
    let par = URL(
      string:
        "https://examplenamespace.objectstorage.us-ashburn-1.oraclecloud.com/p/tokenEXAMPLE/n/examplenamespace/b/test_bucket_by_sdk/o/"
    )!

    let data = try await client.getObject(parURL: par, objectName: "big.bin", range: "bytes=0-1")

    #expect(data == partial)
    let req = await recorder.last
    #expect(req?.httpMethod == "GET")
    #expect(req?.value(forHTTPHeaderField: "range") == "bytes=0-1")
  }

  // headObject carried the same SSE-C parameters and dropped them the same way
  // (it has no range parameter). Assert only the request shape; the response
  // parsing is exercised elsewhere.
  @Test("headObject: emits the SSE-C customer headers when provided")
  func headObjectSSEHeaders() async throws {
    let recorder = RequestRecorder()
    let client = try makeClient(status: 200, body: Data(), recorder: recorder)

    _ = try? await client.headObject(
      namespaceName: "examplenamespace",
      bucketName: "test_bucket_by_sdk",
      objectName: "enc.bin",
      opcSseCustomerAlgorithm: "AES256",
      opcSseCustomerKey: "dGVzdC1rZXk=",
      opcSseCustomerKeySha256: "dGVzdC1zaGE="
    )

    let req = await recorder.last
    #expect(req?.httpMethod == "HEAD")
    #expect(req?.value(forHTTPHeaderField: "opc-sse-customer-algorithm") == "AES256")
    #expect(req?.value(forHTTPHeaderField: "opc-sse-customer-key") == "dGVzdC1rZXk=")
    #expect(req?.value(forHTTPHeaderField: "opc-sse-customer-key-sha256") == "dGVzdC1zaGE=")
  }
}
