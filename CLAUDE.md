# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

oci-swift-sdk is a community-maintained Swift SDK for Oracle Cloud Infrastructure (OCI). It provides Swift access to OCI services across Linux, macOS, and iOS. Not affiliated with Oracle.

## Build & Test Commands

```bash
# Build
swift build

# Run all tests (requires OCI credentials in ~/.oci/config)
swift test

# Run a specific test target
swift test --filter OCIKitCoreTests
swift test --filter OCIKitServiceTests

# Run a single test
swift test --filter OCIKitServiceTests.ObjectStorageTest/copiesObjectWithinRegionWithAPIKeySigner

# Format code (uses .swift-format config)
swift format --in-place --recursive Sources/ Tests/
```

Tests are integration tests that require real OCI credentials. Environment variables:
- `OCI_CONFIG_FILE` — path to OCI config (default: `~/.oci/config`)
- `OCI_PROFILE` — config profile name (default: `DEFAULT`)

## Code Style

- Swift 6.1+, platforms: macOS 13+, iOS 17+
- 2-space indentation, 200-char line length (see `.swift-format`)
- Line break before control flow keywords and before each argument
- Use `async/await` concurrency (no callbacks)
- Linux compatibility: guard `#if canImport(FoundationNetworking)` where URLSession is used

## Architecture

### Single library target: OCIKit

**Core layer** (`Sources/OCIKit/core/`):
- `Signer` protocol — abstraction for OCI request authentication. Implementations: `APIKeySigner`, `InstancePrincipalSigner`, `SecurityTokenSigner`
- `RequestSigner` — static RSA-SHA256 signing logic (PKCS1v1.5) shared by all signers
- `SignerConfiguration` — parses INI-formatted OCI config files and extracts PEM private keys
- `Region+Service` — enum of all OCI regions with service endpoint URL construction

**Services layer** (`Sources/OCIKit/services/`):
Each service follows a consistent pattern:
1. **Router** (e.g., `ObjectStorageRouter.swift`) — enum conforming to the `API` protocol, defining path/method/query/headers per operation
2. **Client** (e.g., `ObjectStorage.swift`) — struct with `region`, `signer`, `endpoint`, `logger`; methods are `async throws` and return decoded models
3. **Models** — `Codable` structs for request/response payloads
4. **Errors** — enum conforming to `LocalizedError`
5. **`BuildRequest.swift`** — shared function that assembles a `URLRequest` from an `API` route and base endpoint

Current services: Object Storage, IAM, Secrets Retrieval, Generative AI, Language.

### Adding a new service

Follow the existing pattern: create a subdirectory under `Sources/OCIKit/services/` with a Router enum (conforming to `API`), a Client struct, model types, and an error enum. Use `buildRequest(api:endpoint:)` to construct requests, then sign with `signer.sign(&request)`.

### Test targets

- `OCIKitCoreTests` (`Tests/OCIKit/`) — core/auth tests
- `OCIKitServiceTests` (`Tests/Services/`) — per-service integration tests
- `Tests on Linux` (`Tests/Linux/`) — Linux platform-specific tests

Tests use Swift's `Testing` framework (`@Test`, `#expect`) with `@testable import OCIKit`.

### Dependencies

- `swift-crypto` — RSA signing and SHA256
- `Perfect-INIParser` — OCI config file parsing
- `swift-log` — logging (global `logger` instance in `Signer.swift`)
