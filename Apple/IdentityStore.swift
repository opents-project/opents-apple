import Foundation
import Security

struct IdentityStore {
    var service = "org.opents-project.opents.identity.v1"

    private var item: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "default"]
    }

    func loadOrCreate() throws -> String {
        if let existing = try load() { return existing }
        let identity = generateIdentity()
        var record = item
        record[kSecValueData] = Data(identity.utf8)
        record[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(record as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try load() { return existing }
        guard status == errSecSuccess else { throw failure(status) }
        return identity
    }

    private func load() throws -> String? {
        var query = item
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { throw failure(errSecDecode) }
        return value
    }

    private func failure(_ status: OSStatus) -> NSError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: String(localized: "OpenTS identity (Keychain): \(detail)")])
    }
}
