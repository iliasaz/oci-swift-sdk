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

/// DNS settings for containers.
public struct ContainerDnsConfig: Codable {
  /// IP address of the name server.
  public let nameservers: [String]?
  /// Search list for hostname lookup.
  public let searches: [String]?
  /// Options allows certain internal resolver variables to be modified.
  public let options: [String]?

  public init(nameservers: [String]? = nil, searches: [String]? = nil, options: [String]? = nil) {
    self.nameservers = nameservers
    self.searches = searches
    self.options = options
  }
}
