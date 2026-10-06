import Foundation
import CryptoKit

// Verification uses only the public key; it never accesses the signing keychain.
let args = CommandLine.arguments
guard args.count == 4, let keyBytes = Data(base64Encoded: args[2]),
      let signature = Data(base64Encoded: args[3]) else { exit(2) }
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    exit(key.isValidSignature(signature, for: data) ? 0 : 1)
} catch { exit(1) }
