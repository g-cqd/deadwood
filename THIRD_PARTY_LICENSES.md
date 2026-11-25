# Third-Party Licenses

All external (non-`g-cqd` / non-`Aemi-Studio`) dependencies in the resolved build graph are official Apple / Swift.org open-source packages licensed under the **Apache License 2.0** (with Runtime Library Exception where noted), plus OpenLDAP Public License 2.8 for LMDB (`swift-lmdb`):

| Package | Repository | License |
| --- | --- | --- |
| `swift-syntax` | https://github.com/swiftlang/swift-syntax | Apache-2.0 with Runtime Library Exception |
| `swift-argument-parser` | https://github.com/apple/swift-argument-parser | Apache-2.0 with Runtime Library Exception |
| `swift-collections` | https://github.com/apple/swift-collections | Apache-2.0 with Runtime Library Exception |
| `swift-system` | https://github.com/apple/swift-system | Apache-2.0 with Runtime Library Exception |
| `swift-subprocess` | https://github.com/swiftlang/swift-subprocess | Apache-2.0 with Runtime Library Exception |
| `swift-crypto` | https://github.com/apple/swift-crypto | Apache-2.0 |
| `swift-asn1` | https://github.com/apple/swift-asn1 | Apache-2.0 |
| `indexstore-db` | https://github.com/swiftlang/indexstore-db | Apache-2.0 with Runtime Library Exception |
| `swift-lmdb` | https://github.com/swiftlang/swift-lmdb | Apache-2.0 / OpenLDAP Public License 2.8 (LMDB) |

Internal family dependencies (`aemi`, `AemiRegex`, `AemiJSON`, `AemiProtobuf`, `analyzerkit`) are licensed under the **MIT License**.
