//
//  Signer.swift
//
//
//  Created by Ilia Sazonov on 5/6/24.
//

import Crypto
import Foundation
import Logging
import _CryptoExtras

public let logger = Logger(label: "OCIKit")

// Linux compatibility
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// CryptoKit.Digest utils
extension Digest {
  var bytes: [UInt8] { Array(makeIterator()) }
  var data: Data { Data(bytes) }

  var hexStr: String {
    bytes.map { String(format: "%02X", $0) }.joined()
  }

  var base64: String {
    data.base64EncodedString()
  }
}

public protocol Signer: Sendable {
  /// Signs `req` in place, adding the OCI request-signature headers.
  ///
  /// The requirement is `async` so that token-based signers can transparently
  /// refresh short-lived credentials (a network round-trip for instance/OKE
  /// principals) inline before signing, and so that the refresh state can be
  /// protected by actor isolation rather than a lock. Stateless signers
  /// (API key, static security token) satisfy it without ever suspending.
  func sign(_ req: inout URLRequest) async throws
}

/// A signer whose credentials can be forcibly refreshed after an authentication
/// failure.
///
/// Token-based signers cache short-lived security tokens that can be rejected by
/// the service (HTTP `401`) even though they still look valid locally — e.g. when
/// the underlying instance identity certificate rotates. When a request signed by
/// a `RefreshableSigner` receives a `401`, ``HTTPClient/send(_:signer:retry:logger:)``
/// calls ``forceRefresh()`` and retries the request once.
public protocol RefreshableSigner: Signer {
  /// Discards any cached security material and obtains fresh credentials so the
  /// next ``Signer/sign(_:)`` call uses them. Because it is `async`, the `401`
  /// retry path can `await` a completed refresh before re-signing.
  func forceRefresh() async throws
}

enum RequestSigner {
  static func sign(
    _ req: inout URLRequest,
    with privateKey: _RSA.Signing.PrivateKey,
    keyId: String,
    includeBodyForVerbs: Set<String> = ["post", "put", "patch"]
  ) throws {
    let verb = req.httpMethod?.lowercased() ?? ""
    let path = req.url?.path ?? "/"
    let query = req.url?.query
    let encodedPath: String
    // Keeping the different tries herem if a new issue appears we know what we tried.
    //  let fullPath = query != nil ? "\(path)?\(query!)" : path
    // let encodedPath = fullPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fullPath
    // let encodedPath = fullPath
    //          let encodedPath = fullPath.addingPercentEncoding(
    //              withAllowedCharacters: .urlPathAllowed.union(.urlQueryAllowed)
    //           ) ?? ""
    //           let encodedPath = req.url?.relativePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

    // ************************************
    // * One more try for proper encoding *
    // ************************************
    // The full path (potentially with a query string) and need it percent-encoded in a consistent, standards-compliant way
    if let query = query, !query.isEmpty {
      // Encode path and query separately
      let safePath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
      let safeQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
      encodedPath = "\(safePath)?\(safeQuery)"
    }
    else {
      encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    req.addValue(req.url?.host ?? "", forHTTPHeaderField: "host")
    let dateString = Self.rfc1123DateString(from: Date())
    req.addValue(dateString, forHTTPHeaderField: "date")

    var authHeader: [String] = [#"Signature version="1""#]
    var signingString: [String] = []

    var contentType = req.value(forHTTPHeaderField: "content-type") ?? ""
    if contentType.isEmpty {
      contentType = "application/json"
      req.addValue(contentType, forHTTPHeaderField: "content-type")
    }

    if includeBodyForVerbs.contains(verb) {
      let contentLength: Int = req.httpBody?.count ?? 0
      let xContentSHA256: String = SHA256.hash(data: req.httpBody ?? "".data(using: .utf8)!).base64

      authHeader.append(#"headers="date (request-target) host content-length content-type x-content-sha256""#)
      signingString.append("date: \(dateString)")
      signingString.append("(request-target): \(verb) \(encodedPath)")
      signingString.append("host: \(req.url?.host ?? "")")
      signingString.append("content-length: \(contentLength)")
      signingString.append("content-type: \(contentType)")
      signingString.append("x-content-sha256: \(xContentSHA256)")

      req.addValue(String(contentLength), forHTTPHeaderField: "content-length")
      req.addValue(xContentSHA256, forHTTPHeaderField: "x-content-sha256")
    }
    else {
      authHeader.append(#"headers="date (request-target) host""#)
      signingString.append("date: \(dateString)")
      signingString.append("(request-target): \(verb) \(encodedPath)")
      signingString.append("host: \(req.url?.host ?? "")")
    }

    authHeader.append(#"keyId="\#(keyId)""#)
    authHeader.append(#"algorithm="rsa-sha256""#)

    logger.debug("signingString: \n\(signingString)\n----------------\n")
    let dataToSign = signingString.joined(separator: "\n").data(using: .ascii)!
    let signature = try privateKey.signature(for: dataToSign, padding: .insecurePKCS1v1_5)
    let signatureBase64String = signature.rawRepresentation.base64EncodedString()

    authHeader.append(#"signature="\#(signatureBase64String)""#)
    req.addValue(authHeader.joined(separator: ","), forHTTPHeaderField: "Authorization")
  }

  /// Formats `date` as the RFC 1123 `date` header used in the OCI signing string.
  ///
  /// The formatter is pinned to `en_US_POSIX` and GMT so the output is always the
  /// ASCII, English, UTC wall-clock representation of the instant — independent of
  /// the host's locale and time zone. Pinning the locale avoids the Cocoa
  /// date-formatting trap (Apple QA1480): a non-English `Locale.current` would
  /// otherwise render localized day/month names (e.g. "lun., 21 juil. 2026") or
  /// non-Latin digits, malforming the signed string and yielding an HTTP 401.
  /// Pinning the zone to GMT keeps the value correct across DST transitions. See
  /// issue #97.
  static func rfc1123DateString(from date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
  }
}
