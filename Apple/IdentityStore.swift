import Foundation
import Security

enum IdentityImportError: LocalizedError {
    case invalidFile, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidFile: String(localized: "Couldn’t read a TS3 identity from this file.")
        case .unavailable: String(localized: "The selected identity is unavailable.")
        }
    }
}

struct IdentityStore {
    var service = "org.opents-project.opents.identity.v1"

    private func item(importedUID: String? = nil) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: importedUID == nil ? service : service + ".imports",
         kSecAttrAccount: importedUID ?? "default"]
    }

    func loadOrCreate() throws -> String {
        if let existing = try load() { return existing }
        let identity = generateIdentity()
        let status = add(identity, to: item())
        if status == errSecDuplicateItem, let existing = try load() { return existing }
        guard status == errSecSuccess else { throw failure(status) }
        return identity
    }

    func forConnection(selectedUID: String?) throws -> String {
        guard let uid = selectedUID else { return try loadOrCreate() }
        guard let key = try load(importedUID: uid), storedIdentityUid(credential: key) == uid
        else { throw IdentityImportError.unavailable }
        return key
    }

    func importedUIDs() throws -> [String] {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service + ".imports",
                                      kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw failure(status) }
        guard let records = result as? [[String: Any]] else { throw failure(errSecDecode) }
        return records.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    func importFile(_ url: URL) throws -> (uid: String, added: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var contents = Data()
        do {
            let limit = 64 * 1024
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, (info.fileSize ?? 0) <= limit else { throw IdentityImportError.invalidFile }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            while contents.count <= limit,
                  let part = try file.read(upToCount: limit + 1 - contents.count), !part.isEmpty {
                contents.append(part)
            }
            guard contents.count <= limit else { throw IdentityImportError.invalidFile }
        } catch { throw IdentityImportError.invalidFile }
        return try importContents(contents)
    }

    func importContents(_ contents: Data) throws -> (uid: String, added: Bool) {
        guard let imported = parseIdentityExport(contents: contents) else { throw IdentityImportError.invalidFile }
        return (imported.uid, try save(imported))
    }

    private func save(_ imported: ImportedIdentity) throws -> Bool {
        if let current = try load(), storedIdentityUid(credential: current) == imported.uid { return false }
        let status = add(imported.credential, to: item(importedUID: imported.uid))
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw failure(status) }
        return true
    }

    private func add(_ credential: String, to item: [CFString: Any]) -> OSStatus {
        var record = item
        record[kSecValueData] = Data(credential.utf8)
        record[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(record as CFDictionary, nil)
    }

    private func load(importedUID: String? = nil) throws -> String? {
        var query = item(importedUID: importedUID)
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
