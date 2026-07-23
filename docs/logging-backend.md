# Logging backend: swift-log → OCI Logging

`OCILogHandler` is a [swift-log](https://github.com/apple/swift-log) backend that ships your
application's log records to an OCI
[custom log](https://docs.oracle.com/en-us/iaas/Content/Logging/Concepts/custom_logs.htm).
Bootstrap it once at start-up and the rest of the code keeps using plain `Logger` values —
nothing downstream of the bootstrap knows OCI is involved.

Reach for it when the platform will not collect your logs for you: **Container Instances**
(no agent, no sidecar — the platform's `RetrieveLogs` is view-only), **Compute E2.1.Micro**
(the Logging agent plugin is shape-gated), **OKE** where you'd rather ship structured records
than tail `/var/log/containers/*`, or any process whose records must land in Logging without a
file on disk in between. On Functions the platform already captures stdout/stderr, so the
handler is worth adding only for records you want under your own log OCID and `type`.

- Per-runtime signer choice and copy-paste IAM policies:
  [`observability-deployment.md`](observability-deployment.md) §2–§3.
- The metrics half of the same story: [`metrics-backend.md`](metrics-backend.md).
- Wire-level research behind every limit quoted here: [`../OBSERVABILITY.md`](../OBSERVABILITY.md) §2.1.
- Source of truth: [`../Sources/OCIKit/services/LoggingIngestion/`](../Sources/OCIKit/services/LoggingIngestion/).
- A deeper, task-oriented version of this guide, packaged for an AI coding agent working in
  this repo: [`.claude/skills/oci-logging-backend`](../.claude/skills/oci-logging-backend/SKILL.md).

All OCIDs below are placeholders — replace the bracketed/`EXAMPLE` values with your own.

---

## 1. Prerequisites — none of them are checked at runtime

| You need | Why | What happens without it |
|---|---|---|
| A **custom log OCID** | `PutLogs` ingests into an existing log; the log group and the log are control-plane resources OCIKit has no client for | The batcher constructs happily and every flush fails **silently** |
| IAM `LOG_CONTENT_PUSH` | `Allow dynamic-group <dg> to use log-content in compartment <compartment>` | Same — a `404 NotAuthorizedOrNotFound` absorbed into a counter |
| A **signer** | Ingestion is standard OCI request signing; every OCIKit signer works | `init` throws only for a missing region/endpoint, never for a bad principal |

Create the log group and the log with Terraform, the OCI Console, or the CLI, then pass the
log's OCID as configuration rather than a literal. On Functions, the resource principal's token
is cached for ~15 minutes, so a policy edit is not live immediately.

The only thing `OCILogBatcher.init` throws is
`LoggingIngestionError.missingRequiredParameter` — and only when you supply neither `region:`
nor `endpoint:`. Everything else fails later, quietly, into `statistics`. That is §5.

---

## 2. Bootstrap

Build the batcher first: swift-log calls the bootstrap closure once per logger label, and every
handler it creates shares this one batcher.

```swift
import Logging
import OCIKit

let signer = try await InstancePrincipalSigner.fromMetadata()   // or any other signer — see the deployment guide

let batcher = try OCILogBatcher(
  configuration: OCILogHandlerConfiguration(
    logId: "ocid1.log.oc1.phx.EXAMPLE",      // an existing custom log
    type: "com.example.orders"
  ),
  region: .phx,                              // or `endpoint:` instead
  signer: signer
)

// Keep the console handler: it is how you debug the process when the OCI half is
// the broken half.
LoggingSystem.bootstrap { label in
  MultiplexLogHandler([
    StreamLogHandler.standardOutput(label: label),
    OCILogHandler(label: label, batcher: batcher, logLevel: .info),
  ])
}

Logger(label: "com.example.orders").info("order placed", metadata: ["orderId": "1234"])

// Before the process exits, so buffered records are not lost:
await batcher.shutdown()
```

`import Logging` resolves through OCIKit's own swift-log dependency, so no extra package is
needed (declaring swift-log in your own manifest is tidier, and harmless).

Two ordering rules:

- **The SDK never calls `LoggingSystem.bootstrap`** — a process-global system belongs to the
  application, which is free to multiplex this backend with any other. That is also why
  `MultiplexLogHandler` above is the recommended shape rather than an aside.
- **Bootstrap before any framework builds its own `Logger`** (Hummingbird, Vapor, your own
  `Logger` globals). swift-log latches its factory on the first call and traps on a second, so
  a logger created before the bootstrap keeps the default handler for the life of the process.

`OCILogHandler.init(label:batcher:logLevel:metadata:metadataProvider:)` defaults `logLevel` to
`.info`, `metadata` to empty, and `metadataProvider` to `nil`.

### What a record looks like on the wire

The handler renders on the caller's thread, in a layout that mirrors swift-log's own
`StreamLogHandler` so a record read in the OCI Console looks like the record read on the
console — except the timestamp is RFC3339 (matching the entry's `time`) and there is no
trailing newline:

```
2026-07-21T15:49:00.123Z info com.example.orders : orderId=1234 [Orders] order placed
```

Metadata is merged handler → provider → call-site (increasing precedence) and rendered as
`key=value` pairs sorted by key, so a record's text is stable across runs. Each `LogEntry`
carries its own `time` — when the application logged, not when the batch flushed — and the
batch carries `source`, `type`, `subject`, and a `defaultlogentrytime` of the flush instant.

---

## 3. The configuration surface

Only `logId` is required. Out-of-range values are **clamped, not rejected**, so a bad number
degrades rather than throwing.

| Parameter | Default | Change it when |
|---|---|---|
| `logId` | *(required)* | — |
| `source` | `defaultSource` — `ProcessInfo.processInfo.hostName` | The hostname is not the identity you want in the Console. **On OKE virtual nodes the hostname is `localhost` for every pod** — take the pod name from the downward API instead |
| `type` | `defaultType` — `"oci-swift-sdk.application"` | Always: use something that identifies the application, e.g. `"com.example.orders"` |
| `subject` | `nil` | You want the sub-resource the events came from recorded per batch |
| `flushInterval` | `5` seconds | This is your ingestion lag. `0` (and any negative value, clamped to `0`) disables the ticker, leaving only the size threshold and explicit `flush()` |
| `flushSizeThreshold` | `1 << 20` (1 MiB of buffered UTF-8) | Rarely. `PutLogs` accepts 1 MiB → 1 GiB with no silent drops, so this bound is ergonomics — it caps retry amplification and per-flush upload latency |
| `bufferCapacity` | `10_000` records | `statistics.dropped` is climbing: the buffer is too small for the burst rate |
| `maxEntryLength` | `9_900` characters (clamped into `1...10_000`) | Rarely — see below |
| `requestTimeout` | `10` seconds per attempt | You need a tighter or looser bound on `shutdown()`. `0` leaves the transport's own timeout, which for `URLSession` is 60 s |
| `retryConfig` | `RetryConfig(maxAttempts: 3, baseDelay: 0.5, maxDelay: 5, maxCumulativeDelay: 10)` | Same reason. `nil` performs a single attempt per flush |
| `excludedLoggerLabels` | `["OCIKit"]` | You have a noisy label to silence. Your set is **unioned** with the default, never replacing it |

```swift
OCILogHandlerConfiguration(
  logId: "ocid1.log.oc1.phx.EXAMPLE",
  source: podName,
  type: "com.example.orders",
  subject: "order-service",
  flushInterval: 5,
  flushSizeThreshold: 1 << 20,
  bufferCapacity: 10_000,
  maxEntryLength: 9_900,
  requestTimeout: 10,
  retryConfig: RetryConfig(maxAttempts: 3, baseDelay: 0.5, maxDelay: 5, maxCumulativeDelay: 10),
  excludedLoggerLabels: ["com.example.noisy"]
)
```

Three of these deserve more than a table row.

**`maxEntryLength` exists because the service truncates silently.** Any entry `data` longer
than 10,000 characters comes back HTTP 200 and is stored cut to exactly 10,000 characters
ending in `...` (live-verified). The batcher therefore splits longer records into consecutive
entries client-side, in order, so the parts read contiguously. A consequence:
`statistics.submitted` counts **entries**, not records.

**`requestTimeout` × `retryConfig` is the bound on `shutdown()`** —
`maxAttempts × requestTimeout + maxCumulativeDelay`, which is 40 seconds with the defaults.
Shrink both if your runtime enforces a tighter termination grace period.

**`excludedLoggerLabels` is one half of the recursion guard.** Shipping logs produces logs, and
a backend that shipped its own would never converge. Three mechanisms keep it from happening,
and none of them is optional:

1. The batcher's internal `LoggingIngestClient` writes to a private no-op backend, bypassing
   the bootstrapped `LoggingSystem` entirely, whatever the application bootstrapped.
2. A task-local `isFlushing` is bound around the `PutLogs` call and inherited by the whole async
   call tree it drives — a custom `HTTPClient`, a custom `Signer`, retry logic, any third-party
   code on the request path. Records offered while it is set are discarded, whatever their label.
3. `excludedLoggerLabels` covers code that logs through the bootstrapped system *outside* a
   flush — notably the SDK's own global `logger`, label `"OCIKit"`, which the signer writes to
   on every signing pass. `"OCIKit"` is unioned in by the initializer and re-checked by the
   batcher, so it cannot be removed.

---

## 4. Flush on shutdown, or lose the buffer

`log(...)` never blocks and never performs I/O: it renders the record and hands it to a bounded
buffer. The `OCILogBatcher` actor drains that buffer and uploads batches with `PutLogs` — on the
size threshold, on the interval tick, or when you call `flush()`/`shutdown()` — keeping at most
one request in flight. `init` starts the drain and ticker tasks immediately, and those tasks
retain the batcher: **dropping the last reference does not stop it.** `shutdown()` does.

```swift
await batcher.flush()      // mid-life: upload everything logged before this call
await batcher.shutdown()   // stop accepting, drain, upload, end both tasks; idempotent
```

`flush()` waits for records still in transit between `enqueue` and the buffer before uploading,
so a flush issued right before exit ships them too. `shutdown()` is idempotent; after it
returns, further records are discarded and counted in `statistics.dropped` — which is expected
on a clean exit, not a defect.

Skipping `shutdown()` loses up to `bufferCapacity` records, including the ones explaining why
the process is going away. Drive it from your service lifecycle rather than a signal handler —
[swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) 2.x is a
dependency of *your* package; OCIKit does not ship it:

```swift
import ServiceLifecycle

// Spell `Service` in full — `import OCIKit` also brings one in (the OCI service catalogue).
struct TelemetryFlushService: ServiceLifecycle.Service {
  let batcher: OCILogBatcher

  func run() async throws {
    try await gracefulShutdown()   // parks here until the group starts shutting down
    await batcher.shutdown()       // waits for the final PutLogs
  }
}

// A `ServiceGroup` tears down in REVERSE array order — put the flush service FIRST
// so it drains LAST, once the server has stopped and logged its final line.
let group = ServiceGroup(
  services: [flushService, server],
  gracefulShutdownSignals: [.sigterm],
  logger: logger
)
```

---

## 5. Failures are never thrown — `statistics` is the only signal

This is the single most confusing thing about the backend, so it is worth stating flatly:

> **Nothing on the export path throws, and nothing on the export path is logged.** A wrong log
> OCID, a missing `use log-content` policy, an unreachable endpoint, a `429` storm — all of them
> look exactly like a healthy application from the outside.

The reason is structural: a log backend cannot report its own errors through the logging system
it implements without producing the very records it just failed to ship. So the batcher swallows
every failure into counters, and reading them is the *only* way to learn that logs are being
lost. `batcher.statistics` is a `nonisolated` snapshot — no `await` — so it is cheap to expose
from a health endpoint or to dump at shutdown.

```swift
let stats = batcher.statistics
logger.info(
  "log delivery",
  metadata: [
    "enqueued": .stringConvertible(stats.enqueued),          // accepted into the hand-off buffer
    "submitted": .stringConvertible(stats.submitted),        // entries the service accepted
    "dropped": .stringConvertible(stats.dropped),            // buffer full, or logged post-shutdown
    "failed": .stringConvertible(stats.failed),              // entries permanently lost
    "flushFailures": .stringConvertible(stats.flushFailures),
    "lastFlushError": .string(stats.lastFlushErrorDescription ?? "none"),
  ]
)
```

If you dump them *after* `shutdown()`, that line reaches the console only — the handler discards
records once the batcher has stopped, and counts them in `dropped`.

How to read them:

| Signal | Means | Do |
|---|---|---|
| `dropped > 0` | The hand-off buffer was full (the buffer keeps the **oldest** records, so a drop discards the newest), or the record was logged after `shutdown()` | Raise `bufferCapacity`, or ignore if it is only the tail of a clean exit |
| `flushFailures > 0`, `failed == 0` | Flushes are failing but recovering — a failed batch goes back to the head of the buffer and a later flush retries it | Read `lastFlushErrorDescription`; the records are not lost yet |
| `failed > 0` | Entries permanently lost: the re-buffered backlog outgrew `bufferCapacity` (oldest dropped), or `shutdown()`'s final flush failed with nothing left to retry it | Fix the underlying error; consider a larger `bufferCapacity` or a longer grace period |
| `submitted` climbing | Working. Note it counts **entries**, so a long split record adds several | — |

A failed batch is not discarded, which matters more than it sounds: the service applies **no
clock-skew rejection at all**, so entries as old as the log's retention window land and index at
their claimed time (anything older returns HTTP 200 and is dropped). Records buffered across an
outage therefore survive for days. The drop policy is capacity-driven, never staleness-driven —
the opposite of the metrics backend, which has a hard two-hour budget.

`lastFlushErrorDescription` holds the raw error description, service response body included.
Reduce it to the error's case name before serving it on an unauthenticated endpoint.

---

## 6. Confirm delivery against the service

Counters tell you the service accepted the request. To confirm the entries are actually
queryable, read them back with the OCI CLI. Your **own** user needs `read log-content` in that
compartment — a separate grant from the workload's `use log-content`.

```bash
oci logging-search search-logs \
  --search-query 'search "<compartment-ocid>/<log-group-ocid>/<log-ocid>" | sort by datetime desc' \
  --time-start 2026-07-22T00:00:00Z \
  --time-end   2026-07-22T01:00:00Z \
  --limit 20
```

Allow a little time before concluding anything: end-to-end latency at the default 5-second
`flushInterval` was measured in single-digit seconds during live verification, but Search
indexing adds its own lag — give it a minute before deciding a record is missing.

A useful triage order when nothing shows up:

1. **`statistics.submitted == 0` and `flushFailures > 0`** → the request is failing.
   `lastFlushErrorDescription` names the reason — and note that a wrong log OCID and a missing
   `use log-content` policy both typically surface as the same `404 NotAuthorizedOrNotFound`.
2. **`submitted > 0` but the search is empty** → you are querying the wrong log, the wrong
   compartment, or a window that does not contain the entry's `time` (which is when the record
   was *logged*, not when it was flushed).
3. **Nothing at all in `statistics`** → the handler is not in the bootstrapped chain: check that
   `LoggingSystem.bootstrap` ran before the `Logger` was created, and that the label is not in
   `excludedLoggerLabels`.

For a probe with none of the batching machinery in the way, call `PutLogs` directly — that is
what `Tests/Services/LoggingIngestionLiveTest.swift` does:

```swift
import Foundation   // Date()
import OCIKit

let client = try LoggingIngestClient(region: .phx, signer: signer)
try await client.putLogs(
  logId: "ocid1.log.oc1.phx.EXAMPLE",
  details: PutLogsDetails(
    logEntryBatches: [
      LogEntryBatch(
        entries: [LogEntry(data: "hello from Swift")],
        source: "my-host",
        type: "com.example.orders",
        defaultlogentrytime: Date()
      )
    ]
  )
)
```

`putLogs` returns nothing — the service answers HTTP 200 with an empty body — and **does**
throw, unlike the batched path: `LoggingIngestionError.unexpectedStatusCode(_:_:)` carries the
service's own code and message. That is exactly why it makes a better probe.

---

## Notes

- **Region vs. endpoint.** `region: .phx` resolves to
  `https://ingestion.logging.us-phoenix-1.oci.oraclecloud.com` (API version `20200831`). Pass
  `endpoint:` instead to override; it takes precedence over `region:`.
- **`httpClient:`** defaults to `HTTPClient.live`. Whenever `requestTimeout` is positive the
  batcher wraps whatever you pass so every request carries it as `timeoutInterval` —
  cancellation is not a usable bound here, because the Linux `URLSession` async shim does not
  cancel its underlying task.
- **Structured logs.** When a record's `data` is JSON, the service indexes it as a structured
  log: at most 10,000 fields, names ≤ 128 bytes, values ≤ 10,000 bytes. The default renderer
  emits text, so this only applies if you render JSON yourself.
- **What this backend is not.** There is no Logging *Search* client and no Log Analytics client
  in OCIKit — reading logs back is the CLI/Console path above. `PutLogs` is the whole ingestion
  surface, and OCI Logging has no OTLP endpoint, so an OTLP logs exporter cannot target it.
