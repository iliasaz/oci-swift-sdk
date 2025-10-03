//===----------------------------------------------------------------------===//
//
// This source file is part of the oci-swift-sdk open source project
//
// Copyright (c) 2025 Szabolcs Tóth and the oci-swift-sdk project authors
// Licensed under MIT License
//
// See LICENSE for license information
// See CONTRIBUTORS.md for the list of oci-swift-sdk project authors
//
// SPDX-License-Identifier: MIT License
//
//===----------------------------------------------------------------------===//

import Foundation

public struct Duration: Codable {
    /// The timeAmount is interpreted in units defined by the timeUnit parameter, and is calculated in relation to each object's Last-Modified timestamp.
    public let timeAmount: Int
    /// The unit that should be used to interpret timeAmount.
    public let timeUnit: TimeUnit
    
    public init(timeAmount: Int, timeUnit: TimeUnit) {
        self.timeAmount = timeAmount
        self.timeUnit = timeUnit
    }
}

public enum TimeUnit: String, Codable {
    case years = "YEAR"
    case days = "DAYS"
}
