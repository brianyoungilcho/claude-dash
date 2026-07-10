#!/usr/bin/env swift

import CryptoKit
import Foundation

guard let encoded = ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_ED_KEY"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let seed = Data(base64Encoded: encoded),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    fputs("SPARKLE_PRIVATE_ED_KEY is not a valid Ed25519 private seed\n", stderr)
    exit(1)
}

print(privateKey.publicKey.rawRepresentation.base64EncodedString())
