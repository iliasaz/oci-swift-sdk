//
//  OCIKitTests.swift
//
//
//  Created by Ilia Sazonov on 5/8/24.
//

import Foundation
import XCTest
@testable import OCIKit

final class OCIKitTests: XCTestCase {
    let ociConfigFilePath = ProcessInfo.processInfo.environment["OCI_CONFIG_FILE"] ?? "/Users/<user>/.oci/config"
    let ociProfileName = ProcessInfo.processInfo.environment["OCI_PROFILE"] ?? "DEFAULT"
    
    func testConfig() async throws {
        let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
        var req = URLRequest(url: URL(string: "https://objectstorage.us-ashburn-1.oraclecloud.com/n")!)
        try signer.sign(&req)
        print(">>> All Headers: >>> \n\(req.allHTTPHeaderFields)\n>>>>>>>>\n")
        
        let (data, _) = try await URLSession.shared.data(for: req)
        let response = String(data: data, encoding: .utf8)
        print("reponse: \(response)")
    }
    
    func testHealthNER() async throws {
        let endpoint = ProcessInfo.processInfo.environment["HEALTH_NER_ENDPOINT"] ?? "none"
        let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
        let healthNER = BatchDetectHealthEntity(region: .iad, signer: signer)
        var req = BatchDetectHealthEntity.BatchDetectHealthEntityDetails(
            documents: [TextDocument(
                key: UUID().uuidString,
                languageCode: "en",
                text: "lung cancer"
            )],
            endpointId: endpoint
        )
        let response = try await healthNER.getHealthEntities(req)
        print("reponse: \(response)")
    }
    
    func testGenAICohere() async throws {
        let compartment = ProcessInfo.processInfo.environment["GENAI_COMPARTMENT_OCID"] ?? "none"
        let modelId = ProcessInfo.processInfo.environment["GENAI_COHERE_MODEL_OCID"] ?? "none"
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
        print("reponse: \(response)")
    }
    
    func testGenAILlama() async throws {
        let compartment = ProcessInfo.processInfo.environment["GENAI_COMPARTMENT_OCID"] ?? "none"
        let modelId = ProcessInfo.processInfo.environment["GENAI_LLAMA_MODEL_OCID"] ?? "none"
        let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
        let getText = GenerateText(region: .ord, signer: signer)
        let req = GenerateText.GenerateTextDetails(
            compartmentId: compartment,
            inferenceRequest: GenerateText.LlamaLlmInferenceRequest(
                frequencyPenalty: nil,
                isEcho: false,
                isStream: false,
                logProbs: nil, maxTokens: nil,
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
        print("reponse: \(response)")
    }
}
