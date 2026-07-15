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
- [ ] OKE Workload Identity authN (planned — needs custom-CA TLS to the in-cluster proxymux)
- [x] Object Storage
- [x] Container Instances
- [x] GenAI inference (custom models)
- [x] Identity & Access Management (compartments)
- [x] Secrets (secret bundles)
- [x] AI Language (health entity detection)

## License

[MIT License](https://github.com/iliasaz/oci-swift-sdk/blob/main/LICENSE)

Copyright (c) 2024 Ilia Sazonov

_**Oracle** is a registered trademark of **Oracle Corporation**. Any use of their trademark is under the established [trademark guidelines](https://www.oracle.com/legal/trademarks.html) and does not imply any affiliation with or endorsement by them, and all rights are reserved by them._

_**Swift** is a registered trademark of **Apple, Inc**. Any use of their trademark does not imply any affiliation with or endorsement by them, and all rights are reserved by them._
