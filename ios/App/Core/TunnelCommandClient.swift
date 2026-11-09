import Foundation
import ArkNet

/// App-side engine client — libbox.CommandClient over the shared unix socket
/// (the Swift counterpart of the Android app's in-process Box handle):
///   * WriteStatus → live traffic (Uplink/Downlink per interval + totals)
///   * WriteLogs   → kernel log stream
///   * WriteGroups → node latency (URLTestDelay) after commandClient.URLTest
///   * ServiceReload → ask the tunnel to re-read config.json (switch node/mode)
@MainActor
final class TunnelCommandClient: NSObject, CommandClientHandler, ObservableObject {

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

    /// NodeSelectView latency test starts from a clean state.
    func resetDelay() {
        nodeDelayMs = -1
    }

    private var client: CommandClient?

    func connect() {
        guard client == nil else { return }
        // Setup must run in the UI process too — same base path as the tunnel.
        TunnelSetup.setupBasePaths()

        let options = CommandClientOptions()
        options.statusInterval = 1   // seconds
        options.addCommand(CommandStatus)
        options.addCommand(CommandLog)
        options.addCommand(CommandGroup)

        let client = CommandClient(self, options)
        self.client = client
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try client.connect()
                _ = self
            } catch {
                Task { @MainActor [weak self] in
                    self?.connected = false
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

    /// Measure current node latency via the engine's urltest group.
    func urlTest() throws {
        try client?.urlTest("auto")
    }

    // MARK: - CommandClientHandler conformance

    nonisolated func connected() {
        Task { @MainActor in
            self.socketConnected = true
        }
    }

    nonisolated func disconnected(message: String) {
        Task { @MainActor in
            self.socketConnected = false
            if !message.isEmpty {
                self.appendLog("disconnected: \(message)")
            }
        }
    }

    nonisolated func setDefaultLogLevel(_ level: Int32) {}

    nonisolated func clearLogs() {
        Task { @MainActor in self.kernelLogs.removeAll() }
    }

    nonisolated func writeLogs(_ messageList: LogIterator?) {
        guard let messageList else { return }
        var lines: [String] = []
        while messageList.hasNext() {
            if let entry = messageList.next() {
                lines.append("\(entry.level)|\(entry.message)")
            }
        }
        Task { @MainActor in
            lines.forEach { self.appendLog($0) }
        }
    }

    nonisolated func writeStatus(_ message: StatusMessage?) {
        guard let message else { return }
        Task { @MainActor in
            self.uplinkBytes = message.uplink
            self.downlinkBytes = message.downlink
            self.uplinkTotal = message.uplinkTotal
            self.downlinkTotal = message.downlinkTotal
            self.connectionsIn = message.connectionsIn
            self.connectionsOut = message.connectionsOut
        }
    }

    nonisolated func writeGroups(_ groups: OutboundGroupIterator?) {
        guard let groups else { return }
        var delay: Int32 = -1
        while groups.hasNext() {
            if let group = groups.next() {
                let items = group.getItems()
                while items.hasNext() {
                    if let item = items.next(), item.tag == "node" {
                        delay = item.urlTestDelay
                    }
                }
            }
        }
        Task { @MainActor in
            if delay > 0 { self.nodeDelayMs = delay }
        }
    }

    nonisolated func initializeClashMode(_ modeList: StringIterator?, currentMode: String) {}
    nonisolated func updateClashMode(_ newMode: String) {}
    nonisolated func writeConnectionEvents(_ events: ConnectionEvents?) {}

    @MainActor
    private func appendLog(_ line: String) {
        kernelLogs.append(line)
        if kernelLogs.count > 200 {
            kernelLogs.removeFirst(kernelLogs.count - 200)
        }
    }
}

/// libbox.Setup for the app process (mirror of the tunnel's call).
enum TunnelSetup {
    static var didSetup = false

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

        let options = SetupOptions()
        options.basePath = base.path
        options.workingPath = working.path
        options.tempPath = temp.path
        options.commandServerListenPort = 0
        options.commandServerSecret = ""
        options.logMaxLines = 5000
        options.debug = false
        _ = try? Setup(options)
    }
}
