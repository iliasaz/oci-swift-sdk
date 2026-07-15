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

/// Allow customers to define DNS settings for containers. If this is not provided, the containers use the default DNS settings of the subnet.
public struct CreateContainerDnsConfigDetails: Codable {
  /// IP address of a name server that the resolver should query, either an IPv4 address (in dot notation), or an IPv6 address in colon (and possibly dot) notation. If null, uses nameservers from subnet dhcpDnsOptions.
  public let nameservers: [String]?
  /// Search list for host-name lookup. If null, uses searches from subnet dhcpDnsOptions.
  public let searches: [String]?
  /// Options allows certain internal resolver variables to be modified. Options are a list of objects in https://man7.org/linux/man-pages/man5/resolv.conf.5.html. Examples: ["ndots:n", "edns0"].
  public let options: [String]?

  public init(nameservers: [String]? = nil, searches: [String]? = nil, options: [String]? = nil) {
    self.nameservers = nameservers
    self.searches = searches
    self.options = options
  }
}
