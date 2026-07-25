# Deployment guide: logs, metrics, and traces per OCI runtime

This is the practical companion to [`OBSERVABILITY.md`](../OBSERVABILITY.md), which has the
wire-level research (limits, live-verified facts, the reasoning behind every decision). This
guide answers the question an operator actually has: *for the runtime I'm deploying to, which
signer do I construct, which IAM policy do I write, and which OCIKit API do I bootstrap?*

All OCIDs, compartment names, and dynamic-group names below are placeholders — replace the
bracketed values with your own before running anything.

---

## 1. Who collects what, per runtime

**Platform** — collected automatically, nothing to configure. **Agent** — a platform agent the
operator installs/configures. **App** — the process exports in-process via the SDK or OTLP; this
is the path the rest of this guide covers.

| Runtime | Logs → [OCI Logging](https://docs.oracle.com/en-us/iaas/Content/Logging/home.htm) | App metrics → [OCI Monitoring](https://docs.oracle.com/en-us/iaas/Content/Monitoring/home.htm) | Traces → [OCI APM](https://docs.oracle.com/en-us/iaas/application-performance-monitoring/home.htm) | Signer |
|---|---|---|---|---|
| Compute VM — **A1.Flex** (Always Free) | Agent (Custom Logs file tailing) **or** App (`PutLogs`) | App (`PostMetricData`) | App (OTLP) | `InstancePrincipalSigner` |
| Compute VM — **E2.1.Micro** (Always Free x86) | App (`PutLogs`) — the Logging agent plugin is shape-gated on this shape | App (`PostMetricData`) | App (OTLP) | `InstancePrincipalSigner` |
| Compute VM — other shapes | Agent (Custom Logs file tailing) **or** App (`PutLogs`) | App (`PostMetricData`) | App (OTLP) | `InstancePrincipalSigner` |
| OKE | Agent (Custom Logs on managed nodes, tailing `/var/log/containers/*`) **or** App (`PutLogs`) | App (`PostMetricData`) | App (OTLP), directly or via a self-managed OTel Collector | `OKEWorkloadIdentitySigner` (enhanced clusters) or node `InstancePrincipalSigner` |
| Container Instances | App (`PutLogs`) — no agent or sidecar mechanism; the platform is view-only (`RetrieveLogs`) | App (`PostMetricData`) | App (OTLP) | `ResourcePrincipalSigner` |
| Functions | Platform (invocation logs, captures stdout/stderr) | App (`PostMetricData`) | Platform (default invocation span) **plus** App (OTLP, via the injected collector URL) | `ResourcePrincipalSigner` |

Two facts drive most of the recipes below:

- **Every runtime's principal already maps onto a signer OCIKit ships.** There is no new auth
  work anywhere in this plan — just the right constructor call, below.
- **Traces need no IAM policy on any runtime.** OCI APM authenticates OTLP/HTTP ingestion with a
  **data key** (`Authorization: dataKey <key>`), not OCI request signing. §4 covers getting that
  key to the workload; the tracing recipe itself lives in the
  [`apm-tracing`](https://github.com/kicsipixel/oci-swift-sdk-examples/blob/main/apm-tracing/README.md)
  example.

### Always Free guidance

- **A1.Flex**: the Logging agent runs and was live-verified `RUNNING` on an Always Free A1.Flex
  instance. A pre-2022 documentation note claiming Ampere shapes aren't supported is stale — use
  the agent if you want file-tailed logs, or the App path if you'd rather ship structured
  `PutLogs` entries directly.
- **E2.1.Micro**: the Logging agent plugin is shape-gated (`"Not supported plugin is disabled
  for Shape VM.Standard.E2.1.Micro"`) — a 2022 platform note, unrefuted since. With only 1 GB of
  RAM on this shape, running a log-tailing daemon alongside your workload is a poor fit anyway.
  Use `OCILogHandler` (§5.1) to ship logs from the app directly; nothing else changes.

---

## 2. Which signer to construct

| Runtime | Signer | Construction |
|---|---|---|
| Compute VM (any shape, incl. Always Free) | `InstancePrincipalSigner` | `try await InstancePrincipalSigner.fromMetadata()` |
| OKE, enhanced cluster (workload identity) | `OKEWorkloadIdentitySigner` | `try await OKEWorkloadIdentitySigner.fromWorkloadIdentity()` — opt-in `OCIKitWorkloadIdentity` product, pins the cluster CA in-process |
| OKE, node-level fallback | `InstancePrincipalSigner` | `try await InstancePrincipalSigner.fromMetadata()` — same as a bare VM; every node is itself a Compute instance |
| Container Instances | `ResourcePrincipalSigner` | `try await ResourcePrincipalSigner.fromEnvironment()` |
| Functions | `ResourcePrincipalSigner` | `try await ResourcePrincipalSigner.fromEnvironment()` |
| Local dev / CI | `APIKeySigner` | `try APIKeySigner(configFilePath: "\(NSHomeDirectory())/.oci/config")` — the path is **not** tilde-expanded, so `"~/.oci/config"` will not resolve |

```swift
import Foundation   // NSHomeDirectory()
import OCIKit

// Compute VM — instance principal.
let signer = try await InstancePrincipalSigner.fromMetadata()

// Container Instances or Functions — resource principal v2.2. The hosting
// service injects the RPST + private key into the environment; nothing else
// to configure.
let signer = try await ResourcePrincipalSigner.fromEnvironment()

// Local dev / CI — reads ~/.oci/config. Pass an absolute path: the config path
// is handed to the INI parser verbatim, so a literal "~/..." is NOT expanded and
// would throw `ConfigErrors.missingConfig`. (`key_file` inside the config file
// *is* tilde-expanded; only this argument isn't.)
let signer = try APIKeySigner(configFilePath: "\(NSHomeDirectory())/.oci/config")
```

```swift
import OCIKit
import OCIKitWorkloadIdentity   // opt-in product; pulls AsyncHTTPClient + NIOSSL

// OKE, enhanced cluster — workload identity. Performs the pod's proxymux
// token exchange and pins the in-cluster CA in-process; no OS trust-store
// install, no cluster step.
let signer = try await OKEWorkloadIdentitySigner.fromWorkloadIdentity()
```

`OKEWorkloadIdentitySigner.fromWorkloadIdentity()` requires **enhanced clusters** — Oracle's own
words: *"You can only use workload identities to grant access to OCI resources when using
enhanced clusters."* On a basic cluster, or for a simpler setup, use the node's own instance
principal instead (`InstancePrincipalSigner`, same as a bare VM) and scope IAM to the node pool's
compartment.

Every one of these signers works unmodified against `LoggingIngestClient`, `MonitoringClient`,
and any other OCIKit service client — signer selection is a one-time, per-runtime decision, not
something the rest of your code needs to know about.

---

## 3. Per-runtime IAM recipes

Each recipe pairs a **dynamic group** (or, for OKE, a workload-identity condition) with the
policy statements for `use log-content` (`PutLogs`) and `use metrics` (`PostMetricData`).
Narrow the metrics grant to a namespace with `target.metrics.namespace` once you've picked one —
see the `OCIMetricsConfiguration.namespace` validation in §5.2.

> Dynamic groups do **not** inherit across compartments the way IAM policies do: list every
> compartment a matching instance/function/container can live in.

### 3.1 Compute VM — instance principal

Dynamic group matching rule (all instances in one compartment):

```
instance.compartment.id = 'ocid1.compartment.oc1..EXAMPLE'
```

Policy:

```
Allow dynamic-group ocikit-vm-workloads to use log-content in compartment ocikit-workloads
Allow dynamic-group ocikit-vm-workloads to use metrics in compartment ocikit-workloads where target.metrics.namespace='my_app'
```

### 3.2 OKE — workload identity (enhanced clusters)

No dynamic group: the principal is `any-user`, scoped down by `request.principal.*`
conditions matched against the pod's Kubernetes service account.

```
Allow any-user to use log-content in compartment ocikit-workloads where all {
  request.principal.type = 'workload',
  request.principal.namespace = 'ocikit-app',
  request.principal.service_account = 'ocikit-app-sa',
  request.principal.cluster_id = 'ocid1.cluster.oc1.phx.EXAMPLE'
}

Allow any-user to use metrics in compartment ocikit-workloads where all {
  request.principal.type = 'workload',
  request.principal.namespace = 'ocikit-app',
  request.principal.service_account = 'ocikit-app-sa',
  request.principal.cluster_id = 'ocid1.cluster.oc1.phx.EXAMPLE',
  target.metrics.namespace = 'my_app'
}
```

If you're on a basic (non-enhanced) cluster, skip workload identity and grant the node pool's
instance-principal dynamic group instead, using the VM recipe in §3.1 scoped to the node pool's
compartment.

### 3.3 Container Instances — resource principal v2.2

Dynamic group matching rule:

```
ALL {resource.type = 'computecontainerinstance', resource.compartment.id = 'ocid1.compartment.oc1..EXAMPLE'}
```

Policy:

```
Allow dynamic-group ocikit-container-instances to use log-content in compartment ocikit-workloads
Allow dynamic-group ocikit-container-instances to use metrics in compartment ocikit-workloads where target.metrics.namespace='my_app'
```

Container Instances has no agent and no sidecar mechanism — the platform's own `RetrieveLogs` is
view-only (container stdout/stderr, not exported to Logging). Every log line your app cares
about has to go out through `OCILogHandler`/`PutLogs`.

### 3.4 Functions — resource principal v2.2

Dynamic group matching rule:

```
ALL {resource.type = 'fnfunc', resource.compartment.id = 'ocid1.compartment.oc1..EXAMPLE'}
```

Policy:

```
Allow dynamic-group ocikit-functions to use log-content in compartment ocikit-workloads
Allow dynamic-group ocikit-functions to use metrics in compartment ocikit-workloads where target.metrics.namespace='my_app'
```

Two Functions-specific gotchas, straight from Oracle's own docs:

- **Free-form tags are not supported** in a Functions dynamic-group matching rule — only defined
  tags (`tag.<namespace>.<key>.value = '...'`) if you want to scope by tag instead of compartment.
- **The token is cached for 15 minutes.** After changing the policy or the dynamic group, a
  running function can keep failing authorization for up to 15 minutes before the change takes
  effect — don't assume a policy edit is live immediately.

Functions needs no IAM at all for **traces**: enabling tracing on the app + function makes the
platform inject the OTLP collector URL and data key directly (§5.3) — see the
[`apm-tracing`](https://github.com/kicsipixel/oci-swift-sdk-examples/blob/main/apm-tracing/README.md)
example.

---

## 4. APM data-key distribution

APM authenticates trace ingestion with a **data key** (`Authorization: dataKey <key>`), not OCI
request signing — there's no signer and no IAM policy on the hot path (§1). The key still has to
get from the APM domain to the workload somehow. On Functions the platform does this for you
(the collector URL, key included, is injected as an environment variable). On every other
runtime — VM, OKE, Container Instances — **nothing injects it**, so the operator has to choose a
distribution path.

### Recommended: a Vault secret, read at startup

Store the data key (and, if you like, the domain's `dataUploadEndpoint`) in an OCI **Vault**
secret, and have the workload read it under its own injected principal — the same signer from
§2, no new OCIKit surface:

```swift
import OCIKit

let signer = try await InstancePrincipalSigner.fromMetadata()   // or ResourcePrincipalSigner / OKEWorkloadIdentitySigner
let client = try SecretsClient(region: .phx, signer: signer)

let bundle = try await client.getSecretBundle(secretId: "ocid1.vaultsecret.oc1.phx.EXAMPLE")
guard let apmDataKey = bundle.secretBundleContent?.decodedString else {
  throw MyAppError.missingAPMDataKey   // your own error type
}
```

Policy, scoped to one secret:

```
Allow dynamic-group ocikit-vm-workloads to read secret-bundles in compartment ocikit-workloads where target.secret.id='ocid1.vaultsecret.oc1.phx.EXAMPLE'
```

This works identically on every runtime that has a signer, needs no new OCIKit code, and rotates
cleanly — updating the secret's content doesn't require touching the workload's environment or
redeploying.

### Simpler: inject the key as configuration

If you don't want to stand up a Vault — a scratch VM, a single Container Instance, a demo —
hand the key to the workload as an environment variable and read it at startup. This is what
the [`apm-trace-probe`](https://github.com/kicsipixel/oci-swift-sdk-examples/blob/main/apm-tracing/README.md#1-apm-trace-probe--a-workload-on-vm--oke--container-instances)
example does:

```swift
import Foundation

guard let apmDataKey = ProcessInfo.processInfo.environment["APM_DATA_KEY"] else {
  throw MyAppError.missingAPMDataKey   // your own error type
}
```

Set it per runtime the usual way: `--env APM_DATA_KEY=...` on a Container Instance's container,
`env:` (or a Kubernetes `Secret` mounted into `env:`) on an OKE pod spec, the function's
configuration on Functions, cloud-init or the unit file on a VM.

The trade-off is why this isn't the default: **the key then lives in the resource's own
configuration** — readable by anyone with `inspect`/`read` on that instance, container, or
function, printed by `oci ... get`, and captured in whatever infrastructure-as-code declares it.
**Rotation means a redeploy** of every workload holding it, rather than one new secret version
in the Vault. And it leaves no audit trail: a Vault read is an auditable event per workload,
per startup; reading an environment variable is not. Use it to get going; move to the Vault
recipe above once the workload is something you'd have to rotate a leaked key out of.

### Why not bootstrap from `ListDataKeys` instead?

The `apm-control-plane` control-plane API can list a domain's data keys
(`GetApmDomain`/`ListDataKeys`), which looks like an obvious way to fetch a key at runtime
without a Vault detour. It's the worse default: **`ListDataKeys` returns the key *values*, live-
verified** — not references to them. Any IAM policy that grants `ListDataKeys` is therefore
exactly as sensitive as granting the keys themselves, and it grants it for *every* key in the
domain (public and private) rather than the one the workload actually needs. A Vault secret lets
you scope access to one key via `target.secret.id`, rotate it independently of the APM domain,
and audit reads through the same trail as every other secret in your tenancy. OCIKit ships no
`apm-control-plane` client for this reason — `SecretsClient.getSecretBundle` is the whole
recipe.

### Functions is the exception

On Functions, tracing needs no Vault lookup at all: enabling tracing on the app + function makes
the platform inject the **public** data key directly, embedded in `OCI_TRACE_COLLECTOR_URL`. A
Vault secret still matters there for OTLP **metrics** (which need the domain's *private* key —
never injected) and for anything else that needs the key outside the traces path.

---

## 5. Bootstrapping the OCIKit backends

Once you have a signer, wiring logs and metrics is process-global bootstrap the app performs
once at startup — OCIKit never calls `LoggingSystem.bootstrap`/`MetricsSystem.bootstrap` itself,
so you're always free to multiplex these with another backend.

### 5.1 Logs — `OCILogHandler`

```swift
import Logging
import OCIKit

let batcher = try OCILogBatcher(
  configuration: OCILogHandlerConfiguration(
    logId: "ocid1.log.oc1.phx.EXAMPLE",   // an existing custom log
    type: "com.example.orders"
  ),
  region: .phx,
  signer: signer
)

LoggingSystem.bootstrap { label in
  OCILogHandler(label: label, batcher: batcher)
}

Logger(label: "com.example.orders").info("order placed", metadata: ["orderId": "1234"])

// Before the process exits, so buffered records are not lost:
await batcher.shutdown()
```

Full behavior — batching, truncation-splitting, the recursion guard, and what counts as a
dropped vs. a retried record — is documented in [`logging-backend.md`](logging-backend.md)
§3–§5.

### 5.2 Metrics — `OCIMetricsFactory`

```swift
import CoreMetrics
import OCIKit

let client = try MonitoringClient(region: .phx, signer: signer)
let factory = OCIMetricsFactory(
  client: client,
  configuration: try OCIMetricsConfiguration(
    namespace: "my_app",
    compartmentId: compartmentId,
    commonDimensions: ["service": "checkout", "env": "prod"]
  )
)
await factory.start()
MetricsSystem.bootstrap(factory)

// before the process exits, so the last step is not lost:
await factory.shutdown()
```

Full behavior — 50-stream chunking, dimension sanitization, the two-hour staleness drop — is
documented in [`metrics-backend.md`](metrics-backend.md) §3–§4.

### 5.3 Traces — swift-otel → APM

There is no OCIKit trace client to bootstrap: APM speaks OTLP/HTTP natively (§4), so tracing is
a stock OTLP exporter (swift-otel) pointed at the domain's traces endpoint with the data key as a
header — no signer, no IAM policy. The full worked recipe, for both a long-running workload
(VM/OKE/Container Instances) and an OCI Function consuming the injected collector URL, is
the [`apm-tracing`](https://github.com/kicsipixel/oci-swift-sdk-examples/blob/main/apm-tracing/README.md)
example — a standalone package (swift-otel never enters the SDK's own dependency graph) with a
real run against a live APM domain recorded in its README.
