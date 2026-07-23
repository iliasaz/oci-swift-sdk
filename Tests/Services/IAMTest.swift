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

@Suite(.enabled(if: destructiveTestsEnabled, Comment(rawValue: destructiveTestsSkipComment)))
struct IAMTest {
  let ociConfigFilePath: String
  let ociProfileName: String
  // Define your values to be used during the test
  let testCompartment = "ocid1.compartment.oc1..aaaaaaaavlvw5pxtgzcuvru5qvindermz6g4fen2acaikxtug6l3ztjytdeq"
  let targetParentCompartmentId = "ocid1.compartment.oc1..aaaaaaaatcmi2vv2tmuzgpajfncnqnvwvzkg2at7ez5lykdcarwtbeieyo2q"

  init() throws {
    let env = ProcessInfo.processInfo.environment
    ociConfigFilePath = env["OCI_CONFIG_FILE"] ?? "\(NSHomeDirectory())/.oci/config"
    ociProfileName = env["OCI_PROFILE"] ?? "DEFAULT"
  }

  // MARK: - Bulk delete resource
  @Test("Deletes all resources in the specified compartment")
  func bulkDeleteResourcesWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try IAMClient(region: region, signer: signer)
    let bulkDeleteResourceDetails = BulkDeleteResourcesDetails(resources: [BulkActionResource(entityType: "Image", identifier: testCompartment)])
    let bulkDelete: ()? = try? await sut.bulkdeleteResources(compartmentId: testCompartment, bulkDeleteResourcesDetails: bulkDeleteResourceDetails)

    #expect(bulkDelete != nil, "The operation should succeed")
  }

  // MARK: - Bulk move resource
  @Test("Moves all resources in the specified compartment to another compartment")
  func bulkMoveResourcesWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let tenancyId = try extractTenancyId(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try IAMClient(region: region, signer: signer)
    let bulkMoveResourceDetails = BulkMoveResourcesDetails(resources: [BulkActionResource(entityType: "Compartment", identifier: "")], targetCompartmentId: tenancyId ?? "")
    let bulkMove: ()? = try? await sut.bulkMoveResources(compartmentId: testCompartment, bulkMoveResourcesDetails: bulkMoveResourceDetails)

    #expect(bulkMove != nil, "The operation should succeed")
  }

  // MARK: - Creates compartment
  @Test("Creates a compartment into the specified tenancy/comaprtment")
  func createCompartmentWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try IAMClient(region: region, signer: signer)
    let newCompartment = CreateCompartmentDetails(
      compartmentId: targetParentCompartmentId,
      description: "Compartment created by oci-swift-sdk.",
      name: "NewCompartment"
    )
    let createdCompartment = try? await sut.createCompartment(compartmentDetails: newCompartment)

    // Print created compartment
    if let compartment = createdCompartment {
      logger.info("Compartment created: \(compartment.name)\n with ID: \(compartment.id)")
    }
    #expect(createdCompartment != nil, "createdCompartment should not be nil")
  }

  // MARK: - Deletes compartment
  @Test("Deletes the specified compartment")
  func deleteCompartmentWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try IAMClient(region: region, signer: signer)
    let deleteCompartment: ()? = try? await sut.deleteCompartment(compartmentId: testCompartment)

    #expect(deleteCompartment != nil, "deleteCompartment should not be nil")
  }

  //MARK: - Gets compartment
  @Test("Returns the specified compartment")
  func getCompartmentWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try IAMClient(region: region, signer: signer)
    let compartment = try? await sut.getCompartment(compartmentId: targetParentCompartmentId)

    // Print compartment name
    if let compartment = compartment {
      logger.info("\(compartment.name)")
    }
    #expect(compartment != nil, "The compartment should not be nil")
  }

  // MARK: - Lists bulk action resource type
  @Test("Returns with list of bulk action resource types")
  func listBulkActionResourceTypesWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try IAMClient(region: region, signer: signer)
    let bulkActionResourceTypes = try? await sut.listBulkActionResourceTypes(bulkActionType: BulkActionType.bulkDeleteResources, limit: 10)

    if let resources = bulkActionResourceTypes?.items {
      for resource in resources {
        logger.info("\(resource.name)")
      }
    }

    #expect(bulkActionResourceTypes != nil, "The bulk action resource types should not be nil")
  }

  // MARK: - Lists compartments
  @Test("Returns with list of compartments in the same tenancy/compartment")
  func listCompartmentsWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let tenancyId = try extractTenancyId(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try IAMClient(region: region, signer: signer)
    // List compartment in the tenancy, if it fails to extact from `config`, it will list
    // `targetParentCompartmentId`
    let listOfCompartments = try? await sut.listCompartments(compartmentId: tenancyId ?? targetParentCompartmentId)

    // Listing compartments
    if let compartments = listOfCompartments {
      for compartment in compartments {
        logger.info("Compartment: \(compartment.name)")
      }
    }
    #expect(listOfCompartments != nil, "Expected a non-nil list of compartments")
  }

  // MARK: - Moves compartment
  @Test("Move the compartment to a different parent compartment in the same tenancy. ")
  func moveCompartmentWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try IAMClient(region: region, signer: signer)
    // Define the compartment where we want to move
    let moveCompartmentDetails = MoveCompartmentDetails(targetCompartmentId: targetParentCompartmentId)
    // Define the compartment to be moved
    let moveCompartment: ()? = try? await sut.moveCompartment(
      compartmentId: testCompartment,
      moveCompartmentDetails: moveCompartmentDetails
    )

    #expect(moveCompartment != nil, "The compartment should be moved successfully.")
  }

  // MARK: - Recovers compartment
  @Test("Recover the compartment from deleted state. ")
  func recoverCompartmentWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try IAMClient(region: region, signer: signer)
    let recoverCompartment = try? await sut.recoverCompartment(compartmentId: testCompartment)

    if let compartment = recoverCompartment {
      logger.info("Compartment: \(compartment.name) was recovered from deleting.")
    }

    #expect(recoverCompartment != nil, "The compartment should be recovered successfully.")
  }

  // MARK: - Updates compartment
  @Test("Update the name and description of the compartment.")
  func updateCompartmentWithAPIKeySigner() async throws {
    let regionId = try extractUserRegion(
      from: ociConfigFilePath,
      profile: ociProfileName
    )
    let region = Region.from(regionId: regionId ?? "") ?? .iad
    let signer = try APIKeySigner(
      configFilePath: ociConfigFilePath,
      configName: ociProfileName
    )

    let sut = try IAMClient(region: region, signer: signer)
    let updateCompartmentDetails = UpdateCompartmentDetails(description: "Updated by oci-swift-sdk.", name: "UpdatedCompartment")
    let updatedCompartment = try? await sut.updateCompartment(
      compartmentId: testCompartment,
      updateCompartmentDetails: updateCompartmentDetails
    )

    // Print the new name and description the updated compartment
    if let compartment = updatedCompartment {
      logger.info("Compartment: \(compartment.name) with description: \(compartment.description) was updated.")
    }
    #expect(updatedCompartment != nil, "The compartment should be updated successfully.")
  }
}
