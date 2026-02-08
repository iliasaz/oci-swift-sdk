//
//  SignerConfiguration.swift
//
//  Shared configuration loader and validator for all signers.
//
//  Created by Alex (AI) on 9/12/25.
//

import Configuration
import Crypto
import Foundation
import INIParser
import SystemPackage
import _CryptoExtras

public enum ConfigErrors: Error, LocalizedError {
  case missingConfig
  case missingFingerprint
  case missingKeyfile
  case missingTenancy
  case missingUser
  case missingRegion
  case missingSecurityTokenFile
  case badKeyfile
  case notPemFormat
  case badSecurityTokenFile
  case badConfigFileFormat

  public var errorDescription: String? {
    switch self {
    case .missingConfig: return "Missing OCI configuration file"
    case .missingFingerprint: return "Fingerprint is missing in OCI configuration"
    case .missingKeyfile: return "Keyfile is missing in OCI configuration"
    case .missingTenancy: return "Tenancy is missing in OCI configuration"
    case .missingUser: return "User is missing in OCI configuration"
    case .missingRegion: return "Region is missing in OCI configuration"
    case .missingSecurityTokenFile: return "Security Token File is missing in OCI configuration"
    case .badKeyfile: return "Key file does not have a valid private key"
    case .notPemFormat: return "Key is not in Pem format"
    case .badSecurityTokenFile: return "Security Token file is malformed or missing"
    case .badConfigFileFormat: return "OCI configuration file is malformed"
    }
  }
}

private func expandTilde(_ path: String) -> String {
  (path as NSString).expandingTildeInPath
}

private func extractPemPrivateKeyBlock(from raw: String) -> String? {
  let variants: [(begin: String, end: String)] = [
    ("-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----"),
    ("-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----"),
  ]

  for v in variants {
    if let beginRange = raw.range(of: v.begin),
      let endRange = raw.range(of: v.end),
      beginRange.lowerBound < endRange.upperBound
    {
      let block = raw[beginRange.lowerBound..<endRange.upperBound]
      return String(block)
    }
  }

  // Fallback with regex to be robust if needed
  if let regex = try? NSRegularExpression(pattern: "-----BEGIN (?:RSA )?PRIVATE KEY-----[\\s\\S]*?-----END (?:RSA )?PRIVATE KEY-----", options: []),
    let match = regex.firstMatch(in: raw, options: [], range: NSRange(location: 0, length: (raw as NSString).length))
  {
    let nsRaw = raw as NSString
    return nsRaw.substring(with: match.range)
  }

  return nil
}

public struct SignerConfiguration: Sendable {
  public let name: String
  public let privateKey: _RSA.Signing.PrivateKey
  public let tenancyOCID: String?
  public let userOCID: String?
  public let fingerprint: String?
  public let securityToken: String?
  public let region: String

  public init(
    name: String,
    privateKey: _RSA.Signing.PrivateKey,
    tenancyOCID: String?,
    userOCID: String?,
    fingerprint: String?,
    securityToken: String?,
    region: String
  ) {
    self.name = name
    self.privateKey = privateKey
    self.tenancyOCID = tenancyOCID
    self.userOCID = userOCID
    self.fingerprint = fingerprint
    self.securityToken = securityToken
    self.region = region
  }

  public static func fromFileForAPIKey(configFilePath: String, configName: String = "DEFAULT") throws -> SignerConfiguration {
    guard let configs = try? INIParser(configFilePath) else { throw ConfigErrors.missingConfig }
    guard configs.sections.keys.contains(configName), let section = configs.sections[configName] else {
      throw ConfigErrors.badConfigFileFormat
    }

    guard let fingerprint = section["fingerprint"] else { throw ConfigErrors.missingFingerprint }
    guard let userOCID = section["user"] else { throw ConfigErrors.missingUser }
    guard let tenancyOCID = section["tenancy"] else { throw ConfigErrors.missingTenancy }
    guard let keyfilePath = section["key_file"] else { throw ConfigErrors.missingKeyfile }
    guard let region = section["region"] else { throw ConfigErrors.missingRegion }
    guard let keyFileContents = try? String(contentsOfFile: expandTilde(keyfilePath), encoding: .utf8) else { throw ConfigErrors.badKeyfile }

    let pemString = extractPemPrivateKeyBlock(from: keyFileContents) ?? keyFileContents
    guard let privateKey = try? _RSA.Signing.PrivateKey(pemRepresentation: pemString) else { throw ConfigErrors.notPemFormat }

    return SignerConfiguration(
      name: configName,
      privateKey: privateKey,
      tenancyOCID: tenancyOCID,
      userOCID: userOCID,
      fingerprint: fingerprint,
      securityToken: nil,
      region: region
    )
  }

  public static func fromFileForSecurityToken(configFilePath: String, configName: String = "DEFAULT") throws -> SignerConfiguration {
    let configs = try INIParser(configFilePath)
    guard configs.sections.keys.contains(configName), let section = configs.sections[configName] else {
      throw ConfigErrors.missingConfig
    }

    guard let keyfilePath = section["key_file"] else { throw ConfigErrors.missingKeyfile }
    guard let keyFileContents = try? String(contentsOfFile: expandTilde(keyfilePath), encoding: .utf8) else { throw ConfigErrors.badKeyfile }

    let pemString = extractPemPrivateKeyBlock(from: keyFileContents) ?? keyFileContents
    guard let privateKey = try? _RSA.Signing.PrivateKey(pemRepresentation: pemString) else { throw ConfigErrors.notPemFormat }

    guard let tokenFilePath = section["security_token_file"] else { throw ConfigErrors.missingSecurityTokenFile }
    guard
      let token = try? String(contentsOfFile: expandTilde(tokenFilePath), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
    else {
      throw ConfigErrors.badSecurityTokenFile
    }
    guard let region = section["region"] else { throw ConfigErrors.missingRegion }

    return SignerConfiguration(
      name: configName,
      privateKey: privateKey,
      tenancyOCID: section["tenancy"],
      userOCID: section["user"],
      fingerprint: section["fingerprint"],
      securityToken: token,
      region: region
    )
  }

  /// Loads API Key configuration from a `.env` file or process environment using swift-configuration.
  ///
  /// Expected keys in the `.env` file:
  /// ```
  /// OCI_TENANCY=ocid1.tenancy.oc1..xxxxx
  /// OCI_USER=ocid1.user.oc1..xxxxx
  /// OCI_FINGERPRINT=aa:bb:cc:dd:ee:ff
  /// OCI_KEY_FILE=~/.oci/oci_api_key.pem
  /// OCI_REGION=eu-frankfurt-1
  /// ```
  ///
  /// For deployments where a key file isn't available (e.g. fly.io), use `OCI_KEY_CONTENT`
  /// with the base64-encoded PEM file instead of `OCI_KEY_FILE`:
  /// ```
  /// fly secrets set OCI_KEY_CONTENT=$(base64 < ~/.oci/oci_api_key.pem)
  /// ```
  public static func fromEnvForAPIKey(envFilePath: String = ".env") async throws -> SignerConfiguration {
    let provider: EnvironmentVariablesProvider
    if FileManager.default.fileExists(atPath: envFilePath) {
      provider = try await EnvironmentVariablesProvider(
        environmentFilePath: FilePath(envFilePath)
      )
    }
    else {
      provider = EnvironmentVariablesProvider()
    }
    let config = ConfigReader(provider: provider)

    guard let fingerprint = config.string(forKey: "oci.fingerprint") else { throw ConfigErrors.missingFingerprint }
    guard let userOCID = config.string(forKey: "oci.user") else { throw ConfigErrors.missingUser }
    guard let tenancyOCID = config.string(forKey: "oci.tenancy") else { throw ConfigErrors.missingTenancy }
    guard let region = config.string(forKey: "oci.region") else { throw ConfigErrors.missingRegion }

    // OCI_KEY_CONTENT (base64-encoded PEM) takes priority over OCI_KEY_FILE (path)
    let pemString: String
    if let keyContent = config.string(forKey: "oci.key.content"),
      let decoded = Data(base64Encoded: keyContent),
      let decodedString = String(data: decoded, encoding: .utf8)
    {
      pemString = extractPemPrivateKeyBlock(from: decodedString) ?? decodedString
    }
    else if let keyfilePath = config.string(forKey: "oci.key.file"),
      let keyFileContents = try? String(contentsOfFile: expandTilde(keyfilePath), encoding: .utf8)
    {
      pemString = extractPemPrivateKeyBlock(from: keyFileContents) ?? keyFileContents
    }
    else {
      throw ConfigErrors.missingKeyfile
    }

    guard let privateKey = try? _RSA.Signing.PrivateKey(pemRepresentation: pemString) else { throw ConfigErrors.notPemFormat }

    return SignerConfiguration(
      name: "ENV",
      privateKey: privateKey,
      tenancyOCID: tenancyOCID,
      userOCID: userOCID,
      fingerprint: fingerprint,
      securityToken: nil,
      region: region
    )
  }

  /// Tries the OCI config file first; if it doesn't exist, falls back to a `.env` file.
  public static func resolveForAPIKey(
    configFilePath: String = "\(NSHomeDirectory())/.oci/config",
    configName: String = "DEFAULT",
    envFilePath: String = ".env"
  ) async throws -> SignerConfiguration {
    if FileManager.default.fileExists(atPath: expandTilde(configFilePath)) {
      return try fromFileForAPIKey(configFilePath: configFilePath, configName: configName)
    }
    return try await fromEnvForAPIKey(envFilePath: envFilePath)
  }
}
