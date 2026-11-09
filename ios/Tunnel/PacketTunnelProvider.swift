import Foundation
import NetworkExtension
import Libbox

/// Packet Tunnel Provider hosting the sing-box engine in-process.
///
/// Layering is identical to sing-box-for-apple (SFI): the extension conforms to
/// libbox's `CommandServerHandler` and `PlatformInterface` protocols and hosts a
/// `LibboxCommandServer`. gomobile generates ObjC names as
/// `Title(GoPkgName) + TypeName`, so everything from package `libbox` is
/// prefixed `Libbox`.
///
/// The config JSON is written by the app into the App Group store and re-read on
/// every reload — the iOS equivalent of Android's Box.startOrReload(optionsJSON).
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private var platform: TunnelPlatformInterface?
    private var started = false

    // MARK: - NE lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        setupLibbox()
        startEngine()
        completionHandler(nil)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        started = false
        if let commandServer {
            try? commandServer.closeService()
            commandServer.close()
        }
        commandServer = nil
        platform = nil
        TunnelStatusWriter.shared.setTunnelEstablished(false)
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        let reply: [String: Any] = [
            "engineStarted": started,
            "hasConfig": SharedStore.tunnelConfig != nil,
            "recentLogs": TunnelStatusWriter.shared.recentLogs
        ]
        completionHandler?(try? JSONSerialization.data(withJSONObject: reply))
    }

    // MARK: - libbox base paths (same container as the app process)

    private func setupLibbox() {
        let fm = FileManager.default
        guard let groupURL = fm.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroupID
        ) else {
            writeLog("app group container unavailable")
            return
        }
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
        do {
            try LibboxSetup(options)
        } catch {
            writeLog("libbox setup failed: \(error)")
        }
    }

    // MARK: - Engine control

    private func startEngine() {
        guard commandServer == nil else {
            reloadEngine()
            return
        }
        let platformInterface = TunnelPlatformInterface(self)
        platform = platformInterface
        do {
            let server = try LibboxNewCommandServer(self, platformInterface)
            try server.start()
            commandServer = server
            started = true
            reloadEngine()
        } catch {
            writeLog("command server start failed: \(error)")
            cancelTunnel(withError: NSError(domain: "ArkNetTunnel", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "引擎启动失败: \(error)"
            ]))
        }
    }

    private func reloadEngine() {
        guard let commandServer else {
            startEngine()
            return
        }
        guard let configData = SharedStore.tunnelConfig,
              let configJSON = String(data: configData, encoding: .utf8),
              !configJSON.isEmpty else {
            writeLog("no tunnel config in app group")
            cancelTunnel(withError: NSError(domain: "ArkNetTunnel", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "缺少隧道配置（App Group tunnel.config）"
            ]))
            return
        }
        do {
            // OverrideOptions is nil: the JSON already is the full profile.
            try commandServer.startOrReloadService(configJSON, options: nil)
            writeLog("startOrReloadService ok (\(configJSON.count) bytes)")
        } catch {
            writeLog("startOrReloadService failed: \(error)")
            commandServer.setError("\(error)")
        }
    }

    func writeLog(_ message: String) {
        NSLog("[ArkNetTunnel] \(message)")
        TunnelStatusWriter.shared.appendLog(message)
    }
}

// MARK: - libbox.CommandServerHandler

extension PacketTunnelProvider: LibboxCommandServerHandlerProtocol {

    func serviceStop() throws {
        started = false
        try commandServer?.closeService()
    }

    func serviceReload() throws {
        reloadEngine()
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        // Not applicable inside a Network Extension.
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        writeLog(message)
    }
}
