# oci-swift-sdk
oci-swift-sdk is a Swift SDK for interacting with Oracle Cloud Infrastructure (OCI), designed to work seamlessly across Linux, macOS, and iOS platforms. It enables developers to build robust, cloud-native applications in Swift by providing comprehensive access to OCI services.

The project is community-supported and maintained by contributors who are passionate about Swift and cloud development. It is not affiliated with Oracle or Oracle Cloud Infrastructure, and it does not receive official support from Oracle.

## Why
I love Swift, I use OCI because it's good, and I'd like to use OCI services for my Swift projects. And because there is no OCI SDK for Swift as of today.  

## Approach
Support for OCI services is being added incrementally, starting with those currently required. Contributions to expand service coverage are welcome. If a specific service is needed, feel free to implement it and submit a pull request so others can benefit from the addition as well.

## TODO List
- [x] API Key authN
- [x] GenAI inference (common models)
- [x] Instance Principal authN
- [x] Resource Principal authN (v2.2 — Container Instances, Functions, Data Science)
- [x] OKE Workload Identity authN (opt-in `OCIKitWorkloadIdentity` product — pins the in-cluster proxymux CA in-process)
- [x] Session token (UPST) authN — sign with a CLI session profile, plus validate / refresh / non-interactive create (`SessionTokenManager`). `SessionTokenSigner` is the self-refreshing signer for long-lived processes: it picks up a token refreshed out of band and refreshes the session itself at the token's half-life, where `SecurityTokenSigner` signs forever with the token it read at init.
- [x] Object Storage
- [x] Container Instances
- [x] GenAI inference (custom models)
- [x] Identity & Access Management (compartments)
- [x] Secrets (secret bundles)
- [x] AI Language (health entity detection)
- [x] Functions — run Swift as a function (FDK) + invoke a function
- [x] Logging Ingestion (`PutLogs`) + a batching swift-log backend
- [x] Monitoring (`PostMetricData`) + a swift-metrics backend

## Logging backend

`OCILogHandler` is a [swift-log](https://github.com/apple/swift-log) backend that ships your
application's log records to an OCI [custom log](https://docs.oracle.com/en-us/iaas/Content/Logging/Concepts/custom_logs.htm)
with `PutLogs`: bootstrap it once and the rest of the code keeps using plain `Logger` values,
while an actor batches records in the background so `log(...)` never blocks and never performs
I/O. Reach for it wherever the platform will not collect your logs for you — Container
Instances, Compute shapes the Logging agent does not cover, or any process whose records must
land in Logging without a file on disk in between.

See [`docs/logging-backend.md`](docs/logging-backend.md) for prerequisites and IAM, the
bootstrap composition, the full configuration surface, flushing and shutdown, the two ways
records can be lost, and how to confirm delivery.

## OCI Functions

`OCIKitFunctions` is an opt-in [Function Development Kit](Sources/OCIKitFunctions/README.md)
that lets a Swift program run as an OCI Function (it serves the Fn `http-stream`
contract over a Unix socket). To call a deployed function from a Swift service,
`OCIKit` ships `FunctionsInvokeClient` (no extra dependencies). See the
[OCIKitFunctions guide](Sources/OCIKitFunctions/README.md) for writing, deploying,
and invoking functions.

## Metrics backend

`OCIMetricsFactory` is a [swift-metrics](https://github.com/apple/swift-metrics) backend that
publishes an application's `Counter`, `Gauge`, `Recorder` and `Timer` instruments to
[OCI Monitoring](https://docs.oracle.com/en-us/iaas/Content/Monitoring/Tasks/publishingcustommetrics.htm)
as custom metrics — aggregated in process and posted with `PostMetricData` on a 60-second step,
where they become queryable, chartable and alarmable next to the platform's own `oci_*` metrics.
Reach for it whenever you want application-level numbers such as request rates, queue depths or
handler latencies: no OCI runtime collects those for you, so self-export is the only path.

See [`docs/metrics-backend.md`](docs/metrics-backend.md) for prerequisites and IAM, the
bootstrap composition, the configuration surface, what each instrument becomes on the wire,
shutdown, and how to confirm the metrics arrived.

## Tracing

Traces are the one signal with **no OCIKit client, deliberately**. OCI
[APM](https://docs.oracle.com/en-us/iaas/application-performance-monitoring/home.htm) ingests
OpenTelemetry natively: its collector accepts OTLP/HTTP authenticated with
`Authorization: dataKey <key>` rather than an OCI request signature, so any stock OTLP exporter
— [swift-otel](https://github.com/swift-otel/swift-otel), typically — can post spans to an APM
domain unmodified. There is nothing for this SDK to sign, and so nothing for it to wrap.

[`apm-tracing`](https://github.com/kicsipixel/oci-swift-sdk-examples/blob/main/apm-tracing/README.md),
in the [examples repo](https://github.com/kicsipixel/oci-swift-sdk-examples), is a standalone,
runnable worked example of that recipe (a plain service and an OCI Functions variant), with the
endpoint layout, data-key handling, and the caveats that bite — span links are dropped, there is
no OTLP logs endpoint, and Always Free is capped at 1,000 tracing events per hour. On Functions
the platform injects the collector URL and B3 trace context at runtime; `OCIKitFunctions`
surfaces both through `TracingContext` and `APMCollectorEndpoint`.

## Deployment guide

For per-runtime guidance — which signer to construct on a VM, OKE, Container Instances, or
Functions; copy-paste IAM policies for logs and metrics; Always Free specifics; and how to
distribute an APM data key — see
[`docs/observability-deployment.md`](docs/observability-deployment.md).

## Examples

Complete, runnable projects live in a companion repository,
[`kicsipixel/oci-swift-sdk-examples`](https://github.com/kicsipixel/oci-swift-sdk-examples) —
whole apps you can build, deploy and read end to end, rather than the fragments this README and
the `docs/` guides can show. Each one is self-contained and carries its own setup instructions:

- [`FileLift`](https://github.com/kicsipixel/oci-swift-sdk-examples/tree/main/FileLift) — a macOS
  drag-and-drop client that resolves the Object Storage namespace, lists buckets in a compartment,
  and uploads files into the one you pick.
- [`BucketView`](https://github.com/kicsipixel/oci-swift-sdk-examples/tree/main/BucketView) — a
  macOS browser for Object Storage: buckets in a compartment, and the objects inside a bucket.
- [`BucketRelay`](https://github.com/kicsipixel/oci-swift-sdk-examples/tree/main/BucketRelay) — a
  [Hummingbird](https://github.com/hummingbird-project/hummingbird) REST service that uploads,
  downloads, lists and deletes objects, deployed as an **OCI Container Instance** and
  authenticated with `ResourcePrincipalSigner` — no API key or config file in the image. Ships
  the networking, bucket, dynamic-group and policy scripts too.
- [`swift-oke`](https://github.com/kicsipixel/oci-swift-sdk-examples/tree/main/swift-oke) — a
  Hummingbird REST service that serves an object's text, running as a pod in an **OKE
  (Kubernetes) cluster** and authenticated with `OKEWorkloadIdentitySigner` via the pod's service
  account. Uses the opt-in `OCIKitWorkloadIdentity` product to pin the in-cluster CA in-process,
  so there is no `update-ca-certificates` step. Includes a Dockerfile and a deployment manifest.
- [`apm-tracing`](https://github.com/kicsipixel/oci-swift-sdk-examples/tree/main/apm-tracing) —
  the tracing recipe described above, worked out in full: OpenTelemetry spans exported to an
  **APM** domain over OTLP/HTTP with swift-otel, in two flavours (a long-running workload and an
  OCI Function) sharing one small `APMTracing` library, plus a record of what a real run against
  a live domain returned. Needs an APM domain and one of its data keys; nothing here runs
  without one.

## Skills

The [`.claude/skills/`](.claude/skills/) directory holds *agent skills*: packaged instructions
that an AI coding agent (Claude Code and compatible tools) loads on demand while working in this
repository, so that recurring jobs — adding a service client, recording a fixture, wiring up a
backend — follow this project's conventions instead of being reinvented each time. Each skill is
a single `SKILL.md`, and the description at the top of that file is what decides when it fires.
They are useful reading for humans too: each one is the long-form version of a workflow this
README can only summarize.

- [`oci-new-service-client`](.claude/skills/oci-new-service-client/SKILL.md) — scaffolds a
  brand-new OCI service client (router enum, client struct wired to the `HTTPClient` seam,
  `Codable` models, error enum) following the Container Instances reference implementation, then
  instruments it with credential-free unit tests and hermetic wire tests. Fires on "implement a
  new OCI service", "add the `<X>` client", "port `<X>` from the Python SDK".
- [`oci-capture-fixtures`](.claude/skills/oci-capture-fixtures/SKILL.md) — captures a real OCI
  wire response, and the request that produced it, into a committable JSON fixture under
  `Tests/Services/Fixtures`, using a live OCI config profile. Fires on "capture a real OCI
  response", "record a fixture from OCI", "grab the real wire response" for an operation.
- [`oci-wire-tests`](.claude/skills/oci-wire-tests/SKILL.md) — turns those fixtures into a
  hermetic replay suite that asserts request building and response decoding with no credentials
  and no network. Fires on "write wire tests for `<service>`", "add replay tests", "hermetic
  tests for `<operation>`".
- [`oci-logging-backend`](.claude/skills/oci-logging-backend/SKILL.md) — enables `OCILogHandler`
  end to end: prerequisites and IAM, the `LoggingSystem.bootstrap` composition, the full
  `OCILogHandlerConfiguration` surface, batcher lifecycle and shutdown flushing, and how to tell
  whether delivery actually works. Fires on "ship my app logs to OCI Logging", "set up
  OCILogHandler", "my logs never show up in OCI Logging".
- [`oci-metrics-backend`](.claude/skills/oci-metrics-backend/SKILL.md) — enables
  `OCIMetricsFactory` end to end: construction, `MetricsSystem.bootstrap`, the configuration
  surface, IAM, shutdown and verification. Fires on "send my metrics to OCI Monitoring",
  "publish custom metrics from Swift", "why are my metrics not showing up in Monitoring".

## License

[MIT License](https://github.com/iliasaz/oci-swift-sdk/blob/main/LICENSE)

Copyright (c) 2024 Ilia Sazonov

_**Oracle** is a registered trademark of **Oracle Corporation**. Any use of their trademark is under the established [trademark guidelines](https://www.oracle.com/legal/trademarks.html) and does not imply any affiliation with or endorsement by them, and all rights are reserved by them._

_**Swift** is a registered trademark of **Apple, Inc**. Any use of their trademark does not imply any affiliation with or endorsement by them, and all rights are reserved by them._
