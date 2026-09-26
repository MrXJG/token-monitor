import CryptoKit
import Foundation

/// Stores credentials in an app-owned encrypted file so normal reads do not
/// trigger macOS Keychain authorization prompts.
actor CredentialVault {
    private let credentialsURL: URL
    private let keyURL: URL

    init(service: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenMonitor", isDirectory: true)
        credentialsURL = directory.appendingPathComponent("credentials.bin")
        keyURL = directory.appendingPathComponent("credentials.key")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = service
    }

    func read(account: String) throws -> String? {
        try load()[account]
    }

    func saveLogin(sessionToken: String, sessionAccount: String, apiKey: String?, apiKeyAccount: String) throws {
        var values = try load()
        values[sessionAccount] = sessionToken
        if let apiKey, !apiKey.isEmpty {
            values[apiKeyAccount] = apiKey
        } else {
            values.removeValue(forKey: apiKeyAccount)
        }
        try save(values)
    }

    func saveSession(_ token: String, account: String) throws {
        var values = try load()
        values[account] = token
        try save(values)
    }

    func delete(sessionAccount: String, apiKeyAccount: String) {
        do {
            var values = try load()
            values.removeValue(forKey: sessionAccount)
            values.removeValue(forKey: apiKeyAccount)
            try save(values)
        } catch {
            // Match the previous Keychain delete behavior: logout remains
            // local even if a stale credential file cannot be removed.
        }
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: credentialsURL.path) else { return [:] }
        let combined = try Data(contentsOf: credentialsURL)
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let plaintext = try ChaChaPoly.open(box, using: try encryptionKey())
        return try JSONDecoder().decode([String: String].self, from: plaintext)
    }

    private func save(_ values: [String: String]) throws {
        let plaintext = try JSONEncoder().encode(values)
        let sealed = try ChaChaPoly.seal(plaintext, using: try encryptionKey())
        try sealed.combined.write(to: credentialsURL, options: [.atomic])
        try restrictPermissions(credentialsURL)
    }

    private func encryptionKey() throws -> SymmetricKey {
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let data = try Data(contentsOf: keyURL)
            guard data.count == 32 else { throw CredentialVaultError.invalidKey }
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: keyURL, options: [.atomic])
        try restrictPermissions(keyURL)
        return key
    }

    private func restrictPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum CredentialVaultError: LocalizedError {
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .invalidKey: "本地凭据密钥文件无效，请重新登录"
        }
    }
}
