//
//  APIKeySigner.swift
//
//
//  Created by Ilia Sazonov on 5/6/24.
//

import Crypto
import Foundation
import _CryptoExtras

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct APIKeySigner: Signer {
  private let config: SignerConfiguration

  public func sign(_ req: inout URLRequest) async throws {
    guard
      let tenancy = config.tenancyOCID,
      let user = config.userOCID,
      let fingerprint = config.fingerprint
    else {
      throw ConfigErrors.missingConfig
    }
    let keyId = "\(tenancy)/\(user)/\(fingerprint)"
    try RequestSigner.sign(&req, with: config.privateKey, keyId: keyId, includeBodyForVerbs: ["post", "put"])
  }

  public init(configFilePath: String, configName: String = "DEFAULT") throws {
    self.config = try SignerConfiguration.fromFileForAPIKey(configFilePath: configFilePath, configName: configName)
  }

  public init(configuration: SignerConfiguration) {
    self.config = configuration
  }
}
