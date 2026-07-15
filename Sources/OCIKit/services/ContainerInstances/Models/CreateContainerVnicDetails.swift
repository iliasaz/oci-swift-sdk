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

/// Information to create a virtual network interface card (VNIC) which gives the containers on this
/// container instance access to a virtual client network (VCN).
///
/// You use this object when creating the primary VNIC during container instance launch or when
/// creating a secondary VNIC. This VNIC is created in the same compartment as the specified subnet
/// on behalf of the customer. The VNIC created by this call contains both the tags specified in this
/// object as well as any tags specified in the parent container instance.
public struct CreateContainerVnicDetails: Codable {
  /// A user-friendly name for the VNIC. Does not have to be unique. Avoid entering confidential information.
  public let displayName: String?
  /// The hostname for the VNIC's primary private IP. Used for DNS.
  public let hostnameLabel: String?
  /// Whether the VNIC should be assigned a public IP address.
  public let isPublicIpAssigned: Bool?
  /// Whether the source/destination check is disabled on the VNIC.
  public let skipSourceDestCheck: Bool?
  /// A list of the OCIDs of the network security groups (NSGs) to add the VNIC to.
  public let nsgIds: [String]?
  /// A private IP address of your choice to assign to the VNIC. Must be an available IP address within the subnet's CIDR.
  public let privateIp: String?
  /// The OCID of the subnet to create the VNIC in.
  public let subnetId: String
  /// Simple key-value pair that is applied without any predefined name, type or scope. Exists for cross-compatibility only. Example: `{"bar-key": "value"}`
  public let freeformTags: [String: String]?
  /// Defined tags for this resource. Each key is predefined and scoped to a namespace. Example: `{"foo-namespace": {"bar-key": "value"}}`.
  public let definedTags: [String: [String: String]]?

  public init(
    displayName: String? = nil,
    hostnameLabel: String? = nil,
    isPublicIpAssigned: Bool? = nil,
    skipSourceDestCheck: Bool? = nil,
    nsgIds: [String]? = nil,
    privateIp: String? = nil,
    subnetId: String,
    freeformTags: [String: String]? = nil,
    definedTags: [String: [String: String]]? = nil
  ) {
    self.displayName = displayName
    self.hostnameLabel = hostnameLabel
    self.isPublicIpAssigned = isPublicIpAssigned
    self.skipSourceDestCheck = skipSourceDestCheck
    self.nsgIds = nsgIds
    self.privateIp = privateIp
    self.subnetId = subnetId
    self.freeformTags = freeformTags
    self.definedTags = definedTags
  }
}
