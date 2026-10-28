import Foundation

/// An IRCv3 Strict Transport Security policy, advertised as the value of the
/// `sts` capability in `CAP LS` (e.g. `sts=port=6697,duration=2592000`).
///
/// On a plaintext connection only `port` matters: the client must drop the
/// link at once and reconnect with TLS on that port. On a TLS connection only
/// `duration` matters: for that many seconds, never connect to this host
/// without TLS again. A `duration` of 0 clears a stored policy.
public struct STSPolicy: Sendable, Equatable {
    public var port: UInt16?
    public var duration: TimeInterval?

    public init(port: UInt16? = nil, duration: TimeInterval? = nil) {
        self.port = port
        self.duration = duration
    }

    /// Parses the capability value. Unknown keys are ignored, as the spec asks.
    public init?(value: String) {
        var port: UInt16?
        var duration: TimeInterval?
        for pair in value.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "port": port = UInt16(kv[1])
            case "duration": duration = TimeInterval(kv[1])
            default: break
            }
        }
        guard port != nil || duration != nil else { return nil }
        self.init(port: port, duration: duration)
    }
}
