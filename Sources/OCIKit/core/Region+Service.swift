//
//  Region+Service.swift
//
//
//  Created by Ilia Sazonov on 5/7/24.
//

import Foundation

public enum Region: String, CaseIterable, Sendable {
  case syd, mel, gru, vcp, yul, yyz, scl, vap, bog, cdg, mrs, fra, hyd, bom,
    hsg, mtz, lin, nrq, kix, nrt, qro, mty, ams, ruh, jed, beg, sin, xsp, jnb,
    icn, yny, mad, orf, arn, zrh, auh, dxb, lhr, cwl, iad, ord, phx, sjc

  var urlPart: String {
    switch self {
    case .syd: "ap-sydney-1"
    case .mel: "ap-melbourne-1"
    case .gru: "sa-saopaulo-1"
    case .vcp: "sa-vinhedo-1"
    case .yul: "ca-montreal-1"
    case .yyz: "ca-toronto-1"
    case .scl: "sa-santiago-1"
    case .vap: "sa-valparaiso-1"
    case .bog: "sa-bogota-1"
    case .cdg: "eu-paris-1"
    case .mrs: "eu-marseille-1"
    case .fra: "eu-frankfurt-1"
    case .hyd: "ap-hyderabad-1"
    case .bom: "ap-mumbai-1"
    case .hsg: "ap-batam-1"
    case .mtz: "il-jerusalem-1"
    case .lin: "eu-milan-1"
    case .nrq: "eu-turin-1"
    case .kix: "ap-osaka-1"
    case .nrt: "ap-tokyo-1"
    case .qro: "mx-queretaro-1"
    case .mty: "mx-monterrey-1"
    case .ams: "eu-amsterdam-1"
    case .ruh: "me-riyadh-1"
    case .jed: "me-jeddah-1"
    case .beg: "eu-jovanovac-1"
    case .sin: "ap-singapore-1"
    case .xsp: "ap-singapore-2"
    case .jnb: "af-johannesburg-1"
    case .icn: "ap-seoul-1"
    case .yny: "ap-chuncheon-1"
    case .mad: "eu-madrid-1"
    case .orf: "eu-madrid-3"
    case .arn: "eu-stockholm-1"
    case .zrh: "eu-zurich-1"
    case .auh: "me-abudhabi-1"
    case .dxb: "me-dubai-1"
    case .lhr: "uk-london-1"
    case .cwl: "uk-cardiff-1"
    case .iad: "us-ashburn-1"
    case .ord: "us-chicago-1"
    case .phx: "us-phoenix-1"
    case .sjc: "us-sanjose-1"
    }
  }

  public static func from(regionId: String) -> Region? {
    allCases.first { $0.urlPart == regionId }
  }
}

public enum Service: String {
  case language, objectstorage, generativeai, iam, secrets

  func getHost(in region: Region) -> String {
    switch self {
    case .language:
      "language.aiservice.\(region.urlPart).oci.oraclecloud.com"
    case .objectstorage:
      "objectstorage.\(region.urlPart).oraclecloud.com"
    case .generativeai:
      "inference.generativeai.\(region.urlPart).oci.oraclecloud.com"
    case .iam:
      "identity.\(region.urlPart).oci.oraclecloud.com"
    case .secrets:
      "secrets.vaults.\(region.urlPart).oci.oraclecloud.com"
    }
  }
}

/// Represents the individual configuration fields that can be extracted
/// from an OCI API key profile within a standard OCI configuration file.
private enum ConfigField {
  /// The region identifier (e.g., `"eu-frankfurt-1"`).
  case region

  /// The tenancy OCID associated with the profile.
  case tenancy

  /// The user OCID associated with the profile.
  case user

  /// The fingerprint of the API key.
  case fingerprint

  /// The security token value, if present.
  case securityToken
}

/// Extracts a specific configuration field from an OCI API key configuration file.
///
/// This helper loads the specified OCI config file (typically `~/.oci/config`)
/// and returns the requested field from the given profile.
/// It centralizes configuration parsing logic and ensures consistent behavior
/// across all higher‑level extractors.
///
/// - Parameters:
///   - field:
///     The configuration field to extract.
///   - configPath:
///     The filesystem path to the OCI configuration file.
///   - profile:
///     The profile name within the config file to load.
///     Defaults to `"DEFAULT"`.
///
/// - Returns:
///   The extracted value for the requested field, or `nil` if the field is not defined.
private func extract(
  _ field: ConfigField,
  from configPath: String,
  profile: String = "DEFAULT"
) throws -> String? {
  let config = try SignerConfiguration.fromFileForAPIKey(
    configFilePath: configPath,
    configName: profile
  )

  switch field {
  case .region:
    return config.region
  case .tenancy:
    return config.tenancyOCID
  case .user:
    return config.userOCID
  case .fingerprint:
    return config.fingerprint
  case .securityToken:
    return config.securityToken
  }
}

/// Extracts the user's configured OCI region from an API key configuration file.
///
/// This is a convenience wrapper around the generic `extract` helper, returning
/// only the region value for the specified profile.
///
/// - Parameters:
///   - path:
///     The filesystem path to the OCI configuration file.
///   - profile:
///     The profile name within the config file to load.
///     Defaults to `"DEFAULT"`.
///
/// - Returns:
///   The region identifier (for example, `"eu-frankfurt-1"`) if present, or `nil` otherwise.
public func extractUserRegion(from path: String, profile: String = "DEFAULT") throws -> String? {
  try extract(.region, from: path, profile: profile)
}

/// Extracts the tenancy OCID from an API key configuration file.
///
/// This helper returns the tenancy OCID associated with the given profile.
/// The tenancy OCID uniquely identifies the root compartment of the tenancy.
///
/// - Parameters:
///   - path:
///     The filesystem path to the OCI configuration file.
///   - profile:
///     The profile name within the config file to load.
///     Defaults to `"DEFAULT"`.
///
/// - Returns:
///   The tenancy OCID if present, or `nil` if the profile does not define one.
public func extractTenancyId(from path: String, profile: String = "DEFAULT") throws -> String? {
  try extract(.tenancy, from: path, profile: profile)
}
