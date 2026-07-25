//
//  BatchDetectHealthEntity.swift
//
//
//  Created by Ilia Sazonov on 5/7/24.
//

import Foundation
import Logging

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct BatchDetectHealthEntity {
  let urlPath = "/20221001/actions/batchDetectHealthEntities"
  let host: String
  let signer: Signer

  public init(region: Region, signer: Signer) {
    self.host = Service.language.getHost(in: region)
    self.signer = signer
  }

  public struct BatchDetectHealthEntityDetails: Codable {
    var documents: [TextDocument]
    let endpointId: String
    var isDetectAssertions: Bool = false
    var isDetectRelationships: Bool = false
    var linkOntologies: [String]?
    var profile: Profile?

    public init(documents: [TextDocument], endpointId: String, isDetectAssertions: Bool, isDetectRelationships: Bool, linkOntologies: [String]? = nil, profile: Profile? = nil) {
      self.documents = documents
      self.endpointId = endpointId
      self.isDetectAssertions = isDetectAssertions
      self.isDetectRelationships = isDetectRelationships
      self.linkOntologies = linkOntologies
      self.profile = profile
    }
  }

  public struct BatchDetectHealthEntityResult: Codable {
    var documents: [HealthEntityDocumentResult]
    var errors: [DocumentError]?
  }

  public struct HealthEntityDocumentResult: Codable {
    let entities: [HealthEntity]
    let key: String
    let languageCode: String
    let relations: [RelationEntity]?
    let resolvedEntities: ResolvedEntities
  }

  public struct HealthEntity: Codable {
    let assertions: [AssertionDetails]?
    let category: String?
    let id: String
    let length: Int
    let matchedConcepts: [MelConcept]?
    let offset: Int
    let score: Double
    let subType: String?
    let text: String
    let type: String
  }

  public struct MelConcept: Codable {
    let concepts: [MelConceptDetails]
    let ontologyName: String
  }

  public struct MelConceptDetails: Codable {
    var attributes: [String: String]?
    let id: String
    let name: String
    let score: Double
  }

  public enum APIError: Error, LocalizedError {
    case badURL

    public var errorDescription: String? {
      switch self {
      case .badURL: return "Service URL is invalid"
      }
    }
  }

  public func getHealthEntities(_ req: BatchDetectHealthEntityDetails) async throws -> BatchDetectHealthEntityResult {
    let body = try JSONEncoder().encode(req)
    guard let url = URL(string: "https://\(host)\(urlPath)") else { throw APIError.badURL }
    logger.debug("target url: \(url)")
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.httpBody = body
    try await signer.sign(&urlRequest)
    logger.debug("http request: \(urlRequest)")
    let headers = urlRequest.allHTTPHeaderFields?.values.joined(separator: "\n") ?? ""
    logger.debug("http headers: \(headers)")
    logger.debug("http request body: \(String(data: body, encoding: .utf8) ?? "")")
    let (data, _) = try await URLSession.shared.data(for: urlRequest)
    let debugString = String(data: data, encoding: .utf8) ?? ""
    logger.debug("http response: \(debugString)")
    let decoder = JSONDecoder()
    let response = try decoder.decode(BatchDetectHealthEntityResult.self, from: data)
    return response
  }
}
