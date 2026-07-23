---
name: oci-new-service-client
description: Scaffold a brand-new OCI service client in OCIKit — router enum, client struct wired to the HTTPClient seam, Codable models, error enum — following the ContainerInstances reference implementation, then instrument it with credential-free unit tests and hermetic wire tests. Use for "implement a new OCI service", "add the <X> service/client", "scaffold <X>Client", or "port <X> from the Python SDK".
---

# Scaffold a new OCI service client

Build a new service the same shape as `Sources/OCIKit/services/ContainerInstances/`
(read `ContainerInstances.swift`, `ContainerInstancesRouter.swift`, two or three
files under `Models/`, and `ContainerInstancesErrors.swift` before starting — they
are the ground truth for every pattern below). Replace `<Service>` with the real
service name throughout (e.g. `Secrets`, `IAM`).

## 0. Research first

- Find the operation list, request/response field names, and error shapes in the
  Python reference SDK at `~/Developer/oci-python-sdk` (`src/oci/<service>/`,
  `models/` and `*_client.py`).
- Cross-check paths, query params, and header names against the OCI REST API spec
  at https://docs.oracle.com/en-us/iaas/api/#/.
- If `<Service>` isn't yet a case in `Service` (`Sources/OCIKit/core/Region+Service.swift`),
  add it and its host mapping, e.g. `"<service>.\(region.urlPart).oraclecloud.com"`.

## 1. Create the service directory

`Sources/OCIKit/services/<Service>/`:

- **`<Service>Router.swift`** — a `<Service>API: API` enum, one case per operation
  holding its path/query/header params as associated values (optionals default to
  `nil`). Implement, exactly like `ContainerInstancesAPI`: `path: String` (switch
  over `self`, built from a `static let version` prefix); `method: HTTPMethod`
  (group cases by verb); `queryItems: [URLQueryItem]?` and `headers: [String:
  String]?` (build a `[(String, String?)]` pairs array, `compactMap` out nils,
  return `nil` if empty).

- **`<Service>.swift`** — `<Service>Client: Sendable` struct holding `endpoint:
  URL?`, `region: Region?`, `retryConfig: RetryConfig?`, `signer: Signer`,
  `logger: Logger`, and **`httpClient: HTTPClient`**. The `init` takes `httpClient:
  HTTPClient = .live` (defaulted, so no existing call site breaks) and resolves
  `endpoint` from either an explicit `endpoint:` string or `region` + `Service
  .<service>.getHost(in:)`, throwing `<Service>Error.missingRequiredParameter` if
  neither is given. One public `async` method per operation, each following: build
  the `<Service>API` case → `buildRequest(api:endpoint:)` → `try await signer.sign(&req)` →
  `try await httpClient.data(req)` → guard the status code, throwing `<Service>Error
  .unexpectedStatusCode` on mismatch → `JSONDecoder().decode(...)`. Route **every**
  send site through `httpClient.data(req)`, never `URLSession.shared.data(for:)`
  directly — that's what makes the client recordable and hermetically testable.
  Read response headers with `http.value(forHTTPHeaderField:)` (case-insensitive; a
  dictionary subscript on `allHeaderFields` breaks on Linux, which capitalizes
  header names differently than Darwin). Centralize execute/encode/decode
  boilerplate in `private` helpers, as `ContainerInstancesClient` does.

- **`Models/*.swift`** — one `Codable` struct/enum per file. For fields whose wire
  format needs translation (e.g. RFC3339 timestamps), store the raw string under a
  private `...Raw` property with a `CodingKeys` rename and expose a computed public
  property (see `ContainerInstance.timeCreatedRaw` / `.timeCreated`).

- **`<Service>Errors.swift`** — a `<Service>Error: Error` enum: `invalidResponse`,
  `invalidURL`, `jsonDecodingError`, `jsonEncodingError`, `missingRequiredParameter`,
  `unexpectedStatusCode(Int, String)`, plus `LocalizedError` with an
  `errorDescription` switch. Decode error bodies via the shared `DataBody` type,
  not a service-specific duplicate.

## 2. Naming and reuse

- Prefix any type name that collides across services: `WorkRequest` →
  `<Service>WorkRequest`. OCIKit is one module — there's no namespacing to fall
  back on.
- Reuse shared types instead of redefining them: `LifecycleState`, `SortOrder`,
  `DataBody`, `RetryConfig`.

## 3. Cross-platform rules

Every file touching `URLRequest`/`URLSession`/`HTTPURLResponse` needs:
```swift
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
```
Use async `URLSession.data(for:)` / `httpClient.data(req)`, never a completion
handler. For hashing/signing use `import Crypto` / `_CryptoExtras` (swift-crypto)
— never `CryptoKit`, which doesn't exist on Linux.

## 4. Instrument with unit tests (credential-free)

Add `Tests/Services/<Service>Test.swift`, mirroring `Tests/Services/SecretsTest.swift`
and `Tests/Services/ContainerInstancesTest.swift`. No `~/.oci/config`, no network,
`@testable import OCIKit`. One `struct` suite per concern:

- **`<Service>RouterTests`** — `.path`/`.method`/`.queryItems` (nils filtered)/
  `.headers` for representative cases; `buildRequest(api:endpoint:)` composes the
  full URL.
- **`<Service>EnumsTests`** — every enum's `.rawValue` matches the OCI wire string.
- **`<Service>ModelEncodingTests`** — `Encodable` payloads emit the right keys,
  including nested/polymorphic objects.
- **`<Service>ModelDecodingTests`** — `Decodable` round-trips of inline JSON
  fixtures (nested objects, enums, dates, polymorphic discriminators).

## 5. Instrument with wire tests (hand off)

Wire tests exercise the client's HTTP path (request building, signing, response
decoding) with no live network, via the `HTTPClient` seam — see
`docs/hermetic-wire-tests.md`.

1. Use skill **`oci-capture-fixtures`** to capture real `<Service>` responses into
   `Tests/Services/Fixtures/*.json`. Review and sanitize (OCIDs, names) before
   committing.
2. Use skill **`oci-wire-tests`** to write `Tests/Services/<Service>HermeticTests.swift`
   (the `StubSigner` + `actor RequestRecorder` + `makeClient` pattern from
   `ObjectStorageHermeticTests.swift`) and a fixture-replay test via `HTTPClient
   .replaying(fromFile:)` per `OCIFixtureReplayTests.swift`.

## 6. Wire into CI

Add every new suite type name to `UNIT_TEST_FILTER` in `.github/workflows/linux.yml`
(a pipe-separated OR regex). Compiling isn't enough — an unlisted suite builds but
never runs, so a real bug in it goes unnoticed.

## 7. Verify

```bash
swift build --build-tests
swift test --filter "<Service>RouterTests|<Service>EnumsTests|<Service>ModelEncodingTests|<Service>ModelDecodingTests|<Service>HermeticTests"

# Linux — also cross-check x86_64 via GitHub CI on the PR:
docker run --rm --platform linux/arm64 -v "$PWD":/pkg -w /pkg swift:6.2 \
  swift test --filter "<Service>RouterTests|<Service>HermeticTests"
```
If SwiftLint is installed, run it and fix everything before committing.

## Checklist

- [ ] Operations/shapes/errors verified against the Python SDK and REST API spec.
- [ ] `Service` enum has a host mapping for `<Service>` (if new).
- [ ] `<Service>Router.swift`, `<Service>.swift`, `Models/*.swift`,
      `<Service>Errors.swift` created.
- [ ] Client has `httpClient: HTTPClient = .live`; every send site uses it.
- [ ] Generic types prefixed per service; shared types reused, not duplicated.
- [ ] FoundationNetworking guard, Crypto (not CryptoKit), async URLSession.
- [ ] Unit suites added: Router/Enums/ModelEncoding/ModelDecoding.
- [ ] Fixtures captured (`oci-capture-fixtures`) + hermetic suite written (`oci-wire-tests`).
- [ ] New suite names added to `UNIT_TEST_FILTER` in `.github/workflows/linux.yml`.
- [ ] `swift build --build-tests` and new suites pass on macOS and Linux (Docker + CI).
