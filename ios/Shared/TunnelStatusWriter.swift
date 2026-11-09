import Foundation

/// Cross-process tunnel status hand-off (App Group + Darwin notifications).
///
/// On iOS the engine lives in the tunnel extension while traffic/status/logs
/// stream to the UI through libbox.CommandClient over the shared unix socket;
/// this writer additionally persists a small status snapshot so the UI can
/// render instantly on cold start without waiting for the socket handshake.
final class TunnelStatusWriter {

    static let shared = TunnelStatusWriter()

    private let defaults = SharedStore.defaults

    private enum Key {
        static let established = "tunnel.established"
        static let lastLog = "tunnel.lastLog"
        static let startedAt = "tunnel.startedAt"
    }

    // MARK: state

    func setTunnelEstablished(_ established: Bool) {
        defaults.set(established, forKey: Key.established)
        if established {
            defaults.set(Date().timeIntervalSince1970, forKey: Key.startedAt)
        }
        DarwinNotify.post(DarwinNotify.configChanged)
    }

    var isTunnelEstablished: Bool {
        defaults.bool(forKey: Key.established)
    }

    var startedAt: TimeInterval {
        defaults.double(forKey: Key.startedAt)
    }

    // MARK: log ring (last 32 lines surfaced in the UI debug sheet)

    private static let ringLimit = 32

    func appendLog(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var ring = defaults.stringArray(forKey: Key.lastLog) ?? []
        ring.append("[\(stamp)] \(message)")
        if ring.count > Self.ringLimit {
            ring.removeFirst(ring.count - Self.ringLimit)
        }
        defaults.set(ring, forKey: Key.lastLog)
    }

    var recentLogs: [String] {
        defaults.stringArray(forKey: Key.lastLog) ?? []
    }
}
