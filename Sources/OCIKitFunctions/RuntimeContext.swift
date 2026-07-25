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

import Foundation
import OCIKit

/// Per-container context, built once at process start from the environment.
///
/// Everything here is stable for the life of the container, so a handler that
/// captures it (or values derived from it, such as an OCI service client) gets
/// "warm" state reused across every invocation on that container.
public struct RuntimeContext: Sendable {
  /// Every environment variable visible to the process (parity with fdk-go's
  /// `Config()` and fdk-python's `config()`), including the platform's `FN_*`
  /// values and any application/function configuration.
  public let config: [String: String]

  public init(config: [String: String]) {
    self.config = config
  }

  /// Builds the runtime context from the process environment (injectable for tests).
  public static func fromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> RuntimeContext {
    RuntimeContext(config: environment)
  }

  /// The value of an arbitrary environment/config key.
  public func value(for key: String) -> String? {
    config[key]
  }

  /// The OCID of the application this function belongs to (`FN_APP_ID`).
  public var appID: String? { config["FN_APP_ID"] }

  /// The name of the application this function belongs to (`FN_APP_NAME`).
  public var appName: String? { config["FN_APP_NAME"] }

  /// The OCID of this function (`FN_FN_ID`).
  public var functionID: String? { config["FN_FN_ID"] }

  /// The name of this function (`FN_FN_NAME`).
  public var functionName: String? { config["FN_FN_NAME"] }

  /// The memory limit of the function in MB (`FN_MEMORY`), if set.
  public var memoryMB: Int? { config["FN_MEMORY"].flatMap(Int.init) }

  /// Builds a Resource Principals v2.2 signer from the platform-injected
  /// `OCI_RESOURCE_PRINCIPAL_*` environment variables.
  ///
  /// This is a thin convenience over ``OCIKit/ResourcePrincipalSigner`` — the FDK
  /// contains no auth logic of its own. Build the signer **once** (e.g. just before
  /// calling ``FunctionRuntime/serve(logger:_:)`` and capture it in your handler);
  /// the signer transparently re-reads the RPST/private-key files and refreshes the
  /// short-lived token as it nears expiry, so a single instance is safe to reuse for
  /// the life of a warm container.
  ///
  /// - Throws: ``OCIKit/ResourcePrincipalError`` if the environment does not carry a
  ///   valid Resource Principal (e.g. when running outside OCI Functions).
  public func resourcePrincipalSigner() async throws -> ResourcePrincipalSigner {
    try await ResourcePrincipalSigner.fromEnvironment(config)
  }
}
