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
// The batteries-included, "white-gloves" entry point for OKE Workload Identity:
// one import + one call yields a fully wired, CA-pinned signer.
//

import Foundation
import Logging
import OCIKit

extension OKEWorkloadIdentitySigner {
  /// Builds an OKE Workload Identity signer wired to an in-process CA-pinning
  /// transport (AsyncHTTPClient + NIOSSL) and performs the first token exchange,
  /// so the returned signer is immediately usable.
  ///
  /// It reads the standard OKE environment (`KUBERNETES_SERVICE_HOST`,
  /// `OCI_KUBERNETES_SERVICE_ACCOUNT_CERT_PATH`, `OCI_RESOURCE_PRINCIPAL_REGION`),
  /// pins the auto-mounted cluster CA in-process, and requires **no** OS
  /// trust-store install and **no** cluster step — matching the Java/Python/Go
  /// SDKs.
  ///
  /// ```swift
  /// import OCIKit
  /// import OCIKitWorkloadIdentity
  ///
  /// let signer = try await OKEWorkloadIdentitySigner.fromWorkloadIdentity()
  /// let client = try ObjectStorageClient(region: .fra, signer: signer)
  /// ```
  ///
  /// - Parameters:
  ///   - verifyHostname: Passed through to
  ///     ``OKEProxymuxTransport/caPinned(caCertPath:verifyHostname:timeout:)``.
  ///     Keep `true` unless the proxymux certificate lacks the API-server host in
  ///     its SAN.
  ///   - logger: Logger for diagnostics.
  ///   - environment: The environment to read (defaults to the process environment).
  /// - Throws: ``OKEWorkloadIdentityError`` when required environment values are
  ///   absent or the initial exchange fails.
  public static func fromWorkloadIdentity(
    verifyHostname: Bool = true,
    logger: Logger = Logger(label: "OKEWorkloadIdentitySigner"),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async throws -> OKEWorkloadIdentitySigner {
    let caCertPath = OKEWorkloadIdentitySigner.serviceAccountCertPath(fromEnvironment: environment)
    let transport = OKEProxymuxTransport.caPinned(caCertPath: caCertPath, verifyHostname: verifyHostname)
    return try await OKEWorkloadIdentitySigner.fromEnvironment(
      transport: transport,
      logger: logger,
      environment: environment
    )
  }
}
