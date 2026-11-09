import Foundation
import NetworkExtension
import Libbox

/// libbox.PlatformInterface implementation for the Packet Tunnel Provider.
///
/// Signatures follow sing-box-for-apple's ExtensionPlatformInterface because
/// gomobile's Objective-C generator dictates them exactly:
///   * Go interface `Foo` → ObjC protocol `LibboxFooProtocol`
///   * Go `(T, error)` → Swift `throws` with an out-pointer (`ret0_`) for T
///   * Go interface returns are nullable ObjC objects
///
/// iOS-irrelevant facets return nil / empty values directly (same as SFI):
/// libbox guards these paths, so no extra Go-side wrapper package is needed.
final class TunnelPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {

    private weak var provider: PacketTunnelProvider?
    private var nwMonitor: NWPathMonitor?
    private var lastNetworkPath: String?
    private var networkSettings: NEPacketTunnelNetworkSettings?

    init(_ provider: PacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    // MARK: - TUN hand-off (engine → fd)

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else {
            throw NSError(domain: "ArkNetTunnel", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "openTun: nil options or return pointer"
            ])
        }
        guard let provider else {
            throw NSError(domain: "ArkNetTunnel", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "openTun: provider deallocated"
            ])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            if let dnsServer = try? options.getDNSServerAddress().value, !dnsServer.isEmpty {
                settings.dnsSettings = NEDNSSettings(servers: [dnsServer])
            }

            var ipv4Addresses: [String] = []
            var ipv4Masks: [String] = []
            let ipv4AddressIterator = options.getInet4Address()!
            while ipv4AddressIterator.hasNext() {
                let prefix = ipv4AddressIterator.next()!
                ipv4Addresses.append(prefix.address())
                ipv4Masks.append(prefix.mask())
            }
            if !ipv4Addresses.isEmpty {
                let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)

                var includedRoutes: [NEIPv4Route] = []
                let routeIterator = options.getInet4RouteAddress()!
                if routeIterator.hasNext() {
                    while routeIterator.hasNext() {
                        let prefix = routeIterator.next()!
                        includedRoutes.append(NEIPv4Route(
                            destinationAddress: prefix.address(),
                            subnetMask: prefix.mask()
                        ))
                    }
                } else {
                    includedRoutes.append(NEIPv4Route.default())
                }

                var excludedRoutes: [NEIPv4Route] = []
                let excludeIterator = options.getInet4RouteExcludeAddress()!
                while excludeIterator.hasNext() {
                    let prefix = excludeIterator.next()!
                    excludedRoutes.append(NEIPv4Route(
                        destinationAddress: prefix.address(),
                        subnetMask: prefix.mask()
                    ))
                }
                ipv4Settings.includedRoutes = includedRoutes
                ipv4Settings.excludedRoutes = excludedRoutes
                settings.ipv4Settings = ipv4Settings
            }

            // IPv6: the Android client hard-disables IPv6 (`ipv6Enabled=false`)
            // and the generated config is IPv4-only, so only apply IPv6 when
            // the engine actually supplied addresses.
            var ipv6Addresses: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            let ipv6AddressIterator = options.getInet6Address()!
            while ipv6AddressIterator.hasNext() {
                let prefix = ipv6AddressIterator.next()!
                ipv6Addresses.append(prefix.address())
                ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
            }
            if !ipv6Addresses.isEmpty {
                let ipv6Settings = NEIPv6Settings(
                    addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes
                )
                var routes: [NEIPv6Route] = []
                let routeIterator = options.getInet6RouteAddress()!
                if routeIterator.hasNext() {
                    while routeIterator.hasNext() {
                        let prefix = routeIterator.next()!
                        routes.append(NEIPv6Route(
                            destinationAddress: prefix.address(),
                            networkPrefixLength: NSNumber(value: prefix.prefix())
                        ))
                    }
                } else {
                    routes.append(NEIPv6Route.default())
                }
                ipv6Settings.includedRoutes = routes

                var excluded: [NEIPv6Route] = []
                let excludeIterator = options.getInet6RouteExcludeAddress()!
                while excludeIterator.hasNext() {
                    let prefix = excludeIterator.next()!
                    excluded.append(NEIPv6Route(
                        destinationAddress: prefix.address(),
                        networkPrefixLength: NSNumber(value: prefix.prefix())
                    ))
                }
                ipv6Settings.excludedRoutes = excluded
                settings.ipv6Settings = ipv6Settings
            }

            // DNS must not be intercepted when the default route is excluded.
            let hasDefaultRoute = (settings.ipv4Settings?.includedRoutes ?? []).contains {
                $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
            }
            if !hasDefaultRoute {
                settings.dnsSettings?.matchDomains = [""]
                settings.dnsSettings?.matchDomainsNoSearch = true
            }
        }

        networkSettings = settings
        try runBlocking { try await provider.setTunnelNetworkSettings(settings) }

        // NEPacketTunnelFlow's utun descriptor, then the loopback fallback.
        if let tunFd = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFd
            provider.writeLog("openTun: fd=\(tunFd)")
            return
        }
        throw NSError(domain: "ArkNetTunnel", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "openTun: packet flow file descriptor unavailable"
        ])
    }

    // MARK: - Interface binding

    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_ fd: Int32) throws {}

    func useProcFS() -> Bool { false }

    func findConnectionOwner(
        _ ipProtocol: Int32,
        sourceAddress: String?,
        sourcePort: Int32,
        destinationAddress: String?,
        destinationPort: Int32
    ) throws -> LibboxConnectionOwner {
        throw NSError(domain: "ArkNetTunnel", code: 0, userInfo: [
            NSLocalizedDescriptionKey: "findConnectionOwner is unsupported on iOS"
        ])
    }

    // MARK: - Default interface monitor

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        nwMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateDefaultInterface(listener, path)
            semaphore.signal()
        }
        monitor.start(queue: DispatchQueue.global())
        semaphore.wait()
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        nwMonitor?.cancel()
        nwMonitor = nil
        lastNetworkPath = nil
    }

    private func updateDefaultInterface(
        _ listener: LibboxInterfaceUpdateListenerProtocol,
        _ path: Network.NWPath
    ) {
        let description = describe(path)
        if description == lastNetworkPath {
            return
        }
        lastNetworkPath = description
        guard path.status != .unsatisfied,
              let defaultInterface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(
            defaultInterface.name,
            interfaceIndex: Int32(defaultInterface.index),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    private func describe(_ path: Network.NWPath) -> String {
        var parts: [String] = ["\(path.status)"]
        parts.append(path.availableInterfaces.map { "\($0.name)#\($0.index)" }.joined(separator: ","))
        parts.append("ipv4:\(path.supportsIPv4) ipv6:\(path.supportsIPv6) dns:\(path.supportsDNS)")
        parts.append("expensive:\(path.isExpensive) constrained:\(path.isConstrained)")
        return parts.joined(separator: " ")
    }

    // MARK: - Interfaces

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let nwMonitor else {
            throw NSError(domain: "ArkNetTunnel", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "getInterfaces: monitor not started"
            ])
        }
        let path = nwMonitor.currentPath
        if path.status == .unsatisfied {
            return NetworkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for item in path.availableInterfaces {
            let interface = LibboxNetworkInterface()
            interface.name = item.name
            interface.index = Int32(item.index)
            interface.mtu = 1500
            switch item.type {
            case .wifi:
                interface.type = LibboxInterfaceTypeWIFI
            case .cellular:
                interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                interface.type = LibboxInterfaceTypeEthernet
            default:
                interface.type = LibboxInterfaceTypeOther
            }
            interfaces.append(interface)
        }
        return NetworkInterfaceArray(interfaces)
    }

    /// Iterator adapter required by LibboxNetworkInterfaceIteratorProtocol.
    final class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var nextValue: LibboxNetworkInterface?

        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }

    // MARK: - Extension facts

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool { false }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    func clearDNSCache() {
        guard let networkSettings, let provider else { return }
        provider.reasserting = true
        defer { provider.reasserting = false }
        try? runBlocking { try await provider.setTunnelNetworkSettings(nil) }
        try? runBlocking { try await provider.setTunnelNetworkSettings(networkSettings) }
    }

    /// Go `SendNotification(notification *Notification) error`.
    /// Swift's ObjC importer renames `sendNotification:` to `send(_:)`
    /// (the same reason sing-box-for-apple declares it as `send`).
    func send(_ notification: LibboxNotification?) throws {
        guard let notification else { return }
        provider?.writeLog("notification: \(notification.title) \(notification.body)")
    }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
}

// MARK: - async → sync bridging (sing-box-for-apple pattern)

/// Runs an async operation from a synchronous libbox callback thread.
func runBlocking<T>(_ block: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task {
        do {
            result = .success(try await block())
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
