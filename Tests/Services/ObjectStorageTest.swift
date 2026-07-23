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
import Logging
import Testing

@testable import OCIKit

@Suite(.enabled(if: destructiveTestsEnabled, Comment(rawValue: destructiveTestsSkipComment)))
struct ObjectStorageTest {
  // `LoggingSystem.bootstrap` is a process-wide, call-once gate. Swift Testing
  // makes a fresh suite instance per `@Test`, so bootstrapping in `init()`
  // directly trips the precondition on the second test. A `static let` runs the
  // bootstrap exactly once per process (thread-safe), so re-running `init()` is
  // safe.
  private static let bootstrapLogging: Void = {
    LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
  }()

  let ociConfigFilePath: String
  let ociProfileName: String

  // Tenancy-specific test resources, supplied by the test plan.
  // See docs/live-tests.md and oci-swift-sdk-Package.xctestplan.template.
  let testNamespace: String
  let testNamespace2: String
  let testBucket: String
  let testReplicaBucket: String
  let testParBucket: String
  let testCopyDestBucket: String
  let testObject: String
  let testObjectSvg: String
  let testObjectTxt: String
  let testUploadFilePath: String
  let testDestRegion: String
  let testCompartmentId: String
  let testTenancyId: String
  let testMetadataCompartmentId: String
  // Per-resource identifiers: these change whenever the resource is recreated.
  let testParURLRead: String
  let testParURLWrite: String
  let testParIdGet: String
  let testParId: String
  let testObjectVersionId: String
  let testReplicationId: String
  let testRetentionRuleIdGet: String
  let testRetentionRuleIdDelete: String
  let testRetentionRuleIdUpdate: String

  init() throws {
    _ = Self.bootstrapLogging
    let env = ProcessInfo.processInfo.environment
    ociConfigFilePath = env["OCI_CONFIG_FILE"] ?? "\(NSHomeDirectory())/.oci/config"
    ociProfileName = env["OCI_PROFILE"] ?? "DEFAULT"
    testNamespace = env["OCI_NAMESPACE"] ?? ""
    testNamespace2 = env["OCI_OS_NAMESPACE_2"] ?? ""
    testBucket = env["OCI_BUCKET"] ?? ""
    testReplicaBucket = env["OCI_OS_REPLICA_BUCKET"] ?? ""
    testParBucket = env["OCI_OS_PAR_BUCKET"] ?? ""
    testCopyDestBucket = env["OCI_OS_COPY_DEST_BUCKET"] ?? ""
    testObject = env["OCI_OBJECT"] ?? ""
    testObjectSvg = env["OCI_OS_OBJECT_SVG"] ?? ""
    testObjectTxt = env["OCI_OS_OBJECT_TXT"] ?? ""
    testUploadFilePath = env["OCI_OS_UPLOAD_FILE"] ?? ""
    testDestRegion = env["OCI_OS_DEST_REGION"] ?? ""
    testCompartmentId = env["OCI_COMPARTMENT_ID"] ?? ""
    testTenancyId = env["OCI_TENANCY_ID"] ?? ""
    testMetadataCompartmentId = env["OCI_OS_METADATA_COMPARTMENT_ID"] ?? ""
    testParURLRead = env["OCI_OS_PAR_URL_READ"] ?? ""
    testParURLWrite = env["OCI_OS_PAR_URL_WRITE"] ?? ""
    testParIdGet = env["OCI_OS_PAR_ID_GET"] ?? ""
    testParId = env["OCI_OS_PAR_ID"] ?? ""
    testObjectVersionId = env["OCI_OS_OBJECT_VERSION_ID"] ?? ""
    testReplicationId = env["OCI_OS_REPLICATION_ID"] ?? ""
    testRetentionRuleIdGet = env["OCI_OS_RETENTION_RULE_ID_GET"] ?? ""
    testRetentionRuleIdDelete = env["OCI_OS_RETENTION_RULE_ID_DELETE"] ?? ""
    testRetentionRuleIdUpdate = env["OCI_OS_RETENTION_RULE_ID_UPDATE"] ?? ""
  }

  // MARK: - Copies object
  /// This test fails with `400` for unknown reason.
  /// "code": "InsufficientServicePermissions",
  ///  "message": "Permissions granted to the object storage service principal \"objectstorage-eu-frankfurt-1\" to this bucket are insufficient."
  ///  "See [documentation](https://docs.oracle.com/iaas/Content/API/References/apierrors.htm) for more information about resolving this error. If you are unable to resolve this issue, run this CLI command with --debug option and contact Oracle support and provide them the full error message."
  @Test func copiesObjectWithinRegionWithAPIKeySigner() async throws {
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
    let object = CopyObjectDetails(
      destinationBucket: testCopyDestBucket,
      destinationNamespace: testNamespace,
      destinationObjectName: testObject,
      destinationRegion: testDestRegion,
      sourceObjectName: testObject
    )

    let copyObject: Void? = try? await sut.copyObject(
      namespaceName: testNamespace,
      bucketName: testBucket,
      copyObjectDetails: object
    )

    #expect(copyObject != nil, "The return value should not be nil")
  }

  // MARK: - Creates bucket
  @Test func createsBucketWithAPIKeySigner() async throws {
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

    let bucketDetails = CreateBucketDetails(
      compartmentId: testCompartmentId,
      name: testBucket
    )

    let bucket = try await sut.createBucket(
      namespaceName: testNamespace,
      createBucketDetails: bucketDetails
    )

    // Prints the name of the new bucket
    logger.info("Created bucket: \(bucket.name)")

    #expect(bucket.name == testBucket, "Bucket name should match the requested one")
  }

  // MARK: - Creates archieve bucket
  @Test func createsArchiveBucketWithAPIKeySigner() async throws {
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
    let bucketDetails = CreateBucketDetails(
      compartmentId: testCompartmentId,
      name: "archive_test_bucket_by_sdk",
      storageTier: StorageTier.archive
    )

    let bucket = try await sut.createBucket(
      namespaceName: testNamespace,
      createBucketDetails: bucketDetails
    )

    // Prints the name of the new bucket
    logger.info("Created bucket: \(bucket.name)")

    #expect(bucket.name == "archive_test_bucket_by_sdk", "Bucket name should match the requested one")
  }

  // MARK: - Creates replication policy
  /// `Allow service objectstorage-eu-frankfurt-1 to manage object-family in compartment your_comparment_name`
  /// Always Free Tier allows only one policy
  @Test func createsReplicationPolicyWithAPIKeySigner() async throws {
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

    let policyDetails = CreateReplicationPolicyDetails(
      destinationBucketName: testReplicaBucket,
      destinationRegionName: testDestRegion,
      name: "Test_policy"
    )

    let createReplicationPolicy = try await sut.createReplicationPolicy(
      namespaceName: testNamespace,
      bucketName: testBucket,
      policyDetails: policyDetails
    )

    #expect(createReplicationPolicy.name == "Test_policy", "Policy name should match the requested one")
  }

  // MARK: - Creates retention rule
  /// If the bucket versioning is enabled, you cannot add retention policy.
  /// `timeRuleLocked` must be at least 14 days ahead of the current time.`
  @Test func createsRetentionRuleWithAPIKeySigner() async throws {
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

    let twentyTwoDaysFromNow = Calendar.current.date(byAdding: .day, value: 22, to: Date.now)
    let ruleDetails = CreateRetentionRuleDetails(
      displayName: "Test_retention_by_SDK",
      duration: Duration(timeAmount: 10, timeUnit: TimeUnit.days),
      timeRuleLocked: twentyTwoDaysFromNow
    )

    let createRetentionRule = try? await sut.createRetentionRule(
      namespaceName: testNamespace,
      bucketName: testBucket,
      ruleDetails: ruleDetails
    )

    // Prints rule
    if let rule = createRetentionRule {
      logger.info("You applied rule: \(rule.displayName).")
    }
    #expect(createRetentionRule != nil, "The operation should succeed")
  }

  // MARK: - Creates preauthenticated request for read/write and list entire bucket
  @Test("Creating preauthenticated request for entire bucket and return with the link")
  func createsPreauthenticatedRequestWithAPIKeySigner() async throws {
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

    let requestDetails = CreatePreauthenticatedRequestDetails(
      accessType: AccessType.anyObjectReadWrite,
      bucketListingAction: .listObjects,
      name: "PAR request for entire bucket",
      timeExpires: "2025-12-31T23:59:59Z"
    )

    let createPreauthenticatedRequest = try? await sut.createPreauthenticatedRequest(
      namespaceName: testNamespace,
      bucketName: testParBucket,
      requestDetails: requestDetails
    )

    if let createPreauthenticatedRequest {
      let host = Service.objectstorage.getHost(in: region)
      logger.info("\(host + createPreauthenticatedRequest.accessUri)")
    }
    #expect(createPreauthenticatedRequest != nil, "The operation should succeed")
  }

  @Test("Creating preauthenticated read only request for one file in bucket only and return with the link")
  func createsPreauthenticatedRequestReadOnlyWithAPIKeySigner() async throws {
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

    let requestDetails = CreatePreauthenticatedRequestDetails(
      accessType: AccessType.objectRead,
      name: "PAR read only request for Frame.png",
      objectName: testObject,
      timeExpires: "2025-12-31T23:59:59Z"
    )

    let createPreauthenticatedRequest = try? await sut.createPreauthenticatedRequest(
      namespaceName: testNamespace,
      bucketName: testParBucket,
      requestDetails: requestDetails
    )

    if let createPreauthenticatedRequest {
      let host = Service.objectstorage.getHost(in: region)
      logger.info("\(host + createPreauthenticatedRequest.accessUri)")
    }
    #expect(createPreauthenticatedRequest != nil, "The operation should succeed")
  }

  // MARK: - Deletes bucket
  @Test func deletesBucketWithAPIKeySigner() async throws {
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

    let deleteBucket: Void? = try? await sut.deleteBucket(
      namespaceName: testNamespace,
      bucketName: testBucket
    )

    #expect(deleteBucket != nil, "The operation should succeed")
  }

  // MARK: -  Deletes object
  @Test func deletesObjectWithAPIKeySigner() async throws {
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

    let deleteObject: Void? = try? await sut.deleteObject(
      namespaceName: testNamespace,
      bucketName: testBucket,
      objectName: testObject
    )

    #expect(deleteObject != nil, "The operation should succeed")
  }

  @Test func deletesObjectWithVersionIdWithAPIKeySigner() async throws {
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

    let deleteObject: Void? = try? await sut.deleteObject(
      namespaceName: testNamespace,
      bucketName: testBucket,
      objectName: testObjectSvg,
      versionId: testObjectVersionId
    )

    #expect(deleteObject != nil, "The operation should succeed")
  }

  // MARK: - Deletes replication policy
  @Test func deletesReplicationPolicyWithAPIKeySigner() async throws {
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

    let deleteReplicationPolicy: Void? = try? await sut.deleteReplicationPolicy(
      namespaceName: testNamespace,
      bucketName: testBucket,
      replicationId: testReplicationId
    )

    #expect(deleteReplicationPolicy != nil, "The operation should succeed")
  }

  // MARK: - Deletes retention rule
  @Test func deletesRetentionRuleWithAPIKeySigner() async throws {
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

    let deleteRetentionRule: Void? = try? await sut.deleteRetentionRule(
      namespaceName: testNamespace,
      bucketName: testBucket,
      retentionRuleId: testRetentionRuleIdDelete
    )

    #expect(deleteRetentionRule != nil, "The operation should succeed")
  }

  // MARK: - Deletes preauthenticated request
  @Test func deletesPreauthenticatedRequestWithAPIKeySigner() async throws {
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

    let deletePreauthRequest: Void? = try await sut.deletePreauthenticatedRequest(
      namespaceName: testNamespace,
      bucketName: testBucket,
      parId: testParId  // <-- replace with valid PAR ID
    )

    #expect(deletePreauthRequest != nil, "The operation should succeed")
  }

  // MARK: - Gets bucket
  @Test func getsBucketWithAPIKeySigner() async throws {
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

    let getBucket = try? await sut.getBucket(
      namespaceName: testNamespace,
      bucketName: testBucket
    )

    // Prints the name of the bucket
    if let getBucket {
      logger.info("The bucket: \(getBucket.name) is in the compartment: \(getBucket.compartmentId), created by: \(getBucket.createdBy)")
    }

    #expect(getBucket != nil, "The return value should not be nil")
  }

  // MARK: - Gets namespace
  @Test func getsNamespaceWithAPIKeySignerReturnsValidString() async throws {
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

  @Test func gestNamespaceWithAPIKeySignerAndCompartmentIdReturnsValidString() async throws {
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

    let namespace = try await sut.getNamespace(
      compartmentId: testTenancyId
    )

    #expect(!namespace.isEmpty, "Namespace should not be empty")
  }

  // MARK: - Gets namespace metadata
  /// `{
  ///   "data": {
  ///       "default-s3-compartment-id": "ocid1.tenancy.oc1..EXAMPLE",
  ///       "default-swift-compartment-id": "ocid1.tenancy.oc1..EXAMPLE",
  ///       "namespace": "EXAMPLENAMESPACE"
  ///    }
  /// }`
  @Test func getsNamespaceMetadataWithAPIKeySigner() async throws {
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

    let getNamespaceMetadata = try? await sut.getNamespaceMetadata(
      namespaceName: testNamespace
    )

    // Prints metadata
    if let metadata = getNamespaceMetadata {
      logger.info("default-swift-compartment-id: \(metadata.defaultSwiftCompartmentId), \ndefault-s3-compartment-id: \(metadata.defaultS3CompartmentId), \nnamespace: \(metadata.namespace)")
    }
    #expect(getNamespaceMetadata != nil, "The operation should succeed")
  }

  // MARK: - Gets object
  @Test func getsObjectWithAPIKeySigner() async throws {
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

    let getObject = try? await sut.getObject(namespaceName: testNamespace, bucketName: testBucket, objectName: testObjectSvg)

    #expect(getObject != nil, "The operation should succeed")
  }

  // MARK: - Gets object from PAR bucket
  @Test func getsObjectWithPAR() async throws {
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

    let getObject = try? await sut.getObject(
      parURL: URL(string: testParURLRead)!,
      objectName: testObjectTxt
    )
    logger.info("downloaded object size: \(getObject?.count ?? -1)")
    #expect(getObject != nil, "The operation should succeed")
  }

  // MARK: - Gets object integrity check
  @Test func getsObjectWithAPIKeySignerAndIntegrityCheck() async throws {
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

    let getObject = try await sut.getObject(namespaceName: testNamespace2, bucketName: testBucket, objectName: testObjectTxt, withObjectIntegrityCheck: true)

    #expect(getObject.count == 12, "The operation should succeed")
  }

  // MARK: - Gets replication policy
  @Test func getsReplicationPolicyWithAPIKeySigner() async throws {
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

    let getReplicationPolicy: ReplicationPolicy? = try await sut.getReplicationPolicy(
      namespaceName: testNamespace,
      bucketName: testBucket,
      replicationId: testReplicationId
    )

    // Print policy details
    if let policy = getReplicationPolicy {
      logger.info("id: \(policy.id) - name: \(policy.name)")
    }
    #expect(getReplicationPolicy != nil, "The operation should succeed")
  }

  // MARK: - Get preauthenticated request
  @Test func getPreauthenticatedRequestWithAPIKeySigner() async throws {
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

    let getPreauthenticatedRequest = try? await sut.getPreauthenticatedRequest(
      namespaceName: testNamespace,
      bucketName: testBucket,
      parId: testParIdGet
    )

    #expect(getPreauthenticatedRequest != nil, "The operation should succeed")
  }

  // MARK: - Gets retention rule
  @Test func getRetentionRuleWithAPIKeySigner() async throws {
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

    let getRetentionRule: RetentionRule? = try? await sut.getRetentionRule(
      namespaceName: testNamespace,
      bucketName: testBucket,
      retentionRuleId: testRetentionRuleIdGet
    )

    // Prints retention rule
    if let rule = getRetentionRule {
      if let timeCreated = rule.timeCreated {
        logger.info("id: \(rule.id) - name: \(rule.displayName) on \(timeCreated)")
      }
    }
    #expect(getRetentionRule != nil, "The operation should succeed")
  }

  // MARK: - Heads bucket
  @Test func headsBucketWithAPIKeySigner() async throws {
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

    let headBucket: Void? = try? await sut.headBucket(
      namespaceName: testNamespace,
      bucketName: testBucket
    )

    #expect(headBucket != nil, "The operation should succeed")
  }

  // MARK: - Lists buckets
  /// Lists buckets in the compartment
  @Test func listsBucketsWithAPIKeySignerReturnsMoreThanZero() async throws {
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

  // MARK: - Lists buckets
  /// List buckets in the compartment using `limit`
  @Test func listsBucketsWithLimitWithAPIKeySignerReturnsMoreThanZero() async throws {
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
      compartmentId: testCompartmentId,
      limit: 2
    )

    // Lists all buckets in the compartment
    for bucket in listOfBuckets {
      logger.info("\(bucket.name)")
    }
    #expect(
      listOfBuckets.count < 3,
      "Number of buckets should be between 0 and 2"
    )
  }

  // MARK: - List replication policies
  @Test func listReplicationPoliciesWithAPIKeySigner() async throws {
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

    let listReplicationPolicies = try? await sut.listReplicationPolicies(
      namespaceName: testNamespace,
      bucketName: testBucket,
      limit: 10
    )

    // Print polices
    if let policies = listReplicationPolicies {
      for policy in policies {
        logger.info("id: \(policy.id) - name: \(policy.name)")
      }
    }
    #expect(listReplicationPolicies != nil, "The operation should succeed")
  }

  // MARK: - List replication resources
  /// At least one replication policy is required on the queried bucket
  @Test func listReplicationResourcesWithAPIKeySigner() async throws {
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

    let listReplicationResources = try? await sut.listReplicationPolicies(
      namespaceName: testNamespace,
      bucketName: testBucket,
      limit: 10
    )

    // Print resources
    if let resources = listReplicationResources {
      for resource in resources {
        logger.info("id: \(resource.id) - name: \(resource.name) - destination: \(resource.destinationBucketName)")
      }
    }
    #expect(listReplicationResources != nil, "The operation should succeed")
  }

  // MARK: - List retention rules
  @Test func listRetentionRulesWithAPIKeySigner() async throws {
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

    let listRetentionRules = try? await sut.listRetentionRules(
      namespaceName: testNamespace,
      bucketName: testBucket
    )

    // Prints rules
    if let rules = listRetentionRules {

      for rule in rules.items {
        if let timeCreated = rule.timeCreated {
          logger.info("- id: \(rule.id) name: \(rule.displayName) on \(timeCreated)")
        }
      }
    }
    #expect(listRetentionRules != nil, "The operation should succeed")
  }

  // MARK: - List objects
  // Returning with `name`, `size`, `timeCreated` and `timeModified`
  @Test func listObjectsWithAPIKeySigner() async throws {
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

    let listOfObjects = try? await sut.listObjects(
      namespaceName: testNamespace,
      bucketName: testBucket
    )

    // Print objects
    if let objects = listOfObjects {
      for object in objects.objects {
        if let timeCreated = object.timeCreated, let size = object.size {
          logger.info("The name of the file: \(object.name), size: \(size) on \(timeCreated)")
        }
      }
    }
    #expect(listOfObjects != nil, "The operation should succeed")
  }

  // Returning with `name`, `size`, `etag`, `timeCreated`, `md5`,`timeModified`, `storageTier` and  `archivalState`
  @Test func listObjectsFullFieldsWithAPIKeySigner() async throws {
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

    let listOfObjects = try? await sut.listObjects(
      namespaceName: testNamespace,
      bucketName: testBucket,
      fields: Field.allCases
    )

    // Print objects
    if let objectsInBucket = listOfObjects {
      for object in objectsInBucket.objects {
        if let size = object.size, let timeCreated = object.timeCreated, let md5 = object.md5, let storageTier = object.storageTier {
          logger.info("Name: \(object.name), size: \(size), created on: \(timeCreated), md5: \(md5), storageTier: \(storageTier)")
        }
      }
    }
    #expect(listOfObjects != nil, "The operation should succeed")
  }

  // Returning with the default values: `name`, `size`, `timeCreated`,`timeModified`
  // additionally with `md5`
  @Test func listObjectsCustomFieldsWithAPIKeySigner() async throws {
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

    let listOfObjects = try? await sut.listObjects(
      namespaceName: testNamespace,
      bucketName: testBucket,
      fields: [.md5]
    )

    // Print objects
    if let objectsInBucket = listOfObjects {
      for object in objectsInBucket.objects {
        if let size = object.size, let timeCreated = object.timeCreated, let timeModified = object.timeModified, let md5 = object.md5 {
          logger.info("Name: \(object.name), size: \(size), created on: \(timeCreated), modified: \(timeModified) and md5: \(md5)")
        }
      }
    }
    #expect(listOfObjects != nil, "The operation should succeed")
  }

  // Returning with `name`, `size`, `timeCreated` and `timeModified` using PAR
  @Test func listObjectsWithPAR() async throws {
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

    let listOfObjects = try? await sut.listObjects(
      parURL: URL(string: testParURLRead)!,
      limit: 10
    )

    // Print objects
    if let objectsInBucket = listOfObjects {
      for object in objectsInBucket.objects {
        if let size = object.size, let timeCreated = object.timeCreated {
          logger.info("Name: \(object.name), size: \(size), created on: \(timeCreated)")
        }
      }
    }
    #expect(listOfObjects != nil, "The operation should succeed")
  }

  // MARK: - Lists object versions
  @Test func listObjectVersionsWithAPIKeySigner() async throws {
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

    // Allowed values are: name (default), size, etag, timeCreated, md5, timeModified, storageTier, archivalState
    let fields: [Field] = [.name, .size, .md5]
    let fieldsString = fields.map { $0.rawValue }.joined(separator: ",")
    let listOfObjectVersions = try? await sut.listObjectVersions(
      namespaceName: testNamespace,
      bucketName: testBucket,
      fields: fieldsString
    )

    // Prints versions
    if let versions = listOfObjectVersions?.items {
      for version in versions {
        logger.info("File: \(version.name), size: \(version.size ?? 0), md5: \(version.md5 ?? "") and version: \(version.versionId)")
      }
    }
    #expect(listOfObjectVersions != nil, "The operation should succeed")
  }

  // MARK: - Makes bucket writable
  @Test func makeBucketWritableWithAPIKeySigner() async throws {
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

    let makeBucketWritable: ()? = try? await sut.makeBucketWritable(namespaceName: testNamespace, bucketName: testReplicaBucket)

    #expect(makeBucketWritable != nil, "The operation should succeed")
  }

  // MARK: - Lists preauthenticated requests
  @Test func listPreauthenticatedRequestsWithAPIKeySigner() async throws {
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

    let makeBucketWritable: ()? = try? await sut.makeBucketWritable(namespaceName: testNamespace, bucketName: testReplicaBucket)

    #expect(makeBucketWritable != nil, "The operation should succeed")
  }

  // MARK: - Puts object
  @Test func putsObjectWithAPIKeySigner() async throws {
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
    let fileToUploadPath = testUploadFilePath
    let fileToUploadURL = URL(fileURLWithPath: fileToUploadPath)
    let data: Data = try Data(contentsOf: fileToUploadURL)

    do {
      try await sut.putObject(
        namespaceName: testNamespace,
        bucketName: testBucket,
        objectName: "\(fileToUploadURL.lastPathComponent)",
        putObjectBody: data
      )

      #expect(true, "The operation should succeed")
    }
    catch {
      Issue.record("putObject threw an error: \(error)")
    }
  }

  @Test("Puts an object into a bucket using PAR link")
  func putsObjectPARWithAPIKeySigner() async throws {
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
    let fileToUploadPath = testUploadFilePath
    let fileToUploadURL = URL(fileURLWithPath: fileToUploadPath)
    let data: Data = try Data(contentsOf: fileToUploadURL)

    do {
      try await sut.putObject(
        parURL: URL(string: testParURLWrite)!,
        objectName: "\(fileToUploadURL.lastPathComponent)",
        putObjectBody: data
      )

      #expect(true, "The operation should succeed")
    }
    catch {
      Issue.record("putObject threw an error: \(error)")
    }
  }

  // MARK: - Puts object into user specified folder
  @Test func putsObjectIntoFolderWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )
    let sut = try ObjectStorageClient(region: region, signer: signer, logger: logger)
    let fileToUploadPath = testUploadFilePath
    let fileToUploadURL = URL(fileURLWithPath: fileToUploadPath)
    let data: Data = try Data(contentsOf: fileToUploadURL)

    do {
      try await sut.putObject(
        namespaceName: testNamespace,
        bucketName: testBucket,
        objectName: fileToUploadURL.lastPathComponent,
        putObjectBody: data,
        toFolder: "MyFolder/SubFolder"
      )

      #expect(true, "The operation should succeed")
    }
    catch {
      Issue.record("putObject threw an error: \(error)")
    }
  }

  // MARK: - Puts object into user specified folder using MD5 hash to file integrity
  @Test func putsObjectIntoFolderWithMD5WithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )
    let sut = try ObjectStorageClient(region: region, signer: signer, logger: logger)
    let fileToUploadPath = testUploadFilePath
    let fileToUploadURL = URL(fileURLWithPath: fileToUploadPath)
    let data: Data = try Data(contentsOf: fileToUploadURL)
    let initialMD5 = data.md5base64

    do {
      try await sut.putObject(
        namespaceName: testNamespace,
        bucketName: testBucket,
        objectName: fileToUploadURL.lastPathComponent,
        putObjectBody: data,
        toFolder: "MyFolder/SubFolder",
        contentMD5: initialMD5
      )

      #expect(true, "The operation should succeed")
    }
    catch {
      Issue.record("putObject threw an error: \(error)")
    }
  }

  // MARK: - Reencrypts bucket
  ///  If you call this API and there is no kmsKeyId associated with the bucket, the call will fail.
  @Test func reencryptsBucketWithAPIKeySigner() async throws {
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

    let reencryptBucket: Void? = try? await sut.reencryptBucket(
      namespaceName: testNamespace,
      bucketName: testBucket
    )

    #expect(reencryptBucket != nil, "The operation should succeed")
  }

  // MARK: - Reencrypts object
  @Test func reencryptsObjectWithAPIKeySigner() async throws {
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
    // If the request payload is empty, the object is encrypted using the encryption key assigned to the bucket.
    let reecryptObjectDetails = ReencryptObjectDetails()

    let reencryptObject: Void? = try? await sut.reencryptObject(
      namespaceName: testNamespace,
      bucketName: testBucket,
      objectName: testObject,
      reencryptObjectDetails: reecryptObjectDetails
    )

    #expect(reencryptObject != nil, "The operation should succeed")
  }

  // MARK: - Renames object
  @Test func renamesObjectWithAPIKeySigner() async throws {
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
    let renameObjectDetails = RenameObjectDetails(newName: "New Frame.png", sourceName: testObject)

    let renameObject: Void? = try? await sut.renameObject(
      namespaceName: testNamespace,
      bucketName: testBucket,
      renameObjectDetails: renameObjectDetails
    )

    #expect(renameObject != nil, "The operation should succeed")
  }

  // MARK: - Restore object
  @Test func restoreObjectWithAPIKeySigner() async throws {
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
    let restoreObjectDetails = RestoreObjectsDetails(objectName: testObject)

    let restoreObject: Void? = try? await sut.restoreObject(
      namespaceName: testNamespace,
      bucketName: testBucket,
      restoreObjectsDetails: restoreObjectDetails
    )

    #expect(restoreObject != nil, "The operation should succeed")
  }

  // MARK: - Updates bucket
  @Test func updatesBucketWithMovingToCompartmentWithAPIKeySigner() async throws {
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
    let bucket = UpdateBucketDetails(
      compartmentId: testCompartmentId
    )

    let updateBucket: Bucket? = try? await sut.updateBucket(
      namespaceName: testNamespace,
      bucketName: testBucket,
      updateBucketDetails: bucket
    )

    if let updateBucket {
      logger.info("\(updateBucket.name)")
    }

    // Prints the new name of the updated bucket
    if let updateBucket {
      logger.info("\(updateBucket.name)")
    }
    #expect(updateBucket != nil, "The return value should not be nil")
  }

  // Once a bucket versioning was "Enabled" you can "Suspend" it only.
  @Test func updatesBucketWithVersioningWithAPIKeySigner() async throws {
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
    let bucket = UpdateBucketDetails(versioning: Versoning.suspended)

    let updateBucket: Bucket? = try? await sut.updateBucket(
      namespaceName: testNamespace,
      bucketName: testBucket,
      updateBucketDetails: bucket
    )

    if let updateBucket {
      logger.info("\(updateBucket.name)")
    }

    // Prints the new name of the updated bucket
    if let updateBucket {
      logger.info("\(updateBucket.name)")
    }
    #expect(updateBucket != nil, "The return value should not be nil")
  }

  // MARK: - Updates namespace meatadata
  @Test func updatesNamespaceMetadataWithAPIKeySigner() async throws {
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
    let metadata = UpdateNamespaceMetadataDetails(
      defaultS3CompartmentId: testMetadataCompartmentId,
      defaultSwiftCompartmentId: testMetadataCompartmentId
    )

    let updateNamespaceMetadata = try? await sut.updateNamespaceMetadata(
      namespaceName: testNamespace,
      metadata: metadata
    )

    // Prints metadata
    if let updateNamespaceMetadata {
      logger.info(
        "default-swift-compartment-id: \(updateNamespaceMetadata.defaultSwiftCompartmentId), \ndefault-s3-compartment-id: \(updateNamespaceMetadata.defaultS3CompartmentId), \nnamespace: \(updateNamespaceMetadata.namespace)"
      )
    }
    #expect(updateNamespaceMetadata != nil, "The operation should succeed")
  }

  // MARK: - Updates object storage tier
  @Test func updatesObjectStorageTierWithAPIKeySigner() async throws {
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
    let updateObjectStorageTierDetails = UpdateObjectStorageTierDetails(
      objectName: testObject,
      storageTier: StorageTier.infrequentAccess
    )

    let updateObjectStorageTier: Void? = try? await sut.updateObjectStorageTier(
      namespaceName: testNamespace,
      bucketName: testBucket,
      updateObjectStorageTierDetails: updateObjectStorageTierDetails
    )

    #expect(updateObjectStorageTier != nil, "The operation should succeed")
  }

  // MARK: - Updates retention rule
  @Test func updatesRetentionRuleWithAPIKeySigner() async throws {
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
    let fortyTwoDaysFromNow = Calendar.current.date(byAdding: .day, value: 42, to: Date.now)
    let updateRetentionRuleDetails = UpdateRetentionRuleDetails(
      displayName: "Test_retention_by_SDK_modified",
      duration: Duration(timeAmount: 20, timeUnit: TimeUnit.days),
      timeRuleLocked: fortyTwoDaysFromNow
    )

    let updateRetentionRule = try? await sut.updateRetentionRule(
      namespaceName: testNamespace,
      bucketName: testBucket,
      retentionRuleId: testRetentionRuleIdUpdate,
      updateRetentionRuleDetails: updateRetentionRuleDetails
    )

    // Prints updated retention rule
    if let rule = updateRetentionRule {
      if let timeRuleLocked = rule.timeRuleLocked {
        logger.info("New rule applies lock on \(timeRuleLocked)")
      }
    }
    #expect(updateRetentionRule != nil, "The operation should succeed")
  }
}
