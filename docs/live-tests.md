# Running the live integration tests

Most suites under `Tests/` are **live integration tests**: they build an
`APIKeySigner` from `~/.oci/config` and make real calls against your OCI tenancy.
They need (a) OCI credentials and (b) references to real resources in your
tenancy (namespaces, buckets, compartment/vault/secret OCIDs, …). To keep those
tenancy-specific values out of source, they are read from **environment
variables** supplied by an Xcode **test plan**.

CI never runs these — the Linux workflow only runs the credential-free unit
suites in `UNIT_TEST_FILTER`.

## Setup

1. Copy the committed template into the gitignored `.swiftpm/` directory (so your
   values never get committed):

   ```sh
   cp oci-swift-sdk-Package.xctestplan.template .swiftpm/oci-swift-sdk-Package.xctestplan
   ```

2. Open `.swiftpm/oci-swift-sdk-Package.xctestplan` in Xcode (Product ▸ Test Plan,
   or edit the JSON directly) and fill in the values for your tenancy. Leave a
   variable blank to skip the tests that require it — the suites that guard on an
   env var self-skip when it is unset.

3. Run the tests through that test plan in Xcode.

`.swiftpm/` is gitignored, so your filled-in plan stays local. Only the
`*.template` file (with placeholder values) is committed.

## ⚠️ Destructive suites

Some live suites **create and delete real resources**. Only run them against a
throwaway/test tenancy or compartment:

- `ObjectStorageTest` — creates/deletes buckets and objects, PARs, replication &
  retention rules; moves compartments; re-encrypts; updates namespace metadata.
- `ObjectStorageTestOnLinux`, `PutObjectHeaderCasingDiagnostics` — put/delete objects.
- `IAMTest` — bulk-deletes/moves resources; creates/deletes/moves/recovers/updates compartments.
- `LoggingIngestionLiveTest` — writes a real log entry.

Read-only or non-destructive: `OCIKitTests`, `SecretsIntegrationTest`,
`GenAITest`, `HealthEntityTest`, `MonitoringLiveTest`, `InstancePrincipalObjectStorageTest`.

## Environment variables

| Variable | Used by | Purpose |
| --- | --- | --- |
| `OCI_CONFIG_FILE`, `OCI_PROFILE` | all live suites | Which `~/.oci/config` file and profile to sign with. |
| `OCI_TENANCY_ID` | Object Storage, Core | Tenancy OCID (used as a `compartmentId` for `getNamespace`). |
| `OCI_COMPARTMENT_ID` | Object Storage, IAM | Working compartment (create/list buckets, IAM parent). |
| `OCI_REGION` | Monitoring (live) | Region id for the monitoring datapoint. |
| `OCI_NAMESPACE`, `OCI_BUCKET`, `OCI_OBJECT` | Object Storage | Primary namespace / bucket / object. |
| `OCI_OS_OBJECT_SVG`, `OCI_OS_OBJECT_TXT`, `OCI_OS_UPLOAD_FILE` | Object Storage | Extra object names + a local file to upload. |
| `OCI_OS_REPLICA_BUCKET`, `OCI_OS_PAR_BUCKET`, `OCI_OS_COPY_DEST_BUCKET`, `OCI_OS_DEST_REGION`, `OCI_OS_METADATA_COMPARTMENT_ID`, `OCI_OS_NAMESPACE_2` | Object Storage | Replication/PAR/copy targets, destination region, namespace-metadata compartment, second namespace. |
| `OCI_OS_PAR_URL_READ`, `OCI_OS_PAR_URL_WRITE`, `OCI_OS_PAR_ID_GET`, `OCI_OS_PAR_ID`, `OCI_OS_OBJECT_VERSION_ID`, `OCI_OS_REPLICATION_ID`, `OCI_OS_RETENTION_RULE_ID_*` | Object Storage | Per-resource identifiers — **these change every time the resource is recreated**, so update them for your account. |
| `OCI_TEST_BUCKET` | `PutObjectHeaderCasingDiagnostics` | Bucket to PUT into (namespace is fetched at runtime). |
| `OCI_IAM_TEST_COMPARTMENT_ID` | IAM | **Destructive** target compartment (bulk-delete/move/delete/recover/update). |
| `OCI_SECRET_ID`, `OCI_VAULT_ID`, `OCI_SECRET_NAME` | Secrets | Secret + vault for bundle retrieval and get-by-name. |
| `GENAI_COMPARTMENT_OCID`, `GENAI_COHERE_MODEL_OCID`, `GENAI_LLAMA_MODEL_OCID` | Generative AI | Compartment + model OCIDs (suite self-skips if unset). |
| `HEALTH_NER_ENDPOINT` | Language/Health | Health-NER model endpoint (self-skips if unset). |
| `MONITORING_COMPARTMENT_OCID`, `MONITORING_NAMESPACE` | Monitoring (live) | Compartment + custom metric namespace (self-skips if compartment unset). |
| `OCI_LOG_ID` | Logging Ingestion (live) | Log OCID to append to (self-skips if unset). |
| `OCI_METADATA_BASE_URL` | Instance Principal | IMDS base URL; default is the standard `169.254.169.254` endpoint. |
