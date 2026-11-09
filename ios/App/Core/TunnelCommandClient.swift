import Foundation
import Libbox

/// App-side engine client — libbox.CommandClient over the shared unix socket
/// (Swift counterpart of the Android app's in-process Box handle):
///   * writeStatus  → live traffic (per-interval + totals)
///   * writeLogs    → kernel log stream
///   * writeGroups  → node latency after urlTest
///   * serviceReload → ask the tunnel to re-read config.json (node/mode switch)
///
/// NOTE: this class is intentionally NOT `@MainActor`. It conforms to the
/// `@objc` protocol `LibboxCommandClientHandlerProtocol`, and actor isolation
/// would make its methods non-`@objc`, which the protocol rejects
/// ("non-'@objc' method ... does not satisfy requirement"). Callbacks arrive on
/// libbox threads, so every `@Published` mutation hops to the main queue.
final class TunnelCommandClient: NSObject, ObservableObject, LibboxCommandClientHandlerProtocol {

    static let shared = TunnelCommandClient()

    @Published private(set) var socketConnected = false
    @Published private(set) var uplinkBytes: Int64 = 0
    @Published private(set) var downlinkBytes: Int64 = 0
    @Published private(set) var uplinkTotal: Int64 = 0
    @Published private(set) var downlinkTotal: Int64 = 0
    @Published private(set) var connectionsIn: Int32 = 0
    @Published private(set) var connectionsOut: Int32 = 0
    @Published private(set) var nodeDelayMs: Int32 = -1
    @Published var kernelLogs: [String] = []

    private var client: LibboxCommandClient?
    private let logLock = NSLock()

    func resetDelay() {
        nodeDelayMs = -1
    }

    func connect() {
        guard client == nil else { return }
        TunnelSetup.setupBasePaths()

        let options = LibboxCommandClientOptions()
        options.statusInterval = 1
        options.addCommand(LibboxCommandStatus)
        options.addCommand(LibboxCommandLog)
        options.addCommand(LibboxCommandGroup)

        let client = LibboxNewCommandClient(self, options)
        self.client = client
        DispatchQueue.global(qos: .utility).async {
            do {
                try client.connect()
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.socketConnected = false
                    self?.appendLog("command client connect failed: \(error)")
                }
            }
        }
    }

    func disconnect() {
        try? client?.disconnect()
        client = nil
        socketConnected = false
    }

    /// Ask the tunnel extension to reload config.json (node/mode switch).
    func serviceReload() throws {
        try client?.serviceReload()
    }

    /// Measure the current node latency through the engine's urltest group.
    func urlTest() throws {
        try client?.urlTest("auto")
    }

    // MARK: - LibboxCommandClientHandlerProtocol

    func connected() {
        DispatchQueue.main.async { self.socketConnected = true }
    }

    func disconnected(_ message: String?) {
        DispatchQueue.main.async {
            self.socketConnected = false
            if let message, !message.isEmpty {
                self.appendLog("disconnected: \(message)")
            }
        }
    }

    func setDefaultLogLevel(_ level: Int32) {}

    func clearLogs() {
        DispatchQueue.main.async { self.kernelLogs.removeAll() }
    }

    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {
        guard let messageList else { return }
        var lines: [String] = []
        while messageList.hasNext() {
            if let entry = messageList.next() {
                lines.append("\(entry.level)|\(entry.message)")
            }
        }
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async {
            lines.forEach { self.appendLog($0) }
        }
    }

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message else { return }
        DispatchQueue.main.async {
            self.uplinkBytes = message.uplink
            self.downlinkBytes = message.downlink
            self.uplinkTotal = message.uplinkTotal
            self.downlinkTotal = message.downlinkTotal
            self.connectionsIn = message.connectionsIn
            self.connectionsOut = message.connectionsOut
        }
    }

    func writeGroups(_ groups: (any LibboxOutboundGroupIteratorProtocol)?) {
        guard let groups else { return }
        var delay: Int32 = -1
        while groups.hasNext() {
            guard let group = groups.next() else { continue }
            // getItems() is optional — unwrap before iterating.
            guard let items = group.getItems() else { continue }
            while items.hasNext() {
                if let item = items.next(), item.tag == "node" {
                    delay = item.urlTestDelay
                }
            }
        }
        DispatchQueue.main.async {
            if delay > 0 { self.nodeDelayMs = delay }
        }
    }

    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}

    func updateClashMode(_ newMode: String?) {}

    /// Go `WriteConnectionEvents` → Swift renames it to `write(_:)`.
    func write(_ events: LibboxConnectionEvents?) {}

    // MARK: - Log ring

    private func appendLog(_ line: String) {
        logLock.lock()
        defer { logLock.unlock() }
        kernelLogs.append(line)
        if kernelLogs.count > 200 {
            kernelLogs.removeFirst(kernelLogs.count - 200)
        }
        TunnelStatusWriter.shared.appendLog(line)
    }
}

/// libbox.Setup for the app process (same container paths as the extension).
enum TunnelSetup {
    private static var didSetup = false

    static func setupBasePaths() {
        guard !didSetup else { return }
        didSetup = true
        let fm = FileManager.default
        guard let groupURL = fm.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroupID
        ) else { return }
        let base = groupURL.appendingPathComponent("libbox", isDirectory: true)
        let working = base.appendingPathComponent("working", isDirectory: true)
        let temp = base.appendingPathComponent("temp", isDirectory: true)
        try? fm.createDirectory(at: working, withIntermediateDirectories: true)
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)

        let options = LibboxSetupOptions()
        options.basePath = base.path
        options.workingPath = working.path
        options.tempPath = temp.path
        options.commandServerListenPort = 0
        options.commandServerSecret = ""
        options.logMaxLines = 5000
        options.debug = false
        // C function, not a throwing method — pass the NSError out-param.
        var setupError: NSError?
        _ = LibboxSetup(options, &setupError)
    }
}
