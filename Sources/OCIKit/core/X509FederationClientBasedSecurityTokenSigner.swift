//
//  X509FederationClientBasedSecurityTokenSigner.swift
//  oci-swift-sdk
//
//  Created by Ilia Sazonov on 9/14/25.
//

import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public final class X509FederationClientBasedSecurityTokenSigner: Signer, @unchecked Sendable {
  private let federationClient: X509FederationClientProtocol

  public init(federationClient: X509FederationClientProtocol) {
    self.federationClient = federationClient
  }

  public func sign(_ req: inout URLRequest) throws {
    let token = try federationClient.currentSecurityToken()
    let key = try federationClient.currentPrivateKey()
    let delegateSigner = SecurityTokenSigner(securityToken: token, privateKey: key)
    try delegateSigner.sign(&req)
  }
}
