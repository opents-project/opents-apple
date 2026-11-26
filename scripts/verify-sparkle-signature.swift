import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let publicKey = Data(base64Encoded: arguments[2]),
      let signature = Data(base64Encoded: arguments[3]),
      let verifier = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
      let archive = try? Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe),
      verifier.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("Sparkle signature does not match the archive and public key in the app.\n".utf8))
    exit(1)
}
