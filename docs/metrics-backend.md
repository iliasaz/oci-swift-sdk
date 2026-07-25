# Metrics backend: swift-metrics → OCI Monitoring

`OCIMetricsFactory` is a [swift-metrics](https://github.com/apple/swift-metrics) backend that
publishes an application's instruments to
[OCI Monitoring](https://docs.oracle.com/en-us/iaas/Content/Monitoring/Tasks/publishingcustommetrics.htm)
as custom metrics. `Counter`, `Gauge`, `Recorder` and `Timer` are aggregated in process and
posted with `PostMetricData` on a 60-second step; from there they are queryable, chartable and
alarmable next to the platform's own `oci_*` metrics.

Reach for it whenever you want application-level numbers — request rates, queue depths, handler
latencies — in the same place as your infrastructure metrics. **Application metrics are
self-export-only on every OCI runtime**: no agent, on any shape, collects them for you, so this
(or an OTLP exporter pointed at APM) is the only path.

- Per-runtime signer choice and copy-paste IAM policies:
  [`observability-deployment.md`](observability-deployment.md) §2–§3.
- The logs half of the same story: [`logging-backend.md`](logging-backend.md).
- Wire-level research behind every limit quoted here: [`../OBSERVABILITY.md`](../OBSERVABILITY.md) §2.2.
- Source of truth: [`../Sources/OCIKit/services/Monitoring/`](../Sources/OCIKit/services/Monitoring/).
- A deeper, task-oriented version of this guide, packaged for an AI coding agent working in
  this repo: [`.claude/skills/oci-metrics-backend`](../.claude/skills/oci-metrics-backend/SKILL.md).

All OCIDs below are placeholders — replace the bracketed/`EXAMPLE` values with your own.

---

## 1. Prerequisites

| You need | Why | What happens without it |
|---|---|---|
| A **compartment OCID** | Metric data is billed and queried per compartment; the service requires one on every metric object | `OCIMetricsConfiguration.init` throws `.missingCompartmentId` at start-up |
| A **namespace** matching `^[a-z][a-z0-9_]*[a-z0-9]$` | The service accepts lower case only, ≤ 256 characters, no `oci_`/`oracle_` prefix | `OCIMetricsConfiguration.init` throws `.invalidNamespace` at start-up |
| IAM `METRIC_WRITE` | `Allow dynamic-group <dg> to use metrics in compartment <compartment> where target.metrics.namespace='my_app'` | Every post fails **silently** — a `401`/`403` absorbed into a counter and a log line |
| A **signer** | Ingestion is standard OCI request signing; every OCIKit signer works | `MonitoringClient.init` throws only for a missing region/endpoint |

There is **no** log-group-equivalent to create: the namespace comes into existence with the
first accepted post. `swift_oke` and `my_app` are legal; `swift-oke` (hyphen), `MyApp`
(upper case) and `my_app_` (trailing underscore) are not — the last two were each live-verified
rejected with that exact pattern quoted back in the message. A policy edit can take ~15 minutes
to take effect on a runtime that caches its principal's token, such as Functions.

**swift-metrics in your own package.** OCIKit builds against the `CoreMetrics` product, so
`import CoreMetrics` gives you `MetricsSystem`, `Counter`, `Gauge`, `Recorder` and `Timer`
without adding anything. The `Metrics` façade — `Timer.measure`, `Timer.record(duration:)` —
lives in a separate module, so `import Metrics` fails unless *your* package declares it:

```swift
.package(url: "https://github.com/apple/swift-metrics.git", from: "2.11.0"),
// …and on your target:
.product(name: "Metrics", package: "swift-metrics"),
```

---

## 2. Bootstrap

```swift
import CoreMetrics
import Logging      // for the `Logger` handed to the factory
import OCIKit

let signer = try await InstancePrincipalSigner.fromMetadata()   // or any other signer — see the deployment guide
let client = try MonitoringClient(region: .phx, signer: signer)

let factory = OCIMetricsFactory(
  client: client,
  configuration: try OCIMetricsConfiguration(
    namespace: "my_app",                     // validated eagerly — throws here, not at flush time
    compartmentId: compartmentId,
    commonDimensions: ["service": "checkout", "env": "prod"]
  ),
  logger: Logger(label: "my_app.metrics")    // default: Logger(label: "OCIMetricsFactory")
)

await factory.start()                        // start the step loop
MetricsSystem.bootstrap(factory)             // exactly once per process — a second call traps

Counter(label: "http_requests_total", dimensions: [("route", "/orders/{id}")]).increment()

// before the process exits, so the last step is not lost:
await factory.shutdown()
```

`OCIMetricsFactory.init` does not throw; `OCIMetricsConfiguration.init` does, and eagerly, so a
process the service is going to reject fails at start-up rather than 60 seconds later on a
background task nobody is watching. Catch it and degrade to no metrics rather than failing to
start:

```swift
func makeMetricsFactory(signer: some Signer, compartmentId: String) async -> OCIMetricsFactory? {
  do {
    let factory = OCIMetricsFactory(
      client: try MonitoringClient(region: .phx, signer: signer),
      configuration: try OCIMetricsConfiguration(namespace: "my_app", compartmentId: compartmentId)
    )
    await factory.start()
    MetricsSystem.bootstrap(factory)
    return factory
  }
  catch {
    logger.error("metrics disabled: \(error)")   // .invalidNamespace / .missingCompartmentId / …
    return nil
  }
}
```

Ordering matters twice:

- **`start()` before `MetricsSystem.bootstrap`**, and both before anything records —
  swift-metrics latches its factory for the life of the process.
- **After `LoggingSystem.bootstrap`**, so the factory's logger writes through the finished
  logging system. Unlike the log backend, the exporter has *no* recursion guard: its warnings
  ship to OCI Logging like any other line, which is why it gets its own label.

The SDK never calls `MetricsSystem.bootstrap` itself — the process-global system belongs to the
application, which is free to multiplex this backend with another.

---

## 3. What each instrument becomes

One metric object per **stream** per step, where a stream is `kind + label + dimensions`.

| Instrument | Posted per step |
|---|---|
| `Counter` | One data point: the **delta** accumulated since the previous step. An untouched step posts nothing |
| `FloatingPointCounter` | As `Counter` — swift-metrics accumulates the fraction and forwards whole increments |
| `Recorder` | One data point per distinct value observed, carrying its occurrence `count` |
| `Gauge` | One data point: the most recent value, repeated every step until it changes |
| `Meter` | As `Recorder` — swift-metrics' default meter wrapper records into an aggregating recorder, so an untouched step posts nothing |
| `Timer` | As `Recorder`, in **nanoseconds**, with `metadata` `["unit": "ns"]` |

Only `makeCounter`, `makeRecorder` and `makeTimer` are implemented; `Meter` and
`FloatingPointCounter` are served by swift-metrics' protocol-provided wrappers, which is why
they inherit the aggregation of the instrument they wrap. Destroying an instrument keeps the
values it recorded since the last step, so its final partial step is still published.

Internalize the delta model: **cumulative totals come from the query**
(`http_requests_total[1m].sum()` over your window), not from the counter — which is also what
makes them survive a restart.

```swift
let dims = [
  ("route", route),                        // the route TEMPLATE, never the raw path
  ("method", method),                      // allow-listed
  ("status_class", "\(status / 100)xx"),   // the class, never the exact code
]
Counter(label: "http_requests_total", dimensions: dims).increment()
```

**Cardinality is your job.** Every distinct combination of dimension values mints its own
stream, and streams cost requests, money and query legibility. Never dimension by raw path,
object name, user id, or anything else caller-controlled. Idle streams cost nothing — an alarm
reads the gap as "no data".

### What gets coerced for you

swift-metrics constrains labels and dimensions not at all; `PostMetricData` does. Rather than
throw the application's data away, the backend coerces it:

- **Metric names** are forced to `^[a-zA-Z][a-zA-Z0-9_.$-]*[a-zA-Z0-9]$`, ≤ 255 characters:
  illegal characters become `_`, leading characters are dropped until it starts with a letter,
  trailing ones until it ends with a letter or digit. So `Counter(label: "login attempts")`
  posts as `login_attempts`, and `Timer(label: "http/server/duration")` as
  `http_server_duration`. A label with nothing salvageable posts as `unnamed_metric`.
- **Dimension keys** collapse runs of whitespace to `_` and truncate at 256 characters;
  **values** are trimmed and truncated at 512. An entry that ends up with an empty key or value
  is dropped.
- **A default dimension is synthesized** when a metric would otherwise have none — the service
  rejects an empty map with `400 "dimensions can not be null or empty"`, and swift-metrics
  instruments are routinely created with no dimensions at all. Default key `source`, default
  value the host name.
- **Dimensions are capped at 20**, the service limit, keeping the lexicographically-first keys
  so the choice is deterministic across steps and processes.
- **`NaN` and `±Infinity` are refused at the recording boundary** — they have no JSON
  representation — and counted in `droppedSamples`.

The two rules coercion cannot rescue are yours: the namespace (§1) and the 20-dimension cap.

---

## 4. The configuration surface

| Parameter | Default | Change it when |
|---|---|---|
| `namespace` | *(required)* | — |
| `compartmentId` | *(required)* | — |
| `resourceGroup` | `nil` | You group metrics by resource group in the Console |
| `commonDimensions` | `[:]` | Always worth setting: service, environment, instance. Sanitized once, here, and merged **over** an instrument's own dimensions on a key collision — operator labels application code cannot shadow |
| `defaultDimensionName` | `"source"` (`OCIMetricsConfiguration.fallbackDimensionName`) | Another key reads better for label-less metrics |
| `defaultDimensionValue` | `ProcessInfo.processInfo.hostName` | **On OKE virtual nodes the host name is `localhost` for every pod** — take the pod name from the downward API instead. Falls back to `"unknown"` if unusable |
| `step` | `.seconds(60)` | Rarely. 60 s is Monitoring's minimum aggregation interval and matches Oracle's own Micronaut/Helidon integrations; shortening it spends the tenancy's 50 TPS `PostMetricData` budget and buys nothing |
| `maximumBufferedStreams` | `500` | `droppedBufferedStreams` is climbing during outages. **This bounds the retry buffer only** — a step's fresh streams are always posted, however many there are |
| `maximumSamplesPerStream` | `1000` | `droppedSamples` is climbing: a recorder or timer sees more than 1,000 distinct values per step. Repeats of an already-seen value always count; only new distinct values are dropped |

```swift
try OCIMetricsConfiguration(
  namespace: "my_app",
  compartmentId: compartmentId,
  resourceGroup: nil,
  commonDimensions: ["service": "checkout", "env": "prod"],
  defaultDimensionName: OCIMetricsConfiguration.fallbackDimensionName,   // "source"
  defaultDimensionValue: podName,
  step: .seconds(60),          // Swift.Duration — spelled in full because OCIKit also
                               // exports an Object Storage lifecycle model named `Duration`
  maximumBufferedStreams: 500,
  maximumSamplesPerStream: 1000
)
```

The initializer throws `OCIMetricsError` — `.invalidNamespace`, `.missingCompartmentId`,
`.invalidStep`, `.invalidBufferBound`. Nothing is clamped; a bad value is a start-up failure.

### What a flush does

Worth knowing when reading the counters in §6:

1. Drain the registry; turn each stream into a `MetricDataDetails` timestamped at the instant of
   the snapshot.
2. Prepend anything the previous flush could not deliver. That carried-over set — and only it —
   is what `maximumBufferedStreams` bounds, applied as the buffer is written back at the end of
   the flush; a step's fresh streams are never dropped for being numerous.
3. Drop data points older than the service's **two-hour** window — it refuses them, so carrying
   them further would poison every retry.
4. Split into requests of at most **50 streams** (a 51st fails the whole request with
   `400 "The valid range is 1 to 50"`) and post them.
5. Read `failedMetrics` out of each `200`, and buffer for retry only the chunks that failed
   *transiently*.

Step 5 is the subtle one. **Partial failures arrive inside a `200`**: under the service's
default non-atomic batching the valid metric objects are ingested and the rejected ones come
back in the response body. Those rejections are permanent — the metric object violated an input
rule — so they are counted, logged, and dropped rather than retried. A thrown error is
classified the same way: a client-side encoding failure and any `4xx` other than `408`/`429`
are permanent (re-posting an identical payload would be rejected identically forever, burning
the tenancy's TPS budget); everything else goes back into the retry buffer.

---

## 5. Shut down without losing the step

`shutdown()` cancels the step task, **awaits** it, and then flushes, so no request is in flight
once it returns. Skipping it loses up to a full step — and the step task retains the factory, so
dropping the last reference does not stop it.

```swift
await factory.flush()      // mid-life: snapshot and publish now, without disturbing the cadence
await factory.shutdown()   // cancel the step task, await it, publish what is left
```

Drive it from your service lifecycle, exactly as with the log backend
([`logging-backend.md`](logging-backend.md) §4) —
[swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) 2.x is a
dependency of *your* package:

```swift
import ServiceLifecycle

// Spell `Service` in full — `import OCIKit` also brings one in (the OCI service catalogue).
struct MetricsFlushService: ServiceLifecycle.Service {
  let factory: OCIMetricsFactory

  func run() async throws {
    try await gracefulShutdown()   // parks until SIGTERM
    await factory.shutdown()
  }
}

// A `ServiceGroup` tears down in REVERSE array order — the flush service goes FIRST so it
// drains LAST. Listed after the server, it would flush mid-drain and lose everything after.
let group = ServiceGroup(
  services: [metricsFlush, server],
  gracefulShutdownSignals: [.sigterm],
  logger: logger
)
```

**Budget the grace period.** Unlike `OCILogBatcher`, `MonitoringClient` has no built-in request
timeout: it defaults to `HTTPClient.live`, so an unanswered `PostMetricData` inherits
`URLSession`'s 60-second default, and `shutdown()` can perform more than one request. If the
runtime enforces a termination grace period, bound the transport yourself — Linux's async
`URLSession` shim ignores cancellation, so this is the only bound that binds:

```swift
let client = try MonitoringClient(
  region: .phx,
  signer: signer,
  httpClient: HTTPClient { request in
    var request = request
    request.timeoutInterval = 5
    return try await HTTPClient.live.data(request)
  }
)
```

---

## 6. Failures are never thrown — `statistics()` is the only counter

> **Nothing on the export path throws.** A metrics backend that can take its application down is
> worse than one that loses a step, so every loss is absorbed and counted instead. A missing
> `use metrics` policy, a malformed dimension, a two-hour outage — none of them surfaces as an
> error to your code.

Unlike the log backend, the exporter is not *silent*: it has no recursion to guard against, so
it reports through the logger you handed it. Read the app's own logs first:

| Log line | Meaning |
|---|---|
| `[OCIMetricsExporter] postMetricData permanently rejected N stream(s), dropping them: …` | A `4xx` outside `408`/`429`, or an encoding failure. A missing `use metrics` policy surfaces here as the `401`/`403` text |
| `[OCIMetricsExporter] postMetricData failed for N stream(s), will retry: …` | Transient — buffered for the next step |
| `[OCIMetricsExporter] metric "x" rejected: <service message>` | One record refused **inside a `200`**; permanent, never retried |
| `[OCIMetricsExporter] dropped N datapoint(s) older than the service's 2-hour window` | The outage budget is spent |
| `[OCIMetricsExporter] dropped N buffered metric stream(s): the retry buffer is full` | `maximumBufferedStreams` reached |
| `[postMetricData] <code> (<status>): <message>` | From `MonitoringClient` itself, on any non-`200` |

`await factory.statistics()` is the only *counter*. All seven are `Int`, monotonic for the life
of the factory, and never reset — surface them where an operator reads them:

| Counter | Means |
|---|---|
| `postedStreams` | Metric streams the service accepted |
| `postedDatapoints` | Data points the service accepted |
| `failedMetrics` | Streams rejected permanently — inside a `200`, or by a permanently-failed request |
| `failedRequests` | Requests that failed outright: transport error, throttling, non-`200` |
| `droppedStaleDatapoints` | Data points that aged past the two-hour window |
| `droppedBufferedStreams` | Streams dropped because the retry buffer was full |
| `droppedSamples` | Observations dropped at the per-step distinct-value bound, or for being non-finite |

The asymmetry with logs is worth remembering: **metrics have a hard two-hour outage budget**
(`(now − 2h, now + 10m)`, strictly enforced and live-verified), where buffered log entries
survive for days. If `droppedStaleDatapoints` is non-zero, the outage outlasted what the service
will accept and that data is permanently unpostable.

---

## 7. Confirm delivery against the service

Counters tell you the service accepted the request. To confirm the metrics are queryable, ask
Monitoring. Allow 1–2 minutes after the first step. Your **own** user needs `read metrics` in
that compartment — a separate grant from the workload's `use metrics`.

```bash
# Which streams exist, and their dimension keys — the fastest cardinality check.
oci monitoring metric list \
  --compartment-id <compartment-ocid> \
  --namespace my_app \
  --all

# Read the datapoints back with an MQL query.
oci monitoring metric-data summarize-metrics-data \
  --compartment-id <compartment-ocid> \
  --namespace my_app \
  --query-text 'http_requests_total[1m].sum()' \
  --start-time 2026-07-22T00:00:00Z \
  --end-time   2026-07-22T01:00:00Z
```

The CLI is the read-back path because OCIKit ships **no query client**: `ListMetrics` and
`SummarizeMetricsData` live on a different host (`telemetry.{region}.oraclecloud.com`, versus
the ingestion host `telemetry-ingestion.{region}.oraclecloud.com`) and are deliberately out of
scope. The Console's Metrics Explorer works just as well.

A useful triage order when nothing shows up:

1. **`failedRequests > 0`** → read the exporter's log lines above. `401`/`403` means the policy;
   `400` usually means a request-level rule (more than 50 streams, or every metric object
   invalid).
2. **`failedMetrics > 0` with `failedRequests == 0`** → the service is rejecting individual
   metric objects inside a `200`. The `metric "x" rejected: …` line carries the service's own
   explanation.
3. **`postedStreams > 0` but `metric list` is empty** → wrong compartment or wrong namespace on
   the query side. The namespace has to match the configured one exactly.
4. **Everything zero** → the step has not fired yet (it is 60 seconds), or `start()` was never
   called, or `MetricsSystem.bootstrap` ran after the instruments were created.

For a probe with none of the aggregation machinery in the way, post directly:

```swift
import Foundation   // Date()
import OCIKit

let client = try MonitoringClient(region: .phx, signer: signer)
let response = try await client.postMetricData(
  details: PostMetricDataDetails(
    metricData: [
      MetricDataDetails(
        namespace: "my_app",
        compartmentId: compartmentId,
        name: "requests",
        dimensions: ["host": "worker-1"],
        metadata: ["unit": "count"],
        datapoints: [MonitoringDatapoint(timestamp: Date(), value: 42)]
      )
    ]
  )
)
if response.failedMetricsCount > 0 {
  logger.warning("\(response.failedMetricsCount) metric(s) rejected: \(response.failedMetrics ?? [])")
}
```

`MonitoringClient` is a faithful transport for one request — it does **not** chunk, sanitize, or
drop anything on your behalf, so a direct caller owns every limit in §3 and §4. It throws
`MonitoringError.unexpectedStatusCode(_:_:)` on a non-`200`, which is exactly what makes it a
better probe than the batched path. And it returns the decoded body rather than discarding it,
because checking only for a thrown error silently loses the partial failures.

---

## Notes

- **Region vs. endpoint.** `region: .phx` resolves to
  `https://telemetry-ingestion.us-phoenix-1.oraclecloud.com` (API version `20180401`) — note
  there is no `.oci.` segment, and it is a different host from the query side. Pass `endpoint:`
  to override; it takes precedence over `region:`.
- **`retryConfig:`** on `MonitoringClient` defaults to `nil` (no retries). The exporter's own
  step-to-step retry buffer covers transient failures, so adding client-level retries mostly
  lengthens `shutdown()`.
- **Cost.** The first 500 M data points per month are free, then $0.0025 per million —
  effectively free for anything this backend produces. Cardinality costs you query legibility
  long before it costs money.
- **Not a substitute.** OTLP metrics sent to an APM domain surface in Monitoring under the
  `oracle_apm_monitoring` namespace, but that path needs an APM domain plus its private data key
  and cannot use OCI principals. For traces — which OCI *does* ingest over OTLP — see the
  [`apm-tracing`](https://github.com/kicsipixel/oci-swift-sdk-examples/blob/main/apm-tracing/README.md)
  example.
