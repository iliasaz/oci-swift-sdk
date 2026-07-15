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

/// Defines behavior of changing ownership and permission of the volume before being exposed inside
/// the containers. This only applies to volumes which support fsGroup ownership and permissions,
/// and will have no effect on ephemeral volumes. ON_ROOT_MISMATCH only changes permissions and
/// ownership if the permission and ownership of the root directory does not match the expected
/// permissions and ownership of the volume. This can improve container instance start times.
/// ALWAYS changes permission and ownership of the volume when it is mounted. If unset, ALWAYS is used.
public enum FsGroupChangePolicy: String, Codable, Sendable {
  case always = "ALWAYS"
  case onRootMismatch = "ON_ROOT_MISMATCH"
}
