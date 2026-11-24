import CryptoKit
import Foundation
import Security

@main
enum IdentityImportCheck {
    // Build a desktop-format INI in memory from a fresh synthetic key.
    private static func fixture(_ credential: String, counter: String? = nil) -> Data {
        let parts = credential.split(separator: "V", maxSplits: 1)
        var bytes = Array(parts[1].utf8)
        let mask = "b9dfaa7bee6ac57ac7b65f1094a1c155e747327bc2fe5d51c512023fe54a280201004e90ad1daaae1075d53b7d571c30e063".utf8
        for (i, byte) in mask.prefix(100).enumerated() { bytes[i] ^= byte }
        let hash = Insecure.SHA1.hash(data: Data(bytes.dropFirst(20).prefix { $0 != 0 }))
        for (i, byte) in hash.enumerated() { bytes[i] ^= byte }
        let value = (counter ?? String(parts[0])) + "V" + Data(bytes).base64EncodedString()
        return Data("[Identity]\r\nid=Synthetic\r\nidentity=\"\(value)\"\r\nnickname=Offline\r\n".utf8)
    }

    static func main() throws {
        let service = "org.opents-project.tests.identity." + UUID().uuidString
        let store = IdentityStore(service: service)
        defer {
            for name in [service, service + ".imports"] {
                let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: name] as CFDictionary)
                precondition(status == errSecSuccess || status == errSecItemNotFound)
            }
        }
        let original = try store.forConnection(selectedUID: nil)
        let originalImport = try store.importContents(fixture(original))
        precondition(!originalImport.added)
        let credential = generateIdentity()
        let uid = storedIdentityUid(credential: credential)!
        let imported = try store.importContents(fixture(credential))
        precondition(imported.uid == uid && imported.added)
        let duplicate = try store.importContents(fixture(credential, counter: "1"))
        precondition(duplicate.uid == uid && !duplicate.added)

        let reopened = IdentityStore(service: service)
        let active = try reopened.forConnection(selectedUID: nil)
        let selected = try reopened.forConnection(selectedUID: uid)
        precondition(active == original && selected == credential)
        do {
            _ = try reopened.forConnection(selectedUID: "missing")
            preconditionFailure("Missing selected UID must fail")
        } catch IdentityImportError.unavailable {}
        do {
            _ = try reopened.importContents(Data("[Identity]\nidentity=broken".utf8))
            preconditionFailure("Malformed file must fail")
        } catch IdentityImportError.invalidFile {}
        let saved = try reopened.importedUIDs()
        precondition(saved == [uid])
        print("PASS: synthetic INI, stable UID, Keychain reload, duplicates, explicit selection and invalid input")
    }
}
