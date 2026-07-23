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

/// Whether destructive live tests are explicitly enabled.
///
/// Some live suites create and delete **real** OCI resources (buckets, objects,
/// PARs, replication/retention rules, and even compartments). They must never run
/// as a side effect of an ordinary test-suite run, so they are gated behind
/// `OCI_RUN_DESTRUCTIVE_TESTS=1` via `@Suite(.enabled(if: destructiveTestsEnabled))`.
///
/// Unset (the default, including in the committed test-plan template) → those
/// suites are reported as **skipped**. Set it deliberately — in a dedicated test
/// plan/scheme or on the command line — to run them:
///
/// ```sh
/// OCI_RUN_DESTRUCTIVE_TESTS=1 swift test --filter ObjectStorageTest
/// ```
let destructiveTestsEnabled = ProcessInfo.processInfo.environment["OCI_RUN_DESTRUCTIVE_TESTS"] == "1"

/// Message shown next to a skipped destructive suite.
let destructiveTestsSkipComment = "Destructive: set OCI_RUN_DESTRUCTIVE_TESTS=1 to run this suite."
