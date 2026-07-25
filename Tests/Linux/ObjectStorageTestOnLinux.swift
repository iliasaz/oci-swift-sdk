//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2025 Szabolcs Tóth and the oci-swift-sdk project authors
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

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct ObjectStorageTestOnLinux {
  let ociConfigFilePath: String
  let ociProfileName: String

  // Tenancy-specific test resources, supplied by the test plan.
  let testNamespace: String
  let testBucket: String
  let testCompartmentId: String

  init() throws {
    let env = ProcessInfo.processInfo.environment
    ociConfigFilePath = env["OCI_CONFIG_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(NSHomeDirectory())/.oci/config"
    ociProfileName = env["OCI_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "DEFAULT"
    testNamespace = env["OCI_NAMESPACE"] ?? ""
    testBucket = env["OCI_BUCKET"] ?? ""
    testCompartmentId = env["OCI_COMPARTMENT_ID"] ?? ""
  }

  // MARK: - Gets namespace
  @Test("GetNamespace returns with a string. e.g.: a short opaque namespace string")
  func getsNamespaceWithAPIKeySignerReturnsValidString() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )
    let sut = try ObjectStorageClient(region: region, signer: signer)

    let namespace = try await sut.getNamespace()

    // Prints the namespace
    logger.info("The current namespace is: \(namespace)")
    #expect(!namespace.isEmpty, "Namespace should not be empty")
  }

  // MARK: - Puts object
  @Test("PutObject uploads a file with special characters in its name", .destructive)
  func putsObjectWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )
    let sut = try ObjectStorageClient(region: region, signer: signer)
    let dummyData = Data("Hello, OCI!".utf8)

    do {
      try await sut.putObject(
        namespaceName: testNamespace,
        bucketName: testBucket,
        objectName: "!@#$%^&*()_ 1.txt",
        putObjectBody: dummyData
      )

      #expect(true, "The operation should succeed")
    }
    catch {
      Issue.record("putObject threw an error: \(error)")
    }
  }

  // MARK: - Lists objects with Observable
  @Test("ListObjects returns with `name`, `size`, `timeCreated` and `timeModified`")
  func listObjectsObservableWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )
    let sut = try ObjectStorageClient(region: region, signer: signer)
    let originalObjects = ListObjects(nextStartWith: nil, objects: [], prefixes: nil)

    let receivedObjects = try await sut.listObjects(
      namespaceName: testNamespace,
      bucketName: testBucket
    )

    // Update the `originalObjects` after API execution
    originalObjects.objects = receivedObjects.objects

    // Print objects
    for object in originalObjects.objects {
      if let timeCreated = object.timeCreated, let size = object.size {
        logger.info("ID: \(object.id ), Name: \(object.name), Size: \(size), Created: \(timeCreated)")
      }
    }
    #expect(!originalObjects.objects.isEmpty, "Expected non-empty object list after API execution")
  }

  // MARK: - Lists work requests
  @Test("ListWorkRequests returns with requests in the compartment")
  func listWorkRequestsWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )
    let sut = try ObjectStorageClient(region: region, signer: signer)

    let listsWorkRequests = try? await sut.listWorkRequests(compartmentId: testCompartmentId)

    #expect(listsWorkRequests != nil, "The operation should succeed")
  }

  // MARK: - Lists buckets
  @Test("ListBuckets returns with the name of the buckets in the compartment")
  func listsBucketsWithAPIKeySignerReturnsMoreThanZero() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )
    let sut = try ObjectStorageClient(region: region, signer: signer)

    let listOfBuckets = try await sut.listBuckets(
      namespaceName: testNamespace,
      compartmentId: testCompartmentId
    )

    // Lists all buckets in the compartment
    for bucket in listOfBuckets {
      logger.info("\(bucket.name)")
    }
    #expect(
      listOfBuckets.count > 0,
      "Number of buckets should be greater than zero"
    )
  }

  // MARK: -  Deletes object
  @Test("DeleteObject deletes the specified object with name special characters", .destructive)
  func deletesObjectWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )
    let sut = try ObjectStorageClient(region: region, signer: signer)
    // 2 secomds delay before deletion
    try await Task.sleep(nanoseconds: 2_000_000_000)

    let deleteObject: Void? = try? await sut.deleteObject(
      namespaceName: testNamespace,
      bucketName: testBucket,
      objectName: "!@#$%^&*()_ 1.txt"
    )

    #expect(deleteObject != nil, "The operation should succeed")
  }
}
