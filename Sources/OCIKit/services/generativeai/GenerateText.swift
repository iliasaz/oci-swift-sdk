//
//  GenerateText.swift
//
//
//  Created by Ilia Sazonov on 5/8/24.
//

import Foundation
import Logging

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct GenerateText {
  let urlPath = "/20231130/actions/generateText"
  let host: String
  let signer: Signer

  public init(region: Region, signer: Signer) {
    self.host = Service.generativeai.getHost(in: region)
    self.signer = signer
  }

  public protocol LlmInferenceRequest: Encodable {
    var runtimeType: String { get }
    var frequencyPenalty: Int? { get }
    var isEcho: Bool { get }
    var isStream: Bool? { get }
    var maxTokens: Int? { get }
    var numGenerations: Int? { get }
    var presencePenalty: Int? { get }
    var prompt: String { get }
    var temperature: Double? { get }
    var topK: Int? { get }
    var topP: Double? { get }
  }

  public protocol ServingMode: Encodable {
    var servingType: String { get }
  }

  public struct GenerateTextDetails: Encodable {
    let compartmentId: String
    let inferenceRequest: LlmInferenceRequest
    let servingMode: ServingMode

    public init(compartmentId: String, inferenceRequest: LlmInferenceRequest, servingMode: ServingMode) {
      self.compartmentId = compartmentId
      self.inferenceRequest = inferenceRequest
      self.servingMode = servingMode
    }

    enum CodingKeys: String, CodingKey {
      case compartmentId, inferenceRequest, servingMode
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(compartmentId, forKey: .compartmentId)

      // Encoding the inferenceRequest based on its runtime type
      switch inferenceRequest {
      case let cohereRequest as CohereLlmInferenceRequest:
        try container.encode(cohereRequest, forKey: .inferenceRequest)
      case let llamaRequest as LlamaLlmInferenceRequest:
        try container.encode(llamaRequest, forKey: .inferenceRequest)
      default:
        throw EncodingError.invalidValue(inferenceRequest, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported type of LlmInferenceRequest"))
      }

      // Encoding the servingMode based on its runtime type
      switch servingMode {
      case let dedicated as DedicatedServingMode:
        try container.encode(dedicated, forKey: .servingMode)
      case let onDemand as OnDemandServingMode:
        try container.encode(onDemand, forKey: .servingMode)
      default:
        throw EncodingError.invalidValue(inferenceRequest, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported type of ServingMode"))
      }
    }
  }

  public struct CohereLlmInferenceRequest: LlmInferenceRequest {
    public let runtimeType = "COHERE"
    public let frequencyPenalty: Int?
    public let isEcho: Bool
    public let isStream: Bool?
    public let maxTokens: Int?
    public let numGenerations: Int?
    public let presencePenalty: Int?
    public let prompt: String
    public let returnLikelihoods: String?
    public let stopSequences: [String]?
    public let temperature: Double?
    public let topK: Int?
    public let topP: Double?
    let truncate: String?

    public init(
      frequencyPenalty: Int?,
      isEcho: Bool,
      isStream: Bool?,
      maxTokens: Int?,
      numGenerations: Int?,
      presencePenalty: Int?,
      prompt: String,
      returnLikelihoods: String?,
      stopSequences: [String]?,
      temperature: Double?,
      topK: Int?,
      topP: Double?,
      truncate: String?
    ) {
      self.frequencyPenalty = frequencyPenalty
      self.isEcho = isEcho
      self.isStream = isStream
      self.maxTokens = maxTokens
      self.numGenerations = numGenerations
      self.presencePenalty = presencePenalty
      self.prompt = prompt
      self.returnLikelihoods = returnLikelihoods
      self.stopSequences = stopSequences
      self.temperature = temperature
      self.topK = topK
      self.topP = topP
      self.truncate = truncate
    }
  }

  public struct LlamaLlmInferenceRequest: LlmInferenceRequest {
    public let runtimeType = "LLAMA"
    public let frequencyPenalty: Int?
    public let isEcho: Bool
    public let isStream: Bool?
    public let logProbs: Int?
    public let maxTokens: Int?
    public let numGenerations: Int?
    public let presencePenalty: Int?
    public let prompt: String
    public let stop: [String]?
    public let temperature: Double?
    public let topK: Int?
    public let topP: Double?

    public init(
      frequencyPenalty: Int?,
      isEcho: Bool,
      isStream: Bool?,
      logProbs: Int?,
      maxTokens: Int?,
      numGenerations: Int?,
      presencePenalty: Int?,
      prompt: String,
      stop: [String]?,
      temperature: Double?,
      topK: Int?,
      topP: Double?
    ) {
      self.frequencyPenalty = frequencyPenalty
      self.isEcho = isEcho
      self.isStream = isStream
      self.logProbs = logProbs
      self.maxTokens = maxTokens
      self.numGenerations = numGenerations
      self.presencePenalty = presencePenalty
      self.prompt = prompt
      self.stop = stop
      self.temperature = temperature
      self.topK = topK
      self.topP = topP
    }
  }

  public struct DedicatedServingMode: ServingMode {
    public let servingType = "DEDICATED"
    let endpointId: String

    public init(endpointId: String) {
      self.endpointId = endpointId
    }
  }

  public struct OnDemandServingMode: ServingMode {
    public let servingType = "ON_DEMAND"
    public let modelId: String

    public init(modelId: String) {
      self.modelId = modelId
    }
  }

  public struct GenerateTextResult: Decodable {
    public let inferenceResponse: LlmInferenceResponse
    public let modelId: String
    public let modelVersion: String

    enum CodingKeys: String, CodingKey {
      case inferenceResponse
      case modelId
      case modelVersion
    }

    enum InferenceResponseCodingKeys: String, CodingKey {
      case runtimeType
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      modelId = try container.decode(String.self, forKey: .modelId)
      modelVersion = try container.decode(String.self, forKey: .modelVersion)

      // Peek into the inferenceResponse to extract runtimeType
      let nestedContainer = try container.nestedContainer(keyedBy: InferenceResponseCodingKeys.self, forKey: .inferenceResponse)
      let runtimeType = try nestedContainer.decode(String.self, forKey: InferenceResponseCodingKeys.runtimeType)

      // now decoding the response based on its type
      switch runtimeType {
      case "COHERE":
        inferenceResponse = try CohereLlmInferenceResponse(from: container.superDecoder(forKey: .inferenceResponse))
      case "LLAMA":
        inferenceResponse = try LlamaLlmInferenceResponse(from: container.superDecoder(forKey: .inferenceResponse))
      default:
        throw DecodingError.dataCorruptedError(forKey: InferenceResponseCodingKeys.runtimeType, in: nestedContainer, debugDescription: "Unsupported runtimeType \(runtimeType)")
      }
    }
  }

  public protocol LlmInferenceResponse: Decodable {
    var runtimeType: String { get }
  }

  public struct CohereLlmInferenceResponse: LlmInferenceResponse {
    public let runtimeType: String
    public let generatedTexts: [GeneratedText]
    public let prompt: String?
    public let timeCreated: String
  }

  public struct GeneratedText: Codable {
    public let finishReason: String?
    public let id: String
    public let likelihood: Double?
    public let text: String
    public let tokenLikelihoods: [TokenLikelihood]?
  }

  public struct TokenLikelihood: Codable {
    public let likelihood: Double?
    public let token: String?
  }

  public struct LlamaLlmInferenceResponse: LlmInferenceResponse {
    public let runtimeType: String
    public let choices: [Choice]
    public let created: String
  }

  public struct Choice: Codable {
    public let finishReason: String?
    public let index: Int
    public let logprobs: Logprobs?
    public let text: String
  }

  public struct Logprobs: Codable {
    public let textOffset: [Int]?
    public let tokenLogprobs: [Double]?
    public let tokens: [String]?
    public let topLogprobs: [Double]?
  }

  public enum APIError: Error, LocalizedError {
    case badURL

    public var errorDescription: String? {
      switch self {
      case .badURL: return "Service URL is invalid"
      }
    }
  }

  public func getCompletion(_ req: GenerateTextDetails) async throws -> GenerateTextResult {
    let body = try JSONEncoder().encode(req)
    guard let url = URL(string: "https://\(host)\(urlPath)") else { throw APIError.badURL }
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
    let response = try decoder.decode(GenerateTextResult.self, from: data)
    return response
  }
}
