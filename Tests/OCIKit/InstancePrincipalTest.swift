//
//  InstancePrincipalTest.swift
//  oci-swift-sdk
//
//  Created by Alex (AI) on 9/13/25.
//

import Foundation
import OCIKit
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct InstancePrincipalObjectStorageTest {
  private func fetchIMDSRegion(timeoutSeconds: TimeInterval = 5) async -> String? {
    let base = ProcessInfo.processInfo.environment["OCI_METADATA_BASE_URL"] ?? "http://169.254.169.254/opc/v2"
    guard let url = URL(string: "\(base)/instance/region") else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.setValue("Bearer Oracle", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = timeoutSeconds

    // Use the async URLSession API. On Apple platforms this is the native method;
    // on Linux it resolves to the shim in core/URLSession+Linux.swift. This avoids
    // mutating a captured var inside a @Sendable completion handler, which is a hard
    // error under strict concurrency on swift-corelibs-foundation (Linux).
    guard
      let (data, resp) = try? await URLSession.shared.data(for: req),
      let http = resp as? HTTPURLResponse,
      (200..<300).contains(http.statusCode)
    else { return nil }

    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  @Test("getNamespace succeeds when signed with an instance principal (live, self-skips off OCI)")
  func getNamespace_withInstancePrincipalSigner() async throws {
    guard let regionRaw = await fetchIMDSRegion() else {
      logger.info("Skipping Instance Principal test: IMDS region unavailable (not running on OCI instance?)")
      return
    }

    guard let region = Region.from(regionId: regionRaw) else {
      logger.info("Skipping Instance Principal test: IMDS returned unsupported or short region '\(regionRaw)'; Region enum expects long-form (e.g. us-phoenix-1).")
      return
    }

    let signer = try await InstancePrincipalSigner.fromMetadata()
    let client = try ObjectStorageClient(region: region, signer: signer)

    let namespace = try await client.getNamespace()
    logger.info("Namespace (Instance Principal): \(namespace)")
    #expect(!namespace.isEmpty)
  }
}
