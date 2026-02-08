//
//  InstancePrincipalSigner.swift
//  OCIKit
//
//  Implements Instance Principals Security Token Signer similar to
//  oci/auth/signers/instance_principals_security_token_signer.py
//
//  Created by Alex (AI) on 9/13/25.
//

import Crypto
import Foundation
import _CryptoExtras

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// MARK: - InstancePrincipalSigner

public struct InstancePrincipalSigner: Signer {
  private let delegate: X509FederationClientBasedSecurityTokenSigner

  public init(
    federationEndpointOverride: String? = nil,
    purpose: String? = nil,
    logRequests: Bool = false
  ) throws {
    let federationClient = try InstancePrincipalsFederationClient(
      federationEndpointOverride: federationEndpointOverride,
      purpose: purpose,
      logRequests: logRequests
    )
    self.delegate = X509FederationClientBasedSecurityTokenSigner(federationClient: federationClient)
  }

  public func sign(_ req: inout URLRequest) throws {
    try delegate.sign(&req)
  }
}

// MARK: - Federation Client (Minimal)

final class InstancePrincipalsFederationClient: X509FederationClientProtocol, @unchecked Sendable {
  // IMDS constants
  private static let metadataBaseURL: String = {
    if let v = ProcessInfo.processInfo.environment["OCI_METADATA_BASE_URL"], !v.isEmpty {
      return v
    }
    return "http://169.254.169.254/opc/v2"
  }()

  private let GET_REGION_URL: URL
  private let LEAF_CERT_URL: URL
  private let LEAF_KEY_URL: URL
  private let INTERMEDIATE_CERT_URL: URL
  private let GET_INSTANCE_URL: URL
  private let METADATA_AUTH_HEADER = "Bearer Oracle"

  private let session: URLSession

  // Leaf cert + key (from IMDS)
  private let leafCertificatePEM: String
  private let leafPrivateKey: _RSA.Signing.PrivateKey
  private let intermediateCertificatePEM: String?

  // Session RSA key (ephemeral) bound to the token
  private let sessionPrivateKey: _RSA.Signing.PrivateKey

  // Token container
  private var token: SecurityTokenContainer?

  // Tenancy and region
  private let tenancyId: String
  private let regionIdLong: String
  private let federationEndpoint: URL
  private let purpose: String?

  // MARK: Init

  init(
    federationEndpointOverride: String?,
    purpose: String?,
    logRequests: Bool
  ) throws {
    let base = InstancePrincipalsFederationClient.metadataBaseURL
    self.GET_REGION_URL = URL(string: "\(base)/instance/region")!
    self.LEAF_CERT_URL = URL(string: "\(base)/identity/cert.pem")!
    self.LEAF_KEY_URL = URL(string: "\(base)/identity/key.pem")!
    self.INTERMEDIATE_CERT_URL = URL(string: "\(base)/identity/intermediate.pem")!
    self.GET_INSTANCE_URL = URL(string: "\(base)/instance/")!

    self.session = URLSession.shared
    self.purpose = purpose

    // Fetch IMDS artifacts
    let leafCertPEM = try Self.fetchText(url: LEAF_CERT_URL, authorization: METADATA_AUTH_HEADER)
    let leafKeyPEM = try Self.fetchText(url: LEAF_KEY_URL, authorization: METADATA_AUTH_HEADER)
    let interCertPEM = try? Self.fetchText(url: INTERMEDIATE_CERT_URL, authorization: METADATA_AUTH_HEADER)
    let regionRaw = try Self.fetchText(url: GET_REGION_URL, authorization: METADATA_AUTH_HEADER).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    self.leafCertificatePEM = leafCertPEM
    self.intermediateCertificatePEM = interCertPEM

    // Parse instance leaf private key
    guard let leafKey = try? _RSA.Signing.PrivateKey(pemRepresentation: leafKeyPEM) else {
      throw ConfigErrors.notPemFormat
    }
    self.leafPrivateKey = leafKey

    if let certTenancyId = try? Self.tenancyIdFromCertificatePEM(leafCertPEM) {
      self.tenancyId = certTenancyId
    }
    else {
      if let instanceJSON = try? Self.fetchJSON(url: GET_INSTANCE_URL, authorization: METADATA_AUTH_HEADER),
        let imdsTenancy = instanceJSON["tenantId"] as? String,
        !imdsTenancy.isEmpty
      {
        self.tenancyId = imdsTenancy
      }
      else {
        throw NSError(domain: "OCIKit.InstancePrincipalsFederationClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to obtain the tenancyId"])
      }
    }

    // Map region to long form using Region enum if possible
    if let region = Region(rawValue: regionRaw) {
      self.regionIdLong = region.urlPart
    }
    else {
      self.regionIdLong = regionRaw
    }

    // Federation endpoint
    if let override = federationEndpointOverride, let fedURL = URL(string: override) {
      self.federationEndpoint = fedURL
    }
    else {
      // https://auth.<region>.oraclecloud.com/v1/x509
      guard let fedURL = URL(string: "https://auth.\(regionIdLong).oraclecloud.com/v1/x509") else {
        throw URLError(.badURL)
      }
      self.federationEndpoint = fedURL
    }

    // Generate an ephemeral session RSA key
    self.sessionPrivateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
  }

  // MARK: - X509FederationClientProtocol

  func currentSecurityToken() throws -> String {
    if let t = token, t.validWithJitter() {
      return t.securityToken
    }
    try refreshToken()
    guard let t = token else { throw ConfigErrors.badSecurityTokenFile }
    return t.securityToken
  }

  func currentPrivateKey() throws -> _RSA.Signing.PrivateKey {
    return sessionPrivateKey
  }

  // MARK: - Token refresh

  private func refreshToken() throws {
    // Build request payload
    var payload: [String: Any] = [
      "certificate": Self.sanitizePEM(leafCertificatePEM),
      "publicKey": Self.sanitizePEM(Self.publicKeyPEM(from: sessionPrivateKey)),
    ]
    if let inter = intermediateCertificatePEM {
      payload["intermediateCertificates"] = [Self.sanitizePEM(inter)]
    }
    if let p = purpose {
      payload["purpose"] = p
    }

    let body = try JSONSerialization.data(withJSONObject: payload, options: [])

    // Compute fingerprint of leaf certificate (SHA-1 over DER)
    let fingerprint = try Self.certificateFingerprintSHA1Hex(pem: leafCertificatePEM)

    // Build request
    var req = URLRequest(url: federationEndpoint)
    req.httpMethod = "POST"
    req.httpBody = body
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.setValue("application/json", forHTTPHeaderField: "accept")

    // Sign request with leaf private key and special keyId
    let keyId = "\(tenancyId)/fed-x509/\(fingerprint)"
    try RequestSigner.sign(&req, with: leafPrivateKey, keyId: keyId, includeBodyForVerbs: ["post", "put", "patch"])

    // Execute
    let (data, resp) = try Self.dataFor(session: session, req: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let bodyStr = String(data: data, encoding: .utf8) ?? ""
      throw NSError(domain: "OCIKit.FederationClient", code: (resp as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Auth federation failed: \(bodyStr)"])
    }

    // Parse JSON { "token": "<jwt>" }
    guard
      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tokenStr = obj["token"] as? String
    else {
      let bodyStr = String(data: data, encoding: .utf8) ?? ""
      throw NSError(domain: "OCIKit.FederationClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Auth federation response missing token: \(bodyStr)"])
    }

    self.token = SecurityTokenContainer(sessionKeySupplier: sessionPrivateKey, securityToken: tokenStr)
  }
}

// MARK: - Helpers

extension InstancePrincipalsFederationClient {
  // Simple IMDS fetch with Bearer header
  fileprivate static func fetchText(url: URL, authorization: String) throws -> String {
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue(authorization, forHTTPHeaderField: "Authorization")
    let (data, resp) = try dataFor(session: URLSession.shared, req: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate static func fetchJSON(url: URL, authorization: String) throws -> [String: Any] {
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue(authorization, forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, resp) = try dataFor(session: URLSession.shared, req: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    let obj = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = obj as? [String: Any] else {
      throw URLError(.cannotParseResponse)
    }
    return dict
  }

  fileprivate static func dataFor(session: URLSession, req: URLRequest) throws -> (Data, URLResponse) {
    nonisolated(unsafe) var result: Result<(Data, URLResponse), Error>!
    let sem = DispatchSemaphore(value: 1)
    sem.wait()
    let group = DispatchGroup()
    group.enter()
    session.dataTask(with: req) { data, resp, err in
      defer { group.leave() }
      if let err {
        result = .failure(err)
      }
      else if let data, let resp {
        result = .success((data, resp))
      }
      else {
        result = .failure(URLError(.unknown))
      }
    }.resume()
    group.wait()
    sem.signal()
    switch result! {
    case .success(let tuple): return tuple
    case .failure(let e): throw e
    }
  }

  fileprivate static func sanitizePEM(_ pem: String) -> String {
    pem
      .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
      .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
      .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
      .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
      .replacingOccurrences(of: "\r", with: "")
      .replacingOccurrences(of: "\n", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate static func publicKeyPEM(from privateKey: _RSA.Signing.PrivateKey) -> String {
    // Assuming CryptoExtras exposes PEM for public key via privateKey.publicKey.pemRepresentation
    return privateKey.publicKey.pemRepresentation
  }

  fileprivate static func certificateFingerprintSHA1Hex(pem: String) throws -> String {
    let der = try derFromPEM(pem)
    let digest = Insecure.SHA1.hash(data: der)
    let bytes = Array(digest)
    return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
  }

  fileprivate static func derFromPEM(_ pem: String) throws -> Data {
    let trimmed =
      pem
      .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
      .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
      .replacingOccurrences(of: "\r", with: "")
      .replacingOccurrences(of: "\n", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let der = Data(base64Encoded: trimmed) else {
      throw NSError(domain: "OCIKit.PEM", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid certificate PEM"])
    }
    return der
  }

  fileprivate static func tenancyIdFromCertificatePEM(_ pem: String) throws -> String {
    let der = try derFromPEM(pem)
    if let tid = extractTaggedValue(in: der, tag: "opc-tenant:") {
      return tid
    }
    if let tid = extractTaggedValue(in: der, tag: "opc-identity:") {
      return tid
    }
    throw NSError(domain: "OCIKit.Certificate", code: -3, userInfo: [NSLocalizedDescriptionKey: "The certificate does not contain a tenancy OCID"])
  }

  fileprivate static func extractTaggedValue(in data: Data, tag: String) -> String? {
    let tagBytes = Array(tag.utf8)
    let bytes = [UInt8](data)
    var i = 0
    while i <= bytes.count - tagBytes.count {
      if Array(bytes[i..<(i + tagBytes.count)]) == tagBytes {
        let start = i + tagBytes.count
        var end = start
        while end < bytes.count {
          let c = bytes[end]
          let isLower = c >= 0x61 && c <= 0x7A
          let isDigit = c >= 0x30 && c <= 0x39
          let isDot = c == 0x2E
          let isDash = c == 0x2D
          if isLower || isDigit || isDot || isDash {
            end += 1
          }
          else {
            break
          }
        }
        var sliceEnd = end
        if sliceEnd > start {
          // If the last collected character is '0' and the next byte looks like a DER tag/length boundary,
          // drop the trailing '0' which is actually the DER SEQUENCE (0x30) byte misread as ASCII.
          if bytes[sliceEnd - 1] == 0x30 {
            if end < bytes.count {
              let next = bytes[end]
              if next >= 0x80 || next == 0x30 || next == 0x31 || next == 0x06 || next == 0x0C || next == 0x13 || next == 0x16 || next == 0x17 || next == 0x18 {
                sliceEnd -= 1
              }
            }
          }
        }
        if sliceEnd > start, let s = String(bytes: bytes[start..<sliceEnd], encoding: .utf8), !s.isEmpty {
          return s
        }
      }
      i += 1
    }
    return nil
  }
}

// MARK: - Simple SecurityTokenContainer (JWT decode without verification)

private final class SecurityTokenContainer {
  let securityToken: String
  private let sessionKeySupplier: _RSA.Signing.PrivateKey
  private let jwt: [String: Any]

  init(sessionKeySupplier: _RSA.Signing.PrivateKey, securityToken: String) {
    self.securityToken = securityToken
    self.sessionKeySupplier = sessionKeySupplier
    self.jwt = Self.decodeJWTNoVerify(securityToken) ?? [:]
  }

  func validWithJitter(_ jitter: Int = 60) -> Bool {
    guard let exp = jwt["exp"] as? Int else { return false }
    let now = Int(Date().timeIntervalSince1970)
    return now <= (exp - jitter)
  }

  static func decodeJWTNoVerify(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    let payload = String(parts[1])
    guard let data = base64URLDecode(payload) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  static func base64URLDecode(_ s: String) -> Data? {
    var base64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let pad = 4 - (base64.count % 4)
    if pad < 4 {
      base64 += String(repeating: "=", count: pad)
    }
    return Data(base64Encoded: base64)
  }
}
