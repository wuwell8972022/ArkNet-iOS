import Foundation
import NetworkExtension
import ArkNet

/// Packet Tunnel Provider hosting the sing-box engine in-process.
///
/// Architecture (sing-box v1.13.0 libbox — identical layering to the Android
/// client whose VPNService implemented arknet.libbox.PlatformInterface):
///
///   PacketTunnelProvider
///    ├─ conforms libbox.CommandServerHandler (serviceStop / serviceReload)
///    ├─ TunnelPlatformInterface conforms libbox.PlatformInterface (openTun…)
///    │    wrapped by ArkNet.SafePlatform (nil-guard bridge, engine/bridge)
///    └─ CommandServer.startOrReloadService(configJSON, nil)
///
/// The UI drives lifecycle through the VPN profile (start/stop) and
/// CommandClient.ServiceReload(); the sing-box config JSON is handed over via
/// the App Group store (`tunnel.config`) — the same contract as Android's
/// Box.startOrReload(optionsJSON).
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: CommandServer?
    private var pathMonitor: PathMonitorBridge?
    private var engineStarted = false

    // MARK: - NE lifecycle

    override func startTunnel(
        with options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        setupBasePaths()
        establishPlaceholderTunnel(completionHandler: completionHandler)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        engineStarted = false
        pathMonitor?.stop()
        pathMonitor = nil
        if let server = commandServer {
            try? server.closeService()
            server.close()
        }
        commandServer = nil
        TunnelStatusWriter.shared.setTunnelEstablished(false)
        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        let reply: [String: Any] = [
            "engineStarted": engineStarted,
            "hasConfig": SharedStore.tunnelConfig != nil
        ]
        completionHandler?(try? JSONSerialization.data(withJSONObject: reply))
    }

    // MARK: - Base paths (libbox.Setup — same dir as the UI process)

    private func setupBasePaths() {
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

        let options = SetupOptions()
        options.basePath = base.path
        options.workingPath = working.path
        options.tempPath = temp.path
        options.commandServerListenPort = 0
        options.commandServerSecret = ""
        options.logMaxLines = 5000
        options.debug = false
        do {
            try Setup(options)
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
        let platform = TunnelPlatformInterface(provider: self)
        do {
            // SafePlatform = nil-guard bridge from engine/bridge (Go).
            let safePlatform = try SafePlatform(platform)
            let server = try CommandServer(self, safePlatform)
            try server.start()
            commandServer = server
            engineStarted = true
            reloadEngine()
        } catch {
            writeLog("command server start failed: \(error)")
            cancelTunnel(withError: NSError(
                domain: "ArkNetTunnel", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "引擎启动失败: \(error)"]
            ))
        }
    }

    private func reloadEngine() {
        guard let server = commandServer else {
            startEngine()
            return
        }
        guard let configData = SharedStore.tunnelConfig,
              let configJSON = String(data: configData, encoding: .utf8),
              !configJSON.isEmpty else {
            writeLog("no tunnel config in app group")
            cancelTunnel(withError: NSError(
                domain: "ArkNetTunnel", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "缺少隧道配置（App Group tunnel.config）"]
            ))
            return
        }
        do {
            try server.startOrReloadService(configJSON, nil)
            writeLog("startOrReloadService ok (\(configJSON.count) bytes)")
        } catch {
            writeLog("startOrReloadService failed: \(error)")
            server.setError("\(error)")
        }
    }

    // MARK: - TUN bootstrap

    /// Phase 1: establish a placeholder flow so packetFlow exists; the engine
    /// immediately calls openTun() with authoritative TunOptions (phase 2).
    private func establishPlaceholderTunnel(completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        settings.mtu = 9000
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: "0.0.0.0", destinationSubnetMask: "0.0.0.0")
        ]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.2"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                completionHandler(error)
                return
            }
            self.startEngine()
            completionHandler(nil)
        }
    }

    func writeLog(_ message: String) {
        NSLog("[ArkNetTunnel] \(message)")
        TunnelStatusWriter.shared.appendLog(message)
    }
}

// MARK: - libbox.CommandServerHandler conformance

extension PacketTunnelProvider: CommandServerHandler {

    func serviceStop() throws {
        engineStarted = false
        if let server = commandServer {
            try? server.closeService()
        }
    }

    func serviceReload() throws {
        reloadEngine()
    }

    func getSystemProxyStatus() throws -> SystemProxyStatus? {
        let status = SystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {
        // Not applicable inside a Network Extension.
    }

    func writeDebugMessage(_ message: String) {
        writeLog(message)
    }
}

// MARK: - libbox.PlatformInterface (Swift side, wrapped by ArkNet.SafePlatform)

final class TunnelPlatformInterface: NSObject, PlatformInterface {

    weak var provider: PacketTunnelProvider?
    private var heldListener: InterfaceUpdateListener?

    init(provider: PacketTunnelProvider?) {
        self.provider = provider
        super.init()
    }

    /// Engine → fd hand-off: configure NE settings from TunOptions, then
    /// return the packetFlow utun file descriptor (KVC, same as sing-box SFI).
    func openTun(_ tunOptions: TunOptions?) throws -> Int32 {
        guard let provider, let options = tunOptions else { return 0 }
        provider.writeLog("openTun: mtu=\(options.getMTU()) autoRoute=\(options.getAutoRoute())")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        settings.mtu = options.getMTU()

        var addresses: [String] = []
        var masks: [String] = []
        let prefixes = options.getInet4Address()
        while prefixes.hasNext() {
            let routePrefix = prefixes.next()
            addresses.append(routePrefix.address())
            masks.append(routePrefix.mask())
        }
        if addresses.isEmpty {
            addresses = ["198.18.0.1"]
            masks = ["255.255.255.252"]
        }
        let ipv4 = NEIPv4Settings(addresses: addresses, subnetMasks: masks)
        if options.getAutoRoute() {
            ipv4.includedRoutes = [
                NEIPv4Route(destinationAddress: "0.0.0.0", destinationSubnetMask: "0.0.0.0")
            ]
            // Excluded routes from the engine (bypassAddresses parity).
            var excluded: [NEIPv4Route] = []
            let exclude = options.getInet4RouteExcludeAddress()
            while exclude.hasNext() {
                let routePrefix = exclude.next()
                let parts = routePrefix.address().split(separator: "/")
                if parts.count == 2,
                   let bits = Int(parts[1]),
                   let mask = IPv4Mask.dotted(bits) {
                    excluded.append(NEIPv4Route(
                        destinationAddress: String(parts[0]),
                        destinationSubnetMask: mask
                    ))
                }
            }
            ipv4.excludedRoutes = excluded
        }
        settings.ipv4Settings = ipv4

        let dnsServers = options.getDNSServerAddress()?.value
        settings.dnsSettings = NEDNSSettings(
            servers: (dnsServers?.isEmpty == false) ? [dnsServers!] : ["198.18.0.2"]
        )

        // setTunnelNetworkSettings must complete before the fd is usable.
        let semaphore = DispatchSemaphore(value: 0)
        provider.setTunnelNetworkSettings(settings) { _ in semaphore.signal() }
        semaphore.wait()

        // KVC: NEPacketTunnelFlow exposes the utun file descriptor.
        guard let fd = provider.packetFlow.value(forKey: "fileDescriptor") as? Int32, fd > 0 else {
            provider.writeLog("openTun: packetFlow fd unavailable")
            return 0
        }
        provider.writeLog("openTun: established fd=\(fd)")
        TunnelStatusWriter.shared.setTunnelEstablished(true)
        return fd
    }

    // MARK: interface binding (NE provider traffic bypasses the VPN)

    func usePlatformAutoDetectInterfaceControl() -> Bool { false }

    func autoDetectInterfaceControl(_ fd: Int32) throws {}

    func useProcFS() -> Bool { false }

    func findConnectionOwner(
        _ ipProtocol: Int32, _ sourceAddress: String, _ sourcePort: Int32,
        _ destinationAddress: String, _ destinationPort: Int32
    ) throws -> ConnectionOwner? { nil }

    // MARK: default interface monitor via NWPathMonitor

    func startDefaultInterfaceMonitor(_ listener: InterfaceUpdateListener?) throws {
        guard let listener else { return }
        heldListener = listener
        let bridge = PathMonitorBridge(listener: listener)
        bridge.start()
        provider?.pathMonitor = bridge
    }

    func closeDefaultInterfaceMonitor(_ listener: InterfaceUpdateListener?) throws {
        provider?.pathMonitor?.stop()
        provider?.pathMonitor = nil
        heldListener = nil
    }

    // MARK: interfaces / extension facts

    func getInterfaces() throws -> NetworkInterfaceIterator? {
        NetworkInterfacesCollector.collect()
    }

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool { false }

    func readWIFIState() throws -> WIFIState? { nil }

    func systemCertificates() throws -> StringIterator? { nil }

    func clearDNSCache() {}

    func sendNotification(_ notification: ArkNet.Notification?) throws {
        guard let notification else { return }
        provider?.writeLog("notification: \(notification.title) \(notification.body)")
    }

    func localDNSTransport() throws -> LocalDNSTransport? { nil }
}

// MARK: - Default interface monitor bridge

final class PathMonitorBridge {
    private let listener: InterfaceUpdateListener
    private let monitor = NWPathMonitor()

    init(listener: InterfaceUpdateListener) {
        self.listener = listener
    }

    func start() {
        monitor.pathUpdateHandler = { [listener] path in
            let interface = path.availableInterfaces.first
            let name = interface?.name ?? ""
            let index = Int32(interface?.index ?? 0)
            listener.updateDefaultInterface(name, index, path.isExpensive, path.isConstrained)
        }
        monitor.start(queue: DispatchQueue(label: "arknet.pathMonitor"))
    }

    func stop() {
        monitor.cancel()
    }
}

// MARK: - getifaddrs collector (getInterfaces parity with Android mi0.e())

enum NetworkInterfacesCollector {

    static func collect() -> NetworkInterfaceIterator? {
        var result: [NetworkInterface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var seen = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let rawName = current.pointee.ifa_name,
                  let name = String(validatingUTF8: rawName),
                  seen.insert(name).inserted,
                  let addrPtr = current.pointee.ifa_addr else { continue }

            var addr = sockaddr()
            memcpy(&addr, addrPtr, min(Int(addrPtr.pointee.sa_len), MemoryLayout<sockaddr>.size))
            guard addr.sa_family == sa_family_t(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addrPtr, socklen_t(addr.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            guard status == 0, let ip = String(validatingUTF8: host) else { continue }

            let item = NetworkInterface()
            item.index = Int32(current.pointee.ifa_index)
            item.mtu = 1500
            item.name = name
            item.addresses = SwiftStringIterator([ip])
            item.flags = 0
            item.type = InterfaceTypeWIFI
            result.append(item)
        }
        return NetworkInterfaceArrayIterator(result)
    }
}

// MARK: - Swift-side iterators (gomobile StringIterator/NetworkInterfaceIterator)

final class SwiftStringIterator: NSObject, StringIterator {
    private var items: [String]
    private var index = 0
    init(_ items: [String]) { self.items = items }
    func len() -> Int32 { Int32(items.count) }
    func hasNext() -> Bool { index < items.count }
    func next() -> String { defer { index += 1 }; return items[index] }
}

final class NetworkInterfaceArrayIterator: NSObject, NetworkInterfaceIterator {
    private var items: [NetworkInterface]
    private var index = 0
    init(_ items: [NetworkInterface]) { self.items = items }
    func len() -> Int32 { Int32(items.count) }
    func hasNext() -> Bool { index < items.count }
    func next() -> NetworkInterface? { defer { index += 1 }; return items[index] }
}

// MARK: - IPv4 helpers

enum IPv4Mask {
    static func dotted(_ prefixBits: Int) -> String? {
        guard (0...32).contains(prefixBits) else { return nil }
        let value: UInt32 = prefixBits == 0 ? 0 : (~UInt32(0) << (32 - UInt32(prefixBits)))
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ]
        return bytes.map(String.init).joined(separator: ".")
    }
}
