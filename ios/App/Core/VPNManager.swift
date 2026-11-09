import Foundation
import NetworkExtension

/// Connection orchestrator — the Swift port of the Android SpeedControl flow:
///
///   connect(node):
///     1. POST /api/v1/nodes/connect {nodeId} → NodeConnectData
///     2. checkNode(password) — credential validity (POST /nodes/check)
///     3. TunnelConfigBuilder.build(profile) → config JSON
///     4. persist profile+config to App Group, install/start VPN profile
///     5. CommandClient.connect() → status/traffic stream
///
///   switchNode/switchMode:
///     rebuild config → App Group → CommandClient.ServiceReload()
///
///   disconnect:
///     POST /api/v1/nodes/disconnect (Bearer or saved disconnect token) →
///     stop VPN session
@MainActor
final class VPNManager: ObservableObject {

    static let shared = VPNManager()

    enum ConnectionState: String {
        case disconnected, connecting, connected, disconnecting, error
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var currentNode: TunnelConfigBuilder.NodeProfile?
    @Published private(set) var mode: TunnelConfigBuilder.Mode
    @Published var lastError: String?

    private let api: APIService
    private let tunnelIdentifier: String

    init(api: APIService = APIService()) {
        self.api = api
        self.mode = TunnelConfigBuilder.Mode(
            rawValue: SharedStore.defaults.string(forKey: "tunnel.mode") ?? ""
        ) ?? .smart
        self.tunnelIdentifier = Bundle.main.bundleIdentifier.map { $0 + ".tunnel" }
            ?? "com.at.arknetprod2.ios.tunnel"
    }

    var isSelected: Bool { state == .connected || state == .connecting }

    // MARK: - Connect flow

    func connect(to node: NodeDto) async {
        state = .connecting
        lastError = nil
        do {
            guard UserSession.shared.isLoggedIn else {
                throw AppError.notLoggedIn
            }
            // 1. credentials from BFF
            let connectData = try await api.connectNode(node.nodeId)
            let profile = TunnelConfigBuilder.NodeProfile(
                connect: connectData,
                nodeId: node.nodeId,
                serverDomain: node.ingress
            )

            // 2. optional credential check (non-fatal)
            if !(await checkCredentialQuietly(connectData.password)) {
                // Server said invalid — surface but continue per Android
                // behaviour where check is advisory.
            }

            // 3. routing rules (bypass addresses)
            let bypass = (try? await api.getRoutingRules())?.bypassAddresses ?? []

            // 4. build config + persist
            try await buildAndPersist(profile: profile, bypass: bypass)

            // 5. start VPN
            try await startVPN()
            currentNode = profile
            state = .connected
        } catch {
            state = .error
            lastError = AppError.describe(error)
        }
    }

    func switchMode(_ newMode: TunnelConfigBuilder.Mode) async {
        guard let profile = currentNode else {
            mode = newMode
            persistMode(newMode)
            return
        }
        mode = newMode
        persistMode(newMode)
        do {
            let bypass = (try? await api.getRoutingRules())?.bypassAddresses ?? []
            try await buildAndPersist(profile: profile, bypass: bypass)
            try TunnelCommandClient.shared.serviceReload()
        } catch {
            lastError = AppError.describe(error)
        }
    }

    func reloadCurrentNode() async {
        guard let profile = currentNode else { return }
        do {
            let bypass = (try? await api.getRoutingRules())?.bypassAddresses ?? []
            try await buildAndPersist(profile: profile, bypass: bypass)
            try TunnelCommandClient.shared.serviceReload()
        } catch {
            lastError = AppError.describe(error)
        }
    }

    func disconnect() async {
        state = .disconnecting
        defer { state = .disconnected }
        // Server-side sign-out of the session (uses Bearer or the saved
        // disconnect fallback token inside the client).
        _ = try? await api.disconnectNode()
        do {
            try await stopVPN()
        } catch {
            lastError = AppError.describe(error)
        }
        currentNode = nil
        SharedStore.tunnelProfile = nil
        SharedStore.tunnelConfig = nil
    }

    // MARK: - Internals

    private func checkCredentialQuietly(_ password: String) async -> Bool {
        (try? await api.checkNode(password: password)) ?? true
    }

    private func buildAndPersist(
        profile: TunnelConfigBuilder.NodeProfile,
        bypass: [String]
    ) async throws {
        let rules = TunnelConfigBuilder.prepareRuleSets()
        let configJSON = try TunnelConfigBuilder.build(.init(
            node: profile,
            mode: mode,
            fakeIP: true,
            bypassAddresses: bypass,
            geositeCNPath: rules.geositeCN,
            geositeNotCNPath: rules.geositeNotCN,
            geoipCNPath: rules.geoipCN
        ))
        let profileData = try JSONEncoder().encode(profile)
        SharedStore.tunnelProfile = profileData
        SharedStore.tunnelConfig = Data(configJSON.utf8)
    }

    private func startVPN() async throws {
        let manager = try await loadManager()
        if manager.isEnabled == false {
            try await manager.saveToPreferences()
        }
        let enabled = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            manager.saveToPreferences { error in
                cont.resume(returning: error == nil)
            }
        }
        _ = enabled
        let loaded = try await loadManager()
        guard loaded.isEnabled else {
            throw AppError.vpnProfileDisabled
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loaded.connection.startVPNTunnel { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        TunnelCommandClient.shared.connect()
    }

    private func stopVPN() async throws {
        TunnelCommandClient.shared.disconnect()
        let manager = try await loadManager()
        guard manager.connection.status != .disconnected else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            manager.connection.stopVPNTunnel { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func loadManager() async throws -> NETunnelProviderManager {
        try await withCheckedThrowingContinuation { cont in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                let manager = managers?.first(where: { self.isOurs($0) }) ?? NETunnelProviderManager()
                let protocol_ = manager.protocolConfiguration as? NETunnelProviderProtocol
                    ?? NETunnelProviderProtocol()
                protocol_.providerBundleIdentifier = self.tunnelIdentifier
                protocol_.serverAddress = "ArkNet"
                protocol_.providerConfiguration = [
                    "profileName": "ArkNet Tunnel" as NSObject
                ]
                manager.protocolConfiguration = protocol_
                manager.localizedDescription = "安心加速器"
                manager.isEnabled = true
                cont.resume(returning: manager)
            }
        }
    }

    private func isOurs(_ manager: NETunnelProviderManager) -> Bool {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerBundleIdentifier == tunnelIdentifier
    }

    private func persistMode(_ newMode: TunnelConfigBuilder.Mode) {
        SharedStore.defaults.set(newMode.rawValue, forKey: "tunnel.mode")
    }
}

// MARK: - Errors

enum AppError: Error, LocalizedError {
    case notLoggedIn
    case vpnProfileDisabled
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "请先登录"
        case .vpnProfileDisabled: return "VPN 描述文件未启用（请在系统设置中允许）"
        case .underlying(let text): return text
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? AppError)?.errorDescription ?? error.localizedDescription
    }
}
