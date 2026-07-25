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
import Testing

/// Whether destructive live tests are explicitly enabled.
///
/// Some live tests create, mutate and delete **real** OCI resources (buckets,
/// objects, PARs, replication/retention rules, and even compartments). They must
/// never run as a side effect of an ordinary test-suite run, so each one is
/// tagged ``Trait/destructive`` and only runs when `OCI_RUN_DESTRUCTIVE_TESTS=1`.
///
/// ```sh
/// OCI_RUN_DESTRUCTIVE_TESTS=1 swift test --filter ObjectStorageTest
/// ```
let destructiveTestsEnabled = ProcessInfo.processInfo.environment["OCI_RUN_DESTRUCTIVE_TESTS"] == "1"

/// Message shown next to a skipped destructive test.
let destructiveTestsSkipComment = "Destructive: set OCI_RUN_DESTRUCTIVE_TESTS=1 to run this test."

extension Trait where Self == ConditionTrait {
  /// Marks a test that creates, mutates or deletes **real** OCI resources.
  ///
  /// Gated on `OCI_RUN_DESTRUCTIVE_TESTS=1` so it is skipped by default. Read-only
  /// tests in the same suite are deliberately left ungated so they still run.
  static var destructive: Self {
    .enabled(if: destructiveTestsEnabled, Comment(rawValue: destructiveTestsSkipComment))
  }

  /// Marks a read-only test that depends on a specific value from the test plan —
  /// typically a per-resource identifier (PAR id/URL, object version, replication
  /// or retention rule id) that changes whenever the resource is recreated.
  ///
  /// The test self-skips when the variable is unset or blank, rather than failing.
  static func requiresEnv(_ key: String) -> Self {
    .enabled(
      if: !(ProcessInfo.processInfo.environment[key] ?? "").isEmpty,
      Comment(rawValue: "Set \(key) in the test plan to run this test.")
    )
  }
}
