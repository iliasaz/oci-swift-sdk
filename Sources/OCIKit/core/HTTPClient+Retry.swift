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
//
// The shared execution path for all service clients: sign → send, with optional
// retries. The loop wraps *both* steps so every attempt is signed afresh — a
// replayed signature can fall outside OCI's ±5 minute clock-skew window after a
// long backoff, and instance/resource principal tokens can rotate between
// attempts. See https://github.com/iliasaz/oci-swift-sdk/issues/78.
//

import Foundation
import Logging

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

extension HTTPClient {
  /// Signs and performs `request`, retrying failed attempts per `retry`.
  ///
  /// Each attempt starts from the pristine, unsigned `request` and signs it anew,
  /// so `date` headers stay fresh and token-based signers can rotate credentials
  /// mid-sequence. A `401` from a ``RefreshableSigner`` triggers one immediate
  /// force-refresh-and-retry outside the retry budget, so requests ride through
  /// a token rotation that lands exactly at request time.
  ///
  /// When the retry budget is exhausted, the most recent response is returned
  /// (or the most recent transport error rethrown) — status-code handling stays
  /// with the calling operation, which maps it to its service-specific error.
  ///
  /// - Parameters:
  ///   - request: The unsigned request to perform.
  ///   - signer: The signer applied to every attempt, or `nil` for requests that
  ///     need no signature (e.g. pre-authenticated-request URLs).
  ///   - retry: The retry configuration; `nil` performs a single attempt.
  ///   - logger: Logger used to record retry decisions at debug level.
  public func send(
    _ request: URLRequest,
    signer: Signer?,
    retry: RetryConfig?,
    logger: Logger
  ) async throws -> (Data, URLResponse) {
    var attempt = 1
    var cumulativeDelay: TimeInterval = 0
    var refreshedAfter401 = false

    while true {
      var req = request
      if let signer {
        try await signer.sign(&req)
      }

      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await self.data(req)
      }
      catch {
        guard let retry, retry.isTransient(error), attempt < retry.maxAttempts else {
          throw error
        }
        let delay = retry.delay(forAttempt: attempt)
        guard cumulativeDelay + delay <= retry.maxCumulativeDelay else {
          throw error
        }
        logger.debug("Transient error on attempt \(attempt)/\(retry.maxAttempts), retrying in \(delay)s: \(error)")
        try await Task.sleep(for: .seconds(delay))
        cumulativeDelay += delay
        attempt += 1
        continue
      }

      guard let http = response as? HTTPURLResponse else {
        return (data, response)
      }

      // Auth failure with a refreshable signer: force a token refresh and retry
      // once immediately, outside the normal retry budget.
      if http.statusCode == 401, !refreshedAfter401, let refreshable = signer as? RefreshableSigner {
        refreshedAfter401 = true
        logger.debug("Received 401 on attempt \(attempt); forcing signer refresh and retrying once")
        try await refreshable.forceRefresh()
        continue
      }

      guard let retry, retry.retryableStatusCodes.contains(http.statusCode), attempt < retry.maxAttempts else {
        return (data, response)
      }
      let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(RetryConfig.retryAfterSeconds(from:))
      let delay = retry.delay(forAttempt: attempt, retryAfter: retryAfter)
      guard cumulativeDelay + delay <= retry.maxCumulativeDelay else {
        return (data, response)
      }
      logger.debug("HTTP \(http.statusCode) on attempt \(attempt)/\(retry.maxAttempts), retrying in \(delay)s")
      try await Task.sleep(for: .seconds(delay))
      cumulativeDelay += delay
      attempt += 1
    }
  }
}
