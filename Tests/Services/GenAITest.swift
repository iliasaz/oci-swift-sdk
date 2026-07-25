//
//  GenAITest.swift
//  oci-swift-sdk
//
//  Created by Ilia Sazonov on 10/12/25.
//

import Foundation
import OCIKit
import Testing

struct GenAITest {
  let ociConfigFilePath: String
  let ociProfileName: String

  init() throws {
    let env = ProcessInfo.processInfo.environment
    ociConfigFilePath = env["OCI_CONFIG_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(NSHomeDirectory())/.oci/config"
    ociProfileName = env["OCI_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "DEFAULT"
  }

  @Test func testGenAICohere() async throws {
    guard
      let compartment = ProcessInfo.processInfo.environment["GENAI_COMPARTMENT_OCID"], !compartment.isEmpty,
      let modelId = ProcessInfo.processInfo.environment["GENAI_COHERE_MODEL_OCID"], !modelId.isEmpty
    else {
      logger.info("testGenAICohere not configured")
      return
    }
    let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
    let getText = GenerateText(region: .ord, signer: signer)
    let req = GenerateText.GenerateTextDetails(
      compartmentId: compartment,
      inferenceRequest: GenerateText.CohereLlmInferenceRequest(
        frequencyPenalty: nil,
        isEcho: false,
        isStream: false,
        maxTokens: nil,
        numGenerations: nil,
        presencePenalty: nil,
        prompt: "tell me about LLMs",
        returnLikelihoods: nil,
        stopSequences: nil,
        temperature: nil,
        topK: nil,
        topP: nil,
        truncate: nil
      ),
      servingMode: GenerateText.OnDemandServingMode(modelId: modelId)
    )
    let response = try await getText.getCompletion(req)
    logger.info("reponse: \(response)")
  }

  @Test func testGenAILlama() async throws {
    guard
      let compartment = ProcessInfo.processInfo.environment["GENAI_COMPARTMENT_OCID"], !compartment.isEmpty,
      let modelId = ProcessInfo.processInfo.environment["GENAI_LLAMA_MODEL_OCID"], !modelId.isEmpty
    else {
      logger.info("testGenAILlama not configured")
      return
    }
    let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
    let getText = GenerateText(region: .ord, signer: signer)
    let req = GenerateText.GenerateTextDetails(
      compartmentId: compartment,
      inferenceRequest: GenerateText.LlamaLlmInferenceRequest(
        frequencyPenalty: nil,
        isEcho: false,
        isStream: false,
        logProbs: nil,
        maxTokens: nil,
        numGenerations: nil,
        presencePenalty: nil,
        prompt: "tell me about LLMs",
        stop: nil,
        temperature: nil,
        topK: nil,
        topP: nil
      ),
      servingMode: GenerateText.OnDemandServingMode(modelId: modelId)
    )
    let response = try await getText.getCompletion(req)
    logger.info("reponse: \(response)")
  }
}
