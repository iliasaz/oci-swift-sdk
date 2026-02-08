// swift-tools-version: 6.2
// Copyright 2024 Ilia Sazonov
// SPDX-License-Identifier: MIT License

import PackageDescription

let package = Package(
  name: "oci-swift-sdk",
  platforms: [
    .macOS(.v15),
    .iOS(.v18),
  ],
  products: [
    .library(name: "OCIKit", targets: ["OCIKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.2.0"),
    .package(url: "https://github.com/iliasaz/Perfect-INIParser.git", branch: "master"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0"),
  ],
  targets: [
    .target(
      name: "OCIKit",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "_CryptoExtras", package: "swift-crypto"),
        .product(name: "INIParser", package: "Perfect-INIParser"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "Configuration", package: "swift-configuration"),
      ]
    ),
    .testTarget(
      name: "Tests on Linux",
      dependencies: ["OCIKit"],
      path: "Tests/Linux"
    ),
    .testTarget(
      name: "OCIKitCoreTests",
      dependencies: ["OCIKit"],
      path: "Tests/OCIKit"
    ),
    .testTarget(
      name: "OCIKitServiceTests",
      dependencies: ["OCIKit"],
      path: "Tests/Services"
    ),
  ]
)
