// SPDX-License-Identifier: AGPL-3.0-only
// SovaGrid — Copyright (C) 2026 Jigokuraku01
// Additional attribution terms: see ATTRIBUTION.md.

import Foundation

@main
enum ProfileExportPayloadTests {
    static func message(version: Any = 1, filename: Any = "server-phone.conf", data: Any = "QQ",
                        extra: [String: Any] = [:]) -> String {
        let object: [String: Any] = ["version": version, "filename": filename, "data": data]
            .merging(extra) { _, new in new }
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    static func main() {
        let good = ProfileExportPayload.parse(message())
        precondition(good?.filename == "server-phone.conf")
        precondition(good?.data == Data([65]))
        for amneziaName in ["amnezia-awg2-phone.conf", "amnezia-wireguard-phone.conf"] {
            precondition(ProfileExportPayload.parse(message(filename: amneziaName))?.filename
                         == amneziaName)
        }

        let biggest = Data(repeating: 65, count: 16_384)
        let biggestEncoded = biggest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        precondition(ProfileExportPayload.parse(message(filename: "ab-c_1.conf", data: biggestEncoded))?.data
                     == biggest)

        for invalid in [
            message(version: true), message(version: 2), message(version: 1.5),
            message(filename: "../server-phone.conf"), message(filename: "A-phone.conf"),
            message(filename: "server-../phone.conf"), message(filename: "server-phone.txt"),
            message(data: "QQ=="), message(data: "QR"), message(data: "Q"), message(data: ""),
            message(data: String(repeating: "QQ", count: 11_000)),
            message(extra: ["command": "cat /etc/shadow"]), "[]", "not JSON"
        ] {
            precondition(ProfileExportPayload.parse(invalid) == nil)
        }
        precondition(ProfileExportPayload.parse(message(data: Data(repeating: 65, count: 16_385)
            .base64EncodedString().replacingOccurrences(of: "=", with: ""))) == nil)
        print("ProfileExportPayload: valid bounds and rejection cases passed")
    }
}
