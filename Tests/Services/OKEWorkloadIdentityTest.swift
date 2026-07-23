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

import Crypto
import Foundation
import Logging
import Synchronization
import Testing
import _CryptoExtras

@testable import OCIKit

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - Helpers

/// Base64url-encodes without padding (JWT segment encoding).
private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacing("+", with: "-")
    .replacing("/", with: "_")
    .replacing("=", with: "")
}

/// Builds an unsigned-but-well-formed JWT string whose payload carries the given
/// claims. The signer never verifies the signature, so the segment is a placeholder.
private func makeJWT(claims: [String: Any]) -> String {
  let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
  let payload = try! JSONSerialization.data(withJSONObject: claims)
  return "\(base64URL(header)).\(base64URL(payload)).c2ln"
}

/// A freshly generated RSA private key and its PEM.
private func makeKeyPair() throws -> (key: _RSA.Signing.PrivateKey, pem: String) {
  let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
  return (key, key.pemRepresentation)
}

/// Encodes an RPST into the exact proxymux wire format: base64 of
/// `{"token":"ST$<rpst>"}`, returned as the HTTP response body bytes.
private func proxymuxResponseBody(rpst: String) -> Data {
  let json = "{\"token\":\"ST$\(rpst)\"}"
  let base64 = Data(json.utf8).base64EncodedString()
  return Data(base64.utf8)
}

private func httpResponse(url: URL, status: Int) -> HTTPURLResponse {
  HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

/// Records every request passed to the injected transport, so tests can assert
/// what was sent and how many exchanges happened. `Sendable` via its `Mutex`.
private final class Recorder: Sendable {
  private let box = Mutex<[URLRequest]>([])
  func record(_ req: URLRequest) { box.withLock { $0.append(req) } }
  var all: [URLRequest] { box.withLock { $0 } }
  var count: Int { box.withLock { $0.count } }
  var last: URLRequest? { box.withLock { $0.last } }
}

/// Builds a transport that records requests and replies with `status` + the
/// base64-wrapped RPST envelope.
private func recordingTransport(
  rpst: String,
  status: Int = 200,
  recorder: Recorder
) -> HTTPClient {
  HTTPClient { req in
    recorder.record(req)
    let url = req.url ?? URL(string: "https://proxymux")!
    let body = status == 200 ? proxymuxResponseBody(rpst: rpst) : Data()
    return (body, httpResponse(url: url, status: status))
  }
}

/// A never-called transport — for tests that must fail before any network I/O.
/// Builds a concrete `HTTPURLResponse` via the designated initializer (the
/// parameterless `HTTPURLResponse()` does not exist in `FoundationNetworking`).
private let unusedTransport = HTTPClient { _ in
  Issue.record("transport should not be called")
  return (Data(), httpResponse(url: URL(string: "https://unused")!, status: 500))
}

private let futureExp = Int(Date().timeIntervalSince1970) + 3600
private func validSAToken() -> String { makeJWT(claims: ["exp": futureExp]) }

/// Directly constructs a signer with an in-memory SA token (no file I/O), for
/// exercising the exchange + signing path hermetically.
private func makeSigner(
  saToken: String,
  transport: HTTPClient,
  region: String? = "us-phoenix-1"
) -> OKEWorkloadIdentitySigner {
  OKEWorkloadIdentitySigner(
    proxymuxEndpoint: URL(string: "https://10.0.0.1:12250/resourcePrincipalSessionTokens")!,
    saTokenSource: .value(saToken),
    caCertPath: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
    region: region,
    transport: transport,
    logger: Logger(label: "test")
  )
}

// MARK: - Environment parsing

struct OKEWorkloadIdentityEnvironmentTests {
  @Test("Missing KUBERNETES_SERVICE_HOST throws serviceHostNotDefined")
  func missingHost() {
    #expect(throws: OKEWorkloadIdentityError.serviceHostNotDefined) {
      _ = try OKEWorkloadIdentitySigner.make(transport: unusedTransport, environment: [:])
    }
  }

  @Test("A present service host composes the proxymux endpoint and default CA path")
  func composesEndpointAndDefaults() throws {
    let signer = try OKEWorkloadIdentitySigner.make(
      transport: unusedTransport,
      environment: [
        "KUBERNETES_SERVICE_HOST": "10.0.0.1"
      ]
    )
    #expect(
      signer.proxymuxEndpoint.absoluteString
        == "https://10.0.0.1:12250/resourcePrincipalSessionTokens"
    )
    #expect(signer.caCertPath == "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
    #expect(signer.region == nil)
  }

  @Test("The CA cert path and region are read from the environment when present")
  func readsCAAndRegion() throws {
    let signer = try OKEWorkloadIdentitySigner.make(
      transport: unusedTransport,
      environment: [
        "KUBERNETES_SERVICE_HOST": "svc.host",
        "OCI_KUBERNETES_SERVICE_ACCOUNT_CERT_PATH": "/custom/ca.crt",
        "OCI_RESOURCE_PRINCIPAL_REGION": "eu-frankfurt-1",
      ]
    )
    #expect(signer.caCertPath == "/custom/ca.crt")
    #expect(signer.region == "eu-frankfurt-1")
  }

  @Test("serviceAccountCertPath resolves the override, else the default")
  func resolvesCACertPath() {
    #expect(
      OKEWorkloadIdentitySigner.serviceAccountCertPath(fromEnvironment: [:])
        == "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    )
    #expect(
      OKEWorkloadIdentitySigner.serviceAccountCertPath(fromEnvironment: [
        "OCI_KUBERNETES_SERVICE_ACCOUNT_CERT_PATH": "/custom/ca.crt"
      ]) == "/custom/ca.crt"
    )
  }
}

// MARK: - podKey serialization

struct OKEWorkloadIdentityPodKeyTests {
  @Test("sanitizedPodKey strips PEM header/footer lines and newlines into one line")
  func stripsHeadersAndNewlines() throws {
    let (key, _) = try makeKeyPair()
    let podKey = OKEWorkloadIdentitySigner.sanitizedPodKey(fromSPKIPEM: key.publicKey.pemRepresentation)
    #expect(!podKey.contains("PUBLIC KEY"))
    #expect(!podKey.contains("-----"))
    #expect(!podKey.contains("\n"))
    #expect(!podKey.contains("\r"))
    #expect(!podKey.isEmpty)
    // The remaining payload must be valid base64 (the SPKI DER).
    #expect(Data(base64Encoded: podKey) != nil)
  }
}

// MARK: - Token-exchange request building

struct OKEWorkloadIdentityRequestTests {
  @Test("buildTokenExchangeRequest sets the method, bearer auth, headers, and podKey body")
  func buildsRequest() throws {
    let endpoint = URL(string: "https://10.0.0.1:12250/resourcePrincipalSessionTokens")!
    let req = OKEWorkloadIdentitySigner.buildTokenExchangeRequest(
      endpoint: endpoint,
      podKey: "POD_KEY_BASE64",
      saToken: "sa.jwt.token",
      opcRequestId: "aaa/bbb/ccc"
    )
    #expect(req.httpMethod == "POST")
    #expect(req.url == endpoint)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sa.jwt.token")
    #expect(req.value(forHTTPHeaderField: "Content-type") == "application/json")
    #expect(req.value(forHTTPHeaderField: "opc-request-id") == "aaa/bbb/ccc")

    let body = try #require(req.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["podKey"] as? String == "POD_KEY_BASE64")
    #expect(json.count == 1)
  }

  @Test("generateOpcRequestId returns three 32-char hex segments joined by '/'")
  func opcRequestIdShape() {
    let id = OKEWorkloadIdentitySigner.generateOpcRequestId()
    let segments = id.split(separator: "/")
    #expect(segments.count == 3)
    for segment in segments {
      #expect(segment.count == 32)
      #expect(segment.allSatisfy { $0.isHexDigit })
    }
  }
}

// MARK: - Response decoding

struct OKEWorkloadIdentityResponseTests {
  @Test("decodeRPST unwraps base64(JSON) and strips the ST$ prefix")
  func decodesAndStripsPrefix() throws {
    let rpst = makeJWT(claims: ["exp": futureExp])
    let body = proxymuxResponseBody(rpst: rpst)
    #expect(try OKEWorkloadIdentitySigner.decodeRPST(fromResponseBody: body) == rpst)
  }

  @Test("decodeRPST tolerates base64 with embedded newlines (lenient, like the other SDKs)")
  func decodesBase64WithNewlines() throws {
    let rpst = makeJWT(claims: ["exp": futureExp])
    var base64 = Data("{\"token\":\"ST$\(rpst)\"}".utf8).base64EncodedString()
    base64.insert("\n", at: base64.index(base64.startIndex, offsetBy: base64.count / 2))
    #expect(try OKEWorkloadIdentitySigner.decodeRPST(fromResponseBody: Data(base64.utf8)) == rpst)
  }

  @Test("decodeRPST also accepts a raw (non-base64) JSON body")
  func decodesRawJSON() throws {
    let rpst = makeJWT(claims: ["exp": futureExp])
    let body = Data("{\"token\":\"ST$\(rpst)\"}".utf8)
    #expect(try OKEWorkloadIdentitySigner.decodeRPST(fromResponseBody: body) == rpst)
  }

  @Test("decodeRPST throws for a body that is not base64")
  func rejectsNonBase64() {
    let body = Data("this is not base64!!!".utf8)
    #expect(throws: OKEWorkloadIdentityError.self) {
      _ = try OKEWorkloadIdentitySigner.decodeRPST(fromResponseBody: body)
    }
  }

  @Test("decodeRPST throws when the decoded JSON has no token field")
  func rejectsMissingToken() {
    let json = "{\"nottoken\":\"x\"}"
    let body = Data(Data(json.utf8).base64EncodedString().utf8)
    #expect(throws: OKEWorkloadIdentityError.self) {
      _ = try OKEWorkloadIdentitySigner.decodeRPST(fromResponseBody: body)
    }
  }
}

// MARK: - JWT parsing

struct OKEWorkloadIdentityTokenTests {
  @Test("issuedAndExpiry reads the iat and exp claims")
  func readsClaims() {
    let jwt = makeJWT(claims: ["iat": 1000, "exp": 5000])
    let claims = OKEWorkloadIdentityToken.issuedAndExpiry(of: jwt)
    #expect(claims.issuedAt == 1000)
    #expect(claims.expiry == 5000)
  }

  @Test("issuedAndExpiry returns nils for a malformed token")
  func malformedIsNil() {
    let claims = OKEWorkloadIdentityToken.issuedAndExpiry(of: "not-a-jwt")
    #expect(claims.issuedAt == nil)
    #expect(claims.expiry == nil)
  }

  @Test("isUnexpired is true only for a future exp claim")
  func expiryCheck() {
    let now = Int(Date().timeIntervalSince1970)
    #expect(OKEWorkloadIdentityToken.isUnexpired(makeJWT(claims: ["exp": now + 60]), now: now))
    #expect(!OKEWorkloadIdentityToken.isUnexpired(makeJWT(claims: ["exp": now - 60]), now: now))
    // No exp claim -> not usable.
    #expect(!OKEWorkloadIdentityToken.isUnexpired(makeJWT(claims: ["sub": "x"]), now: now))
  }
}

// MARK: - Token exchange (hermetic, injected transport)

struct OKEWorkloadIdentityExchangeTests {
  @Test("refresh() exchanges the pod key and signs the exchange request with the SA bearer token")
  func exchangeSendsExpectedRequest() async throws {
    let rpst = makeJWT(claims: ["iat": Int(Date().timeIntervalSince1970), "exp": futureExp])
    let recorder = Recorder()
    let sa = validSAToken()
    let signer = makeSigner(saToken: sa, transport: recordingTransport(rpst: rpst, recorder: recorder))

    try await signer.refresh()

    #expect(recorder.count == 1)
    let sent = try #require(recorder.last)
    #expect(sent.httpMethod == "POST")
    #expect(sent.url?.absoluteString == "https://10.0.0.1:12250/resourcePrincipalSessionTokens")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer \(sa)")
    #expect(sent.value(forHTTPHeaderField: "opc-request-id") != nil)
    let body = try #require(sent.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let podKey = try #require(json["podKey"] as? String)
    #expect(!podKey.contains("PUBLIC KEY"))
  }

  @Test("After a successful exchange, sign() uses an ST$<rpst> keyId")
  func signsWithExchangedToken() async throws {
    let rpst = makeJWT(claims: ["iat": Int(Date().timeIntervalSince1970), "exp": futureExp])
    let recorder = Recorder()
    let signer = makeSigner(saToken: validSAToken(), transport: recordingTransport(rpst: rpst, recorder: recorder))
    try await signer.refresh()

    var req = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
    req.httpMethod = "GET"
    try await signer.sign(&req)

    let auth = req.value(forHTTPHeaderField: "Authorization")
    #expect(auth?.contains("keyId=\"ST$\(rpst)\"") == true)
    #expect(auth?.contains("algorithm=\"rsa-sha256\"") == true)
    #expect(auth?.contains("x-content-sha256") == false)  // GET has no signed body
  }

  @Test("sign() with no cached token self-primes via one exchange, then signs")
  func signSelfPrimes() async throws {
    let rpst = makeJWT(claims: ["iat": Int(Date().timeIntervalSince1970), "exp": futureExp])
    let recorder = Recorder()
    let signer = makeSigner(saToken: validSAToken(), transport: recordingTransport(rpst: rpst, recorder: recorder))

    var req = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
    req.httpMethod = "GET"
    // No explicit refresh() first: sign() must exchange inline before signing.
    try await signer.sign(&req)

    #expect(recorder.count == 1)
    let auth = req.value(forHTTPHeaderField: "Authorization")
    #expect(auth?.contains("keyId=\"ST$\(rpst)\"") == true)
  }

  @Test("A 403 from the proxymux surfaces as tokenExchangeFailed(403)")
  func handles403() async {
    let recorder = Recorder()
    let signer = makeSigner(
      saToken: validSAToken(),
      transport: recordingTransport(rpst: "unused", status: 403, recorder: recorder)
    )
    do {
      try await signer.refresh()
      Issue.record("expected a 403 token-exchange failure")
    }
    catch let error as OKEWorkloadIdentityError {
      #expect(error == .tokenExchangeFailed(status: 403, message: ""))
    }
    catch {
      Issue.record("unexpected error: \(error)")
    }
  }

  @Test("An expired SA token fails before any network call")
  func expiredSATokenFailsFast() async {
    let now = Int(Date().timeIntervalSince1970)
    let expired = makeJWT(claims: ["exp": now - 60])
    let signer = makeSigner(saToken: expired, transport: unusedTransport)
    do {
      try await signer.refresh()
      Issue.record("expected serviceAccountTokenExpired")
    }
    catch let error as OKEWorkloadIdentityError {
      #expect(error == .serviceAccountTokenExpired)
    }
    catch {
      Issue.record("unexpected error: \(error)")
    }
  }
}

// MARK: - Half-life refresh policy

struct OKEWorkloadIdentityRefreshPolicyTests {
  @Test("refreshIfNeeded does not re-exchange while the token is within its half-life")
  func freshTokenSkipsRefresh() async throws {
    let now = Int(Date().timeIntervalSince1970)
    let rpst = makeJWT(claims: ["iat": now, "exp": now + 3600])
    let recorder = Recorder()
    let signer = makeSigner(saToken: validSAToken(), transport: recordingTransport(rpst: rpst, recorder: recorder))

    try await signer.refresh()  // exchange #1
    try await signer.refreshIfNeeded()  // still fresh -> no exchange

    #expect(recorder.count == 1)
  }

  @Test("refreshIfNeeded re-exchanges once the token is past its half-life")
  func staleTokenTriggersRefresh() async throws {
    let now = Int(Date().timeIntervalSince1970)
    // iat far in the past, exp just ahead -> already past the midpoint.
    let rpst = makeJWT(claims: ["iat": now - 3600, "exp": now + 30])
    let recorder = Recorder()
    let signer = makeSigner(saToken: validSAToken(), transport: recordingTransport(rpst: rpst, recorder: recorder))

    try await signer.refresh()  // exchange #1
    try await signer.refreshIfNeeded()  // past half-life -> exchange #2

    #expect(recorder.count == 2)
  }
}
