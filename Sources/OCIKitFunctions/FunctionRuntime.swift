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
import Logging

/// The entry point for running a Swift program as an OCI Function.
///
/// Call one of the `serve` methods from your executable's `main` and it will:
/// 1. validate `FN_FORMAT` / `FN_LISTENER`,
/// 2. bind the Unix domain socket with the Fn "phony socket" readiness handshake,
/// 3. serve the http-stream contract (HTTP/1.1 keep-alive over the socket), turning
///    each request into one invocation of your handler,
/// 4. enforce the invocation deadline (`504` on timeout, `502` on an unhandled error).
///
/// It returns only when the listener socket closes, so it is normally the last call
/// in `main`.
///
/// ## Warm state
/// Everything you build **before** calling `serve` runs once per container and is
/// reused across invocations. Build your Resource Principal signer and OCI service
/// clients there and capture them in the handler:
///
/// ```swift
/// import OCIKit
/// import OCIKitFunctions
///
/// let runtime = RuntimeContext.fromEnvironment()
/// let signer = try await runtime.resourcePrincipalSigner()    // built once
/// let objectStorage = try ObjectStorageClient(region: .iad, signer: signer)
///
/// try await FunctionRuntime.serve { context, request in
///   let name = request.string ?? "world"
///   return .text("Hello, \(name)!")
/// }
/// ```
public enum FunctionRuntime {

  /// Serves invocations using a handler closure.
  ///
  /// - Parameters:
  ///   - logger: The logger used for FDK diagnostics.
  ///   - handler: The closure invoked once per request. Return a ``FunctionResponse``;
  ///     throwing yields a `502`, and exceeding the deadline yields a `504`.
  /// - Throws: ``FunctionRuntimeError`` if the container contract is broken
  ///   (missing/invalid `FN_LISTENER`, unsupported `FN_FORMAT`, or socket setup failure).
  public static func serve(
    logger: Logger = Logger(label: "OCIKitFunctions"),
    _ handler: @escaping FunctionHandler
  ) async throws {
    let environment = ProcessInfo.processInfo.environment
    try FnListener.validateFormat(environment)
    let listener = try FnListener.fromEnvironment(environment)
    let runtime = RuntimeContext.fromEnvironment(environment)
    let server = FunctionServer(listener: listener, runtime: runtime, handler: handler, logger: logger)
    try await server.run()
  }

  /// Serves invocations using a ``Function``-conforming handler object.
  ///
  /// - Parameters:
  ///   - function: The handler instance, constructed once at startup so its stored
  ///     state (clients, signers, caches) is reused across invocations.
  ///   - logger: The logger used for FDK diagnostics.
  public static func serve(
    _ function: some Function,
    logger: Logger = Logger(label: "OCIKitFunctions")
  ) async throws {
    try await serve(logger: logger) { context, request in
      try await function.handle(context, request)
    }
  }
}
