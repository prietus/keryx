import Foundation
import CryptoKit
import KeryxProtocol

/// An immutable snapshot of a `NetworkConfig` plus its resolved secrets, handed
/// to a `Session`, so the session never touches the Keychain or the store.
struct SessionConfig: Sendable, Identifiable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var useTLS: Bool
    var allowInvalidCertificates: Bool
    var nickname: String
    var username: String
    var realName: String
    var saslMode: SASLMode
    var saslAccount: String
    var saslPassword: String?
    var serverPassword: String?
    var isBouncer: Bool
    var autoJoinChannels: [String]
    var connectCommands: [String] = []
    /// Ask for joins, parts and the like in history (`draft/event-playback`).
    /// Off when you hide them anyway: a busy channel's history is then what
    /// people said, not page after page of comings and goings.
    var eventPlayback = true
    var certificateData: Data?
    var certificatePassphrase: String?
    /// Set when this session is bound to one soju network (its bouncer id).
    var boundNetworkID: String?
    /// The bouncer account this bound session belongs to.
    var parentID: UUID?

    init(id: UUID = UUID(), name: String = "", host: String, port: UInt16 = 6697,
         useTLS: Bool = true, nickname: String, saslMode: SASLMode = .none,
         saslAccount: String = "", saslPassword: String? = nil, isBouncer: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        allowInvalidCertificates = false
        self.nickname = nickname
        username = nickname
        realName = nickname
        self.saslMode = saslMode
        self.saslAccount = saslAccount
        self.saslPassword = saslPassword
        self.isBouncer = isBouncer
        autoJoinChannels = []
    }

    init(_ config: NetworkConfig, clientName: String) {
        id = config.id
        name = config.displayName
        host = config.host
        port = UInt16(clamping: config.port)
        useTLS = config.useTLS
        allowInvalidCertificates = config.allowInvalidCertificates
        nickname = config.nickname
        // soju keeps per-client history keyed on a `user@client` suffix, so this
        // install replays exactly what it missed. Only for a bouncer: a plain
        // network would read the suffix as part of the account name.
        let suffix = config.isBouncer ? "@\(clientName)" : ""
        username = (config.username.isEmpty ? config.nickname : config.username) + suffix
        realName = config.realName.isEmpty ? config.nickname : config.realName
        saslMode = config.saslMode
        saslAccount = (config.saslAccount.isEmpty ? config.nickname : config.saslAccount) + suffix
        saslPassword = config.saslPassword
        serverPassword = config.serverPassword
        isBouncer = config.isBouncer
        autoJoinChannels = config.autoJoinChannels
        connectCommands = config.connectCommands ?? []
        certificateData = config.certificateData
        certificatePassphrase = config.certificatePassphrase
    }

    /// A session bound to one soju network, reusing the account's credentials
    /// with a `/network` suffix on the username and SASL account.
    init(boundNetwork network: BouncerNetwork, base: SessionConfig) {
        func bind(_ value: String) -> String {
            // `user@client/network`: keep the client suffix, replace any network.
            let bare = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
            return "\(bare)/\(network.name)"
        }
        id = Self.stableID(base.id, network.id)
        name = network.name
        host = base.host
        port = base.port
        useTLS = base.useTLS
        allowInvalidCertificates = base.allowInvalidCertificates
        nickname = network.nickname ?? base.nickname
        username = bind(base.username)
        realName = base.realName
        saslMode = base.saslMode
        saslAccount = bind(base.saslAccount)
        saslPassword = base.saslPassword
        serverPassword = base.serverPassword
        isBouncer = true
        autoJoinChannels = []
        eventPlayback = base.eventPlayback
        certificateData = base.certificateData
        certificatePassphrase = base.certificatePassphrase
        boundNetworkID = network.id
        parentID = base.id
    }

    /// The same id every launch for the same account + bouncer network, so a
    /// bound session's scrollback and settings survive restarts.
    static func stableID(_ parent: UUID, _ networkID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(parent.uuidString)/\(networkID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    var isExplicitlyBound: Bool {
        boundNetworkID != nil || username.contains("/")
    }

    /// soju honours a `/network` binding only while the client does NOT take
    /// `soju.im/bouncer-networks`, so a bound session drops those caps.
    var desiredCaps: Set<String> {
        var caps = CapabilityName.desired
        if !eventPlayback { caps.remove(CapabilityName.eventPlayback) }
        if isExplicitlyBound {
            caps.subtract([CapabilityName.bouncerNetworks, CapabilityName.bouncerNetworksNotify])
        }
        return caps
    }

    var saslMechanism: SASLMechanism? {
        switch saslMode {
        case .none: return nil
        case .plain:
            guard let password = saslPassword else { return nil }
            return .plain(authcid: saslAccount, password: password)
        case .external: return .external()
        }
    }
}
