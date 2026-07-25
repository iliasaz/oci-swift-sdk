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

/// Bookkeeping for a signer's single-flight credential exchange.
///
/// Held as actor-isolated state by the token signers, which coalesce concurrent
/// refreshes onto one network exchange. All mutation is synchronous, so callers
/// keep their `await`s in their own actor-isolated methods and this type never
/// has to reason about isolation itself.
///
/// ## Why counters rather than "is `task` non-nil"
///
/// A plain `Task?` cannot answer "is an exchange running": it stays non-nil after
/// the task completes until somebody clears it, and it is cleared early if the
/// caller that started it is cancelled (an unstructured `Task` does not inherit
/// cancellation, so the exchange outlives the caller that was awaiting it). Both
/// gaps let a second exchange start while the first is still running, and the
/// older one can then land last and overwrite newer credentials.
///
/// ``started`` and ``completed`` close that: an exchange is running exactly while
/// `started > completed`, and only the exchange itself moves `completed`.
///
/// ## The ordering that makes this safe
///
/// ``finish()`` must be called from the exchange body's own `defer`, inside the
/// actor. That way `completed` is updated as the body returns — strictly before
/// any `await task.value` awaiter is resumed — so a caller that waits out an
/// exchange always observes it as finished on resume, and cannot spin.
struct SingleFlightExchange {
  /// Why an exchange was started, which decides who may join it.
  enum Kind {
    /// A proactive refresh: the cache was empty or past its half-life.
    case routine
    /// A refresh forced by an authentication failure, so its credential material
    /// was read *after* some `401`.
    case forced
  }

  /// Number of exchanges started. Also serves as a generation counter: a caller
  /// can snapshot it and later tell whether the running exchange began after it.
  private(set) var started = 0
  /// Number of exchanges finished, successfully or not.
  private(set) var completed = 0
  /// The running exchange, if any. Only meaningful while ``isRunning``.
  private(set) var task: Task<Void, Error>?
  /// Why the current exchange was started.
  private(set) var kind: Kind = .routine

  /// Whether an exchange is currently running.
  var isRunning: Bool { started > completed }

  /// The running exchange, or `nil` when nothing is in flight.
  var running: Task<Void, Error>? { isRunning ? task : nil }

  /// Records that `task` has begun.
  mutating func begin(_ task: Task<Void, Error>, kind: Kind) {
    started += 1
    self.task = task
    self.kind = kind
  }

  /// Records that the running exchange has finished. Call from the exchange
  /// body's `defer` so it runs on both success and failure.
  mutating func finish() {
    completed += 1
    task = nil
  }
}
