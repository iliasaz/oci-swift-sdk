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
import Testing
import _CryptoExtras

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@testable import OCIKit

// MARK: - Helpers

/// Base64url-encodes without padding (JWT segment encoding).
private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

/// Builds an unsigned-but-well-formed JWT string whose payload carries the given
/// claims. The Resource Principal signer never verifies the signature, so the
/// signature segment is a placeholder.
private func makeJWT(claims: [String: Any]) -> String {
  let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
  let payload = try! JSONSerialization.data(withJSONObject: claims)
  return "\(base64URL(header)).\(base64URL(payload)).c2ln"
}

/// A freshly generated RSA private key and its PEM, for building signers.
private func makeKeyPair() throws -> (key: _RSA.Signing.PrivateKey, pem: String) {
  let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
  return (key, key.pemRepresentation)
}

// MARK: - Source classification

struct ResourcePrincipalSourceTests {
  @Test("Absolute paths classify as files, everything else as literal values")
  func detectsPathVsValue() {
    #expect(ResourcePrincipalSource.detect("/etc/oci/rpst") == .file("/etc/oci/rpst"))
    #expect(ResourcePrincipalSource.detect("/var/run/secrets/token") == .file("/var/run/secrets/token"))
    // A JWT-looking literal is a value, not a path.
    #expect(ResourcePrincipalSource.detect("eyJhbGciOiJSUzI1NiJ9.e30.sig") == .value("eyJhbGciOiJSUzI1NiJ9.e30.sig"))
    #expect(ResourcePrincipalSource.detect("relative/path") == .value("relative/path"))
  }

  @Test("A literal value source resolves to itself")
  func resolvesLiteral() throws {
    let source = ResourcePrincipalSource.value("hello-token")
    #expect(try source.resolve() == "hello-token")
  }
}

// MARK: - RPST JWT parsing

struct ResourcePrincipalTokenTests {
  @Test("Reads the exp claim from a JWT payload")
  func readsExp() {
    let exp = 1_893_456_000  // 2030-01-01
    let jwt = makeJWT(claims: ["exp": exp, "res_tenant": "ocid1.tenancy.oc1..aaaa"])
    #expect(ResourcePrincipalToken.expiry(of: jwt) == exp)
  }

  @Test("Returns nil for a token without an exp claim")
  func missingExpIsNil() {
    let jwt = makeJWT(claims: ["res_tenant": "ocid1.tenancy.oc1..aaaa"])
    #expect(ResourcePrincipalToken.expiry(of: jwt) == nil)
  }

  @Test("Returns nil for a malformed token")
  func malformedIsNil() {
    #expect(ResourcePrincipalToken.expiry(of: "not-a-jwt") == nil)
  }
}

// MARK: - Environment parsing

struct ResourcePrincipalEnvironmentTests {
  @Test("Missing version throws versionNotDefined")
  func missingVersion() {
    #expect(throws: ResourcePrincipalError.versionNotDefined) {
      _ = try ResourcePrincipalSigner.fromEnvironment([:])
    }
  }

  @Test("Unsupported version throws unsupportedVersion")
  func unsupportedVersion() {
    #expect(throws: ResourcePrincipalError.unsupportedVersion("1.1")) {
      _ = try ResourcePrincipalSigner.fromEnvironment(["OCI_RESOURCE_PRINCIPAL_VERSION": "1.1"])
    }
  }

  @Test("Missing RPST throws missingSessionToken")
  func missingRPST() throws {
    let (_, pem) = try makeKeyPair()
    #expect(throws: ResourcePrincipalError.missingSessionToken) {
      _ = try ResourcePrincipalSigner.fromEnvironment([
        "OCI_RESOURCE_PRINCIPAL_VERSION": "2.2",
        "OCI_RESOURCE_PRINCIPAL_PRIVATE_PEM": pem,
      ])
    }
  }

  @Test("Missing private key throws missingPrivateKey")
  func missingKey() {
    let jwt = makeJWT(claims: ["exp": 1_893_456_000])
    #expect(throws: ResourcePrincipalError.missingPrivateKey) {
      _ = try ResourcePrincipalSigner.fromEnvironment([
        "OCI_RESOURCE_PRINCIPAL_VERSION": "2.2",
        "OCI_RESOURCE_PRINCIPAL_RPST": jwt,
      ])
    }
  }

  @Test("Valid environment builds a signer and exposes the region")
  func buildsFromEnvironment() throws {
    let (_, pem) = try makeKeyPair()
    let jwt = makeJWT(claims: ["exp": Int(Date().timeIntervalSince1970) + 3600])
    let signer = try ResourcePrincipalSigner.fromEnvironment([
      "OCI_RESOURCE_PRINCIPAL_VERSION": "2.2",
      "OCI_RESOURCE_PRINCIPAL_RPST": jwt,
      "OCI_RESOURCE_PRINCIPAL_PRIVATE_PEM": pem,
      "OCI_RESOURCE_PRINCIPAL_REGION": "us-phoenix-1",
    ])
    #expect(signer.region == "us-phoenix-1")
  }
}

// MARK: - Signing

struct ResourcePrincipalSigningTests {
  @Test("Signs a request with an ST$<rpst> keyId")
  func signsWithSecurityTokenKeyId() throws {
    let (_, pem) = try makeKeyPair()
    let jwt = makeJWT(claims: ["exp": Int(Date().timeIntervalSince1970) + 3600])
    let signer = ResourcePrincipalSigner(sessionToken: jwt, privateKeyPEM: pem, region: "us-phoenix-1")

    var req = URLRequest(url: URL(string: "https://objectstorage.us-phoenix-1.oraclecloud.com/n/")!)
    req.httpMethod = "GET"
    try signer.sign(&req)

    let auth = req.value(forHTTPHeaderField: "Authorization")
    #expect(auth != nil)
    #expect(auth?.contains("keyId=\"ST$\(jwt)\"") == true)
    #expect(auth?.contains("algorithm=\"rsa-sha256\"") == true)
    // A GET must not sign a body.
    #expect(auth?.contains("x-content-sha256") == false)
  }

  @Test("Invalid PEM surfaces as invalidPrivateKey at sign time")
  func invalidKeyThrows() {
    let jwt = makeJWT(claims: ["exp": Int(Date().timeIntervalSince1970) + 3600])
    let signer = ResourcePrincipalSigner(sessionToken: jwt, privateKeyPEM: "not-a-pem", region: nil)
    var req = URLRequest(url: URL(string: "https://example.com/")!)
    #expect(throws: ResourcePrincipalError.invalidPrivateKey) {
      try signer.sign(&req)
    }
  }
}
