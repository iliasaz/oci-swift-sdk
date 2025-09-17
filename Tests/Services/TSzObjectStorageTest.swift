//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2025 Szabolcs Toth and the oci-swift-sdk project authors
// Licensed under MIT License
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of oci-swift-sdk project authors
//
// SPDX-License-Identifier: MIT License
//
//===----------------------------------------------------------------------===//

import Foundation
import OCIKit
import Testing

struct TSzObjectStorageTest {
    let ociConfigFilePath: String
    let ociProfileName: String
    
    init() {
        let env = ProcessInfo.processInfo.environment
        ociConfigFilePath = env["OCI_CONFIG_FILE"] ?? "\(NSHomeDirectory())/.oci/config"
        ociProfileName = env["OCI_PROFILE"] ?? "DEFAULT"
    }
    
    // MARK: - Creates bucket
    @Test func createsBucketWithAPIKeySigner() async throws {
        let regionId = try extractUserRegion(from: ociConfigFilePath, profile: ociProfileName)
        let region = Region.from(regionId: regionId ?? "") ?? .iad
        let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
        let sut = try TSzObjectStorageClient(region: region, signer: signer)
        let bucket = CreateBucketDetails(compartmentId: "ocid1.compartment.oc1..aaaaaaaatcmi2vv2tmuzgpajfncnqnvwvzkg2at7ez5lykdcarwtbeieyo2q",
                                         name: "test_bucket_by_sdk")
       
        let createBucket = try await sut.createBucket(namespaceName: "frjfldcyl3la", bucket: bucket)
        
        // Prints the name of the new bucket
        if let createBucket {
            print(createBucket.name)
        }
        
        #expect(createBucket != nil, "The return value should not be nil")
    }
    
    // MARK: - Get bucket
    @Test func getsBucketWithAPIKeySigner() async throws {
        let regionId = try extractUserRegion(from: ociConfigFilePath, profile: ociProfileName)
        let region = Region.from(regionId: regionId ?? "") ?? .iad
        let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
        let sut = try TSzObjectStorageClient(region: region, signer: signer)
    
        let createBucket = try await sut.getBucket(namespaceName: "frjfldcyl3la", bucketName: "test_bucket_by_sdk")
        
        // Prints the name of the new bucket
        if let createBucket {
            print("The bucket: \(createBucket.name) is in the compartment: \(createBucket.compartmentId), created by: \(createBucket.createdBy)")
        }
        
        #expect(createBucket != nil, "The return value should not be nil")
    }
    
    // MARK: - Gets namespace
    @Test func getNamespaceWithAPIKeySignerReturnsValidString() async throws {
        let regionId = try extractUserRegion(from: ociConfigFilePath, profile: ociProfileName)
        let region = Region.from(regionId: regionId ?? "") ?? .iad
        let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
        let sut = try TSzObjectStorageClient(region: region, signer: signer)
        
        let namespace = try await sut.getNamespace()
        
        #expect(!namespace.isEmpty, "Namespace should not be empty")
    }
    
    @Test func getNamespaceWithAPIKeySignerAndCompartmentIdReturnsValidString() async throws {
        let regionId = try extractUserRegion(from: ociConfigFilePath, profile: ociProfileName)
        let region = Region.from(regionId: regionId ?? "") ?? .iad
        let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
        let sut = try TSzObjectStorageClient(region: region, signer: signer)
        
        let namespace = try await sut.getNamespace(compartmentId: "ocid1.tenancy.oc1..aaaaaaaapt3esrvwldrfekea5ucasigr2nof7tjx6ysyb4oo3yiqgx2d72ha")
        
        #expect(!namespace.isEmpty, "Namespace should not be empty")
    }
    
    // MARK: - Lists buckets
    /// Creates bucket must be proceed.
    @Test func listBucketsWithAPIKeySignerReturnsMoreThanZero() async throws {
        let regionId = try extractUserRegion(from: ociConfigFilePath, profile: ociProfileName)
        let region = Region.from(regionId: regionId ?? "") ?? .iad
        let signer = try APIKeySigner(configFilePath: ociConfigFilePath, configName: ociProfileName)
        let sut = try TSzObjectStorageClient(region: region, signer: signer)
        
        let listOfBuckets = try await sut.listBuckets(namespaceName: "frjfldcyl3la", compartmentId: "ocid1.compartment.oc1..aaaaaaaatcmi2vv2tmuzgpajfncnqnvwvzkg2at7ez5lykdcarwtbeieyo2q")
        
        // Lists all buckets in the compartment
        for bucket in listOfBuckets {
            print(bucket.name)
        }
        
        #expect(listOfBuckets.count > 0, "Number of buckets should be greater than zero")
    }
}
