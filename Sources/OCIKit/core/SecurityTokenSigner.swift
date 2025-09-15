//
//  SecurityTokenSigner.swift
//
//  Created by Alex (AI) on 9/12/25.
//

import Foundation
import Crypto
import _CryptoExtras
import Logging

// Linux compatibility
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SecurityTokenSigner: Signer {
    private let securityToken: String
    private let privateKey: _RSA.Signing.PrivateKey

    public init(securityToken: String, privateKey: _RSA.Signing.PrivateKey) {
        self.securityToken = securityToken
        self.privateKey = privateKey
    }

    public init(configFilePath: String, configName: String = "DEFAULT") throws {
        let cfg = try SignerConfiguration.fromFileForSecurityToken(configFilePath: configFilePath, configName: configName)
        guard let token = cfg.securityToken else { throw ConfigErrors.badSecurityTokenFile }
        self.init(securityToken: token, privateKey: cfg.privateKey)
    }

    public init(configuration: SignerConfiguration) throws {
        guard let token = configuration.securityToken else { throw ConfigErrors.badSecurityTokenFile }
        self.init(securityToken: token, privateKey: configuration.privateKey)
    }

    public func sign(_ req: inout URLRequest) throws {
        let keyId = "ST$\(securityToken)"
        try RequestSigner.sign(&req, with: privateKey, keyId: keyId, includeBodyForVerbs: ["post", "put", "patch"])
    }
}