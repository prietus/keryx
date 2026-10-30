import Foundation
import Security
import KeryxProtocol

// MARK: - Locations

enum StoragePaths {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Keryx", directoryHint: .isDirectory)
    }

    static func file(_ name: String) -> URL { root.appending(path: name) }

    static func directory(_ name: String) -> URL {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Reads and writes small Codable documents atomically. Writes happen off the
/// main thread; encoding happens on the caller so main-actor state stays there.
enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Keychain

/// Per-network secrets, keyed `"<networkID>.<field>"`, never in the JSON files.
enum Keychain {
    private static let service = "im.keryx.secrets"

    static func set(_ value: String?, for key: String) {
        guard let value, !value.isEmpty else {
            remove(key)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Network definitions

enum SASLMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, plain, external
    var id: String { rawValue }
}

/// A saved network or bouncer. Secrets live in the Keychain.
struct NetworkConfig: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 6697
    var useTLS = true
    var allowInvalidCertificates = false
    var nickname = ""
    var username = ""
    var realName = ""
    var saslMode: SASLMode = .none
    var saslAccount = ""
    var isBouncer = false
    var autoConnect = true
    var autoJoinChannels: [String] = []
    /// PKCS#12 identity for CertFP, stored next to the config.
    var certificateData: Data?

    var displayName: String { name.isEmpty ? host : name }

    var saslPassword: String? {
        get { Keychain.get("\(id).sasl") }
        nonmutating set { Keychain.set(newValue, for: "\(id).sasl") }
    }

    var serverPassword: String? {
        get { Keychain.get("\(id).pass") }
        nonmutating set { Keychain.set(newValue, for: "\(id).pass") }
    }

    var certificatePassphrase: String? {
        get { Keychain.get("\(id).cert") }
        nonmutating set { Keychain.set(newValue, for: "\(id).cert") }
    }

    func forgetSecrets() {
        for field in ["sasl", "pass", "cert"] { Keychain.remove("\(id).\(field)") }
    }
}

enum NetworkStore {
    private static var url: URL { StoragePaths.file("networks.json") }

    static func load() -> [NetworkConfig] {
        JSONFile.load([NetworkConfig].self, from: url) ?? []
    }

    static func save(_ networks: [NetworkConfig]) {
        JSONFile.save(networks, to: url)
    }
}

// MARK: - Per-network state

/// Everything a network remembers between launches besides its scrollback:
/// ignores and dims, muted/pinned conversations, the MONITOR list, the
/// published profile and the bookkeeping for soju's metadata sync.
struct NetworkState: Codable, Sendable {
    var ignores: [IgnoreMask] = []
    /// Soft ignores: their lines stay, dimmed.
    var dimmed: [String] = []
    var muted: Set<String> = []
    var pinned: Set<String> = []
    var buddies: [String] = []
    /// Conversations where joins/parts are hidden entirely.
    var quietPresence: Set<String> = []
    var profile: [String: String] = [:]
    var publishedProfileKeys: Set<String> = []
    /// Per soju key, the targets flagged at the last sync (three-way merge base).
    var synced: [String: Set<String>] = [:]
    /// Spelling and word-completion language per conversation (lowercased
    /// name → "es", "en_GB", "off"). Optional so older saved state still loads.
    var languages: [String: String]?

    private static func url(_ id: UUID) -> URL {
        StoragePaths.directory("State").appending(path: "\(id.uuidString).json")
    }

    static func load(_ id: UUID) -> NetworkState {
        JSONFile.load(NetworkState.self, from: url(id)) ?? NetworkState()
    }

    func save(_ id: UUID) { JSONFile.save(self, to: Self.url(id)) }

    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }
}

// MARK: - STS

/// Persisted Strict Transport Security policies, host → (port, expiry).
enum STSStore {
    struct Entry: Codable { var port: UInt16; var expires: Date }

    private static var url: URL { StoragePaths.file("sts.json") }

    private static func all() -> [String: Entry] {
        JSONFile.load([String: Entry].self, from: url) ?? [:]
    }

    static func policy(for host: String) -> Entry? {
        guard let entry = all()[host.lowercased()], entry.expires > Date() else { return nil }
        return entry
    }

    /// Records (or, with a zero duration, clears) the policy for `host`.
    static func record(host: String, port: UInt16, duration: TimeInterval) {
        var entries = all().filter { $0.value.expires > Date() }
        if duration <= 0 {
            entries[host.lowercased()] = nil
        } else {
            entries[host.lowercased()] = Entry(port: port, expires: Date().addingTimeInterval(duration))
        }
        JSONFile.save(entries, to: url)
    }
}

// MARK: - Scrollback

/// On-disk scrollback per network so a cold launch shows conversations at
/// once; the server stays the source of truth (catch-up via CHATHISTORY AFTER,
/// msgid dedup drops the overlap).
enum HistoryStore {
    static let maxLinesPerBuffer = 1000

    struct Snapshot: Codable {
        var version = 1
        var buffers: [BufferSnapshot]
    }

    struct BufferSnapshot: Codable {
        var name: String
        var kind: Buffer.Kind
        var topic: String?
        var readMarker: Date?
        var historyExhausted: Bool
        var lines: [ChatLine]
    }

    private static func url(_ id: UUID) -> URL {
        StoragePaths.directory("History").appending(path: "\(id.uuidString).json")
    }

    static func load(_ id: UUID) -> Snapshot? {
        guard let snapshot = JSONFile.load(Snapshot.self, from: url(id)), snapshot.version == 1 else { return nil }
        return snapshot
    }

    static func save(_ snapshot: Snapshot, for id: UUID) { JSONFile.save(snapshot, to: url(id)) }

    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }
}
