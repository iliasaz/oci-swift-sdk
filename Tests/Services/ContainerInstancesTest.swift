//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2026 Ilia Sazonov and the oci-swift-sdk project authors
// Licensed under MIT License
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of oci-swift-sdk project authors
//
// SPDX-License-Identifier: MIT License
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import OCIKit

// MARK: - Router

struct ContainerInstancesRouterTests {
  @Test("Create/list container instances route to the collection path")
  func containerInstancesCollectionPath() {
    #expect(ContainerInstancesAPI.createContainerInstance().path == "/20210415/containerInstances")
    #expect(ContainerInstancesAPI.createContainerInstance().method == .post)
    #expect(ContainerInstancesAPI.listContainerInstances(compartmentId: "ocid1.compartment").path == "/20210415/containerInstances")
    #expect(ContainerInstancesAPI.listContainerInstances(compartmentId: "ocid1.compartment").method == .get)
  }

  @Test("Get/update/delete route to the resource path with the OCID")
  func containerInstanceResourcePath() {
    let id = "ocid1.containerinstance.oc1..aaaa"
    #expect(ContainerInstancesAPI.getContainerInstance(containerInstanceId: id).path == "/20210415/containerInstances/\(id)")
    #expect(ContainerInstancesAPI.getContainerInstance(containerInstanceId: id).method == .get)
    #expect(ContainerInstancesAPI.updateContainerInstance(containerInstanceId: id).method == .put)
    #expect(ContainerInstancesAPI.deleteContainerInstance(containerInstanceId: id).method == .delete)
  }

  @Test("Lifecycle actions route to /actions/<verb>")
  func lifecycleActionPaths() {
    let id = "ocid1.containerinstance.oc1..aaaa"
    #expect(ContainerInstancesAPI.startContainerInstance(containerInstanceId: id).path == "/20210415/containerInstances/\(id)/actions/start")
    #expect(ContainerInstancesAPI.stopContainerInstance(containerInstanceId: id).path == "/20210415/containerInstances/\(id)/actions/stop")
    #expect(ContainerInstancesAPI.restartContainerInstance(containerInstanceId: id).path == "/20210415/containerInstances/\(id)/actions/restart")
    #expect(
      ContainerInstancesAPI.changeContainerInstanceCompartment(containerInstanceId: id).path
        == "/20210415/containerInstances/\(id)/actions/changeCompartment")
    #expect(ContainerInstancesAPI.startContainerInstance(containerInstanceId: id).method == .post)
  }

  @Test("Work request and container paths")
  func otherResourcePaths() {
    #expect(ContainerInstancesAPI.getContainer(containerId: "ocid1.container").path == "/20210415/containers/ocid1.container")
    #expect(ContainerInstancesAPI.retrieveLogs(containerId: "ocid1.container").path == "/20210415/containers/ocid1.container/actions/retrieveLogs")
    #expect(ContainerInstancesAPI.listContainerInstanceShapes(compartmentId: "c").path == "/20210415/containerInstanceShapes")
    #expect(ContainerInstancesAPI.getWorkRequest(workRequestId: "wr1").path == "/20210415/workRequests/wr1")
    #expect(ContainerInstancesAPI.listWorkRequestErrors(workRequestId: "wr1").path == "/20210415/workRequests/wr1/errors")
    #expect(ContainerInstancesAPI.listWorkRequestLogs(workRequestId: "wr1").path == "/20210415/workRequests/wr1/logs")
  }

  @Test("List container instances assembles query items, filtering nils")
  func listQueryItems() {
    let items = ContainerInstancesAPI.listContainerInstances(
      compartmentId: "ocid1.compartment",
      lifecycleState: .active,
      displayName: "web",
      limit: 25,
      sortOrder: .desc,
      sortBy: .timeCreated
    ).queryItems ?? []

    let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
    #expect(dict["compartmentId"] == "ocid1.compartment")
    #expect(dict["lifecycleState"] == "ACTIVE")
    #expect(dict["displayName"] == "web")
    #expect(dict["limit"] == "25")
    #expect(dict["sortOrder"] == "DESC")
    #expect(dict["sortBy"] == "timeCreated")
    // Unset optionals must be omitted.
    #expect(dict["availabilityDomain"] == nil)
    #expect(dict["page"] == nil)
  }

  @Test("retrieveLogs encodes isPrevious as a boolean string")
  func retrieveLogsQuery() {
    let onItems = ContainerInstancesAPI.retrieveLogs(containerId: "c", isPrevious: true).queryItems ?? []
    #expect(onItems.first(where: { $0.name == "isPrevious" })?.value == "true")
    // Omitted when nil.
    #expect(ContainerInstancesAPI.retrieveLogs(containerId: "c").queryItems == nil)
  }

  @Test("Headers carry if-match, opc-request-id, and opc-retry-token where applicable")
  func headers() {
    let update = ContainerInstancesAPI.updateContainerInstance(
      containerInstanceId: "id", ifMatch: "etag-123", opcRequestId: "req-1"
    ).headers ?? [:]
    #expect(update["if-match"] == "etag-123")
    #expect(update["opc-request-id"] == "req-1")

    let create = ContainerInstancesAPI.createContainerInstance(opcRetryToken: "tok", opcRequestId: "req-2").headers ?? [:]
    #expect(create["opc-retry-token"] == "tok")
    #expect(create["opc-request-id"] == "req-2")

    // No headers set => nil.
    #expect(ContainerInstancesAPI.getContainerInstance(containerInstanceId: "id").headers == nil)
  }

  @Test("buildRequest composes the full signed-ready URL")
  func buildRequestURL() throws {
    let endpoint = URL(string: "https://compute-containers.us-phoenix-1.oci.oraclecloud.com")!
    let req = try buildRequest(
      api: ContainerInstancesAPI.listContainerInstances(compartmentId: "ocid1.compartment"),
      endpoint: endpoint
    )
    let url = req.url!.absoluteString
    #expect(url.hasPrefix("https://compute-containers.us-phoenix-1.oci.oraclecloud.com/20210415/containerInstances?"))
    #expect(url.contains("compartmentId=ocid1.compartment"))
    #expect(req.httpMethod == "GET")
  }
}

// MARK: - Enums

struct ContainerInstancesEnumsTests {
  @Test("Enum raw values match the OCI wire strings")
  func rawValues() {
    #expect(ContainerInstanceLifecycleState.active.rawValue == "ACTIVE")
    #expect(ContainerInstanceLifecycleState.deleting.rawValue == "DELETING")
    #expect(ContainerRestartPolicy.onFailure.rawValue == "ON_FAILURE")
    #expect(ImagePullSecretType.vault.rawValue == "VAULT")
    #expect(ContainerVolumeType.emptyDir.rawValue == "EMPTYDIR")
    #expect(ContainerVolumeType.configFile.rawValue == "CONFIGFILE")
    #expect(ContainerInstanceWorkRequestStatus.inProgress.rawValue == "IN_PROGRESS")
    #expect(ContainerInstanceWorkRequestOperationType.createContainerInstance.rawValue == "CREATE_CONTAINER_INSTANCE")
  }
}

// MARK: - Model encoding (request wire format)

struct ContainerInstancesModelEncodingTests {
  /// Encodes a value and returns the resulting JSON as a dictionary for inspection.
  private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
  }

  @Test("Volume factories emit the correct discriminator and only the relevant fields")
  func volumeUnionEncoding() throws {
    let empty = try jsonObject(CreateContainerVolumeDetails.emptyDir(name: "scratch", backingStore: "MEMORY"))
    #expect(empty["name"] as? String == "scratch")
    #expect(empty["volumeType"] as? String == "EMPTYDIR")
    #expect(empty["backingStore"] as? String == "MEMORY")
    #expect(empty["configs"] == nil)  // omitted for EMPTYDIR

    let config = try jsonObject(
      CreateContainerVolumeDetails.configFile(
        name: "cfg",
        configs: [ContainerConfigFile(fileName: "app.conf", data: "aGVsbG8=")]
      ))
    #expect(config["volumeType"] as? String == "CONFIGFILE")
    #expect(config["backingStore"] == nil)  // omitted for CONFIGFILE
    let configs = config["configs"] as? [[String: Any]]
    #expect(configs?.first?["fileName"] as? String == "app.conf")
    #expect(configs?.first?["data"] as? String == "aGVsbG8=")
  }

  @Test("Image pull secret factories emit the discriminator and credentials")
  func imagePullSecretEncoding() throws {
    let basic = try jsonObject(CreateImagePullSecretDetails.basic(registryEndpoint: "iad.ocir.io", username: "dXNlcg==", password: "cGFzcw=="))
    #expect(basic["secretType"] as? String == "BASIC")
    #expect(basic["registryEndpoint"] as? String == "iad.ocir.io")
    #expect(basic["username"] as? String == "dXNlcg==")
    #expect(basic["secretId"] == nil)

    let vault = try jsonObject(CreateImagePullSecretDetails.vault(registryEndpoint: "iad.ocir.io", secretId: "ocid1.vaultsecret"))
    #expect(vault["secretType"] as? String == "VAULT")
    #expect(vault["secretId"] as? String == "ocid1.vaultsecret")
    #expect(vault["username"] == nil)
  }

  @Test("A full create-instance payload nests required objects with correct keys")
  func createInstanceEncoding() throws {
    let details = CreateContainerInstanceDetails(
      compartmentId: "ocid1.compartment",
      availabilityDomain: "AD-1",
      shape: "CI.Standard.E4.Flex",
      shapeConfig: CreateContainerInstanceShapeConfigDetails(ocpus: 1, memoryInGBs: 4),
      containers: [CreateContainerDetails(imageUrl: "iad.ocir.io/ns/app:latest")],
      vnics: [CreateContainerVnicDetails(subnetId: "ocid1.subnet")],
      containerRestartPolicy: .always
    )
    let json = try jsonObject(details)
    #expect(json["compartmentId"] as? String == "ocid1.compartment")
    #expect(json["availabilityDomain"] as? String == "AD-1")
    #expect(json["shape"] as? String == "CI.Standard.E4.Flex")
    #expect(json["containerRestartPolicy"] as? String == "ALWAYS")

    let shapeConfig = json["shapeConfig"] as? [String: Any]
    #expect(shapeConfig?["ocpus"] as? Double == 1)
    #expect(shapeConfig?["memoryInGBs"] as? Double == 4)

    let containers = json["containers"] as? [[String: Any]]
    #expect(containers?.first?["imageUrl"] as? String == "iad.ocir.io/ns/app:latest")

    let vnics = json["vnics"] as? [[String: Any]]
    #expect(vnics?.first?["subnetId"] as? String == "ocid1.subnet")
  }
}

// MARK: - Model decoding (response wire format)

struct ContainerInstancesModelDecodingTests {
  @Test("Decodes a container instance with nested objects, enums, and dates")
  func decodesContainerInstance() throws {
    let json = """
      {
        "id": "ocid1.containerinstance.oc1..aaaa",
        "displayName": "my-instance",
        "compartmentId": "ocid1.compartment.oc1..bbbb",
        "availabilityDomain": "Uocm:PHX-AD-1",
        "lifecycleState": "ACTIVE",
        "containers": [{ "containerId": "ocid1.container.oc1..cccc" }],
        "containerCount": 1,
        "timeCreated": "2025-01-15T10:30:00.000Z",
        "shape": "CI.Standard.E4.Flex",
        "shapeConfig": {
          "ocpus": 1.0,
          "memoryInGBs": 4.0,
          "processorDescription": "AMD EPYC",
          "networkingBandwidthInGbps": 1.0
        },
        "vnics": [{ "vnicId": "ocid1.vnic.oc1..dddd" }],
        "containerRestartPolicy": "ALWAYS",
        "volumeCount": 0
      }
      """
    let instance = try JSONDecoder().decode(ContainerInstance.self, from: json.data(using: .utf8)!)
    #expect(instance.id == "ocid1.containerinstance.oc1..aaaa")
    #expect(instance.lifecycleState == .active)
    #expect(instance.containerRestartPolicy == .always)
    #expect(instance.containerCount == 1)
    #expect(instance.containers.first?.containerId == "ocid1.container.oc1..cccc")
    #expect(instance.shapeConfig.processorDescription == "AMD EPYC")
    #expect(instance.vnics.first?.vnicId == "ocid1.vnic.oc1..dddd")
    #expect(instance.timeCreated != nil)
  }

  @Test("Decodes a container instance collection")
  func decodesCollection() throws {
    let json = """
      {
        "items": [
          {
            "id": "ocid1.ci.1", "displayName": "a", "compartmentId": "c",
            "availabilityDomain": "AD-1", "lifecycleState": "CREATING",
            "containerCount": 2, "timeCreated": "2025-01-15T10:30:00.000Z",
            "shape": "CI.Standard.E4.Flex",
            "shapeConfig": { "ocpus": 1.0, "memoryInGBs": 2.0, "processorDescription": "x", "networkingBandwidthInGbps": 1.0 },
            "containerRestartPolicy": "NEVER"
          }
        ]
      }
      """
    let collection = try JSONDecoder().decode(ContainerInstanceCollection.self, from: json.data(using: .utf8)!)
    #expect(collection.items.count == 1)
    #expect(collection.items.first?.lifecycleState == .creating)
    #expect(collection.items.first?.containerRestartPolicy == .never)
  }

  @Test("Decodes a work request with status, operation type, and dates")
  func decodesWorkRequest() throws {
    let json = """
      {
        "operationType": "CREATE_CONTAINER_INSTANCE",
        "status": "IN_PROGRESS",
        "id": "ocid1.workrequest.oc1..eeee",
        "compartmentId": "ocid1.compartment.oc1..ffff",
        "resources": [
          { "entityType": "containerInstance", "actionType": "CREATED", "identifier": "ocid1.ci.1" }
        ],
        "percentComplete": 42.5,
        "timeAccepted": "2025-01-15T10:30:00.000Z"
      }
      """
    let wr = try JSONDecoder().decode(ContainerInstanceWorkRequest.self, from: json.data(using: .utf8)!)
    #expect(wr.operationType == .createContainerInstance)
    #expect(wr.status == .inProgress)
    #expect(wr.percentComplete == 42.5)
    #expect(wr.resources.first?.actionType == .created)
    #expect(wr.timeAccepted != nil)
  }

  @Test("Decodes a polymorphic container volume by discriminator")
  func decodesVolumeUnion() throws {
    let json = """
      { "name": "scratch", "volumeType": "EMPTYDIR", "backingStore": "EPHEMERAL_STORAGE" }
      """
    let volume = try JSONDecoder().decode(ContainerVolume.self, from: json.data(using: .utf8)!)
    #expect(volume.name == "scratch")
    #expect(volume.volumeType == .emptyDir)
    #expect(volume.backingStore == "EPHEMERAL_STORAGE")
  }
}
