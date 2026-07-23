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
// An OCI Function that reads an Object Storage object using Resource Principal
// auth and returns its contents. Deployed with the OCIKitFunctions FDK; the
// bucket/object/namespace come from function config (with defaults for this test).
//

import Foundation
import OCIKit
import OCIKitFunctions

// The bucket/object/namespace come from function configuration (set with
// `oci fn function update --config`), so nothing tenancy-specific is baked in.
let runtime = RuntimeContext.fromEnvironment()
let namespace = runtime.value(for: "OSS_NAMESPACE") ?? ""
let bucket = runtime.value(for: "OSS_BUCKET") ?? ""
let object = runtime.value(for: "OSS_OBJECT") ?? ""

logger.info("relay-function starting: will read \(bucket)/\(object) (namespace \(namespace))")

try await FunctionRuntime.serve { _, _ in
  do {
    guard !namespace.isEmpty, !bucket.isEmpty, !object.isEmpty else {
      return .text("missing config: set OSS_NAMESPACE, OSS_BUCKET, OSS_OBJECT", status: 500)
    }
    // Resource Principal v2.2: OCI injects the session token + key into the
    // container environment; the signer reads them with no config file.
    let signer = try await runtime.resourcePrincipalSigner()
    let objectStorage = try ObjectStorageClient(region: .phx, signer: signer)
    let data = try await objectStorage.getObject(
      namespaceName: namespace,
      bucketName: bucket,
      objectName: object
    )
    return .data(data, contentType: "text/plain; charset=utf-8")
  }
  catch {
    logger.error("failed to read \(bucket)/\(object): \(error)")
    return .text("ERROR reading \(bucket)/\(object): \(error)", status: 500)
  }
}
