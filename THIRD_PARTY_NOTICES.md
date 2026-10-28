# Third-party notices

The offline About screen includes the unmodified license and NOTICE files for the exact resolved packages below. The files are packaged in both iOS and macOS application resources.

| Package | Version | Resolved source |
| --- | --- | --- |
| swift-argument-parser | 1.8.2 | [revision 6a52f3251125](https://github.com/apple/swift-argument-parser/tree/6a52f3251125d74daf04fcbd5e6f08a75d074382) |
| swift-asn1 | 1.7.3 | [revision 3b6410f7dee0](https://github.com/apple/swift-asn1/tree/3b6410f7dee09eb33cdd26260c5fd47fda19b0e2) |
| swift-atomics | 1.3.1 | [revision 0442cb5a3f98](https://github.com/apple/swift-atomics/tree/0442cb5a3f98ab802acb777929fdb446bda11a34) |
| swift-collections | 1.7.4 | [revision 844289ac4558](https://github.com/apple/swift-collections/tree/844289ac455816e193f1dbbe014f3c4dbe429410) |
| swift-crypto | 3.15.1 | [revision 95ba0316a9b7](https://github.com/apple/swift-crypto/tree/95ba0316a9b733e92bb6b071255ff46263bbe7dc) |
| swift-nio | 2.104.0 | [revision 6db9d9abd92a](https://github.com/apple/swift-nio/tree/6db9d9abd92ad7399b8a564cafbb87d3507245fa) |
| swift-nio-ssh | 0.13.0 | [revision 1a915a324afe](https://github.com/apple/swift-nio-ssh/tree/1a915a324afefd4031e396e81a0e210178621be8) |
| swift-system | 1.8.1 | [revision 869129b7bf4e](https://github.com/apple/swift-system/tree/869129b7bf4ecc57b97d0193ad29690ca2134750) |
| swiftterm | 1.11.2 | [revision b1262db5b6be](https://github.com/migueldeicaza/SwiftTerm/tree/b1262db5b6bea699a8260a8c66999436c508ca56) |

License files and SHA-256 digests: [`SovaGrid/LegalResources/ThirdParty/manifest.json`](SovaGrid/LegalResources/ThirdParty/manifest.json). SwiftTerm uses MIT; the listed Swift packages use Apache 2.0. Retain each supplied NOTICE file.

This list conservatively includes all resolved packages. Swift Argument Parser is a dependency of SwiftTerm’s separate Termcast executable and is not linked into this application. SwiftNIO’s optional llhttp license is retained even though the SSH client does not link CNIOLLHTTP. Swift Crypto uses Apple CryptoKit on Darwin; its non-Darwin BoringSSL target is not linked into these builds.
