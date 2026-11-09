import Foundation

/// Builds the sing-box v1.13 options JSON consumed by the tunnel extension.
///
/// Faithful port of the Android `arknet.mobile` Profile semantics:
///  * inbound  = tun (IPv4 only, IPv6 hard-disabled like the Android client)
///  * fakeIP   = true by default (Profile.FakeIP)
///  * modes    = smart(分流) / global(全局) / specified(=smart, per-app N/A) / protect(断连保护)
///  * rule-set = bundled .srs (geoip-cn / geosite-cn / geosite-geolocation-!cn)
///  * outbound mapping per server-issued `proto` with Reality triad support
enum TunnelConfigBuilder {

    enum Mode: String {
        case smart, global, specified, protect
    }

    enum ConfigError: Error, LocalizedError {
        case unsupportedProtocol(String)
        case missingCredentials

        var errorDescription: String? {
            switch self {
            case .unsupportedProtocol(let proto):
                return "节点协议暂不支持: \(proto)"
            case .missingCredentials:
                return "节点凭据缺失（先连接获取 NodeConnectData）"
            }
        }
    }

    /// Everything the builder needs, straight from the BFF NodeConnectData.
    struct NodeProfile: Codable {
        var nodeId: String
        var proto: String          // vless / hysteria2 / trojan / shadowsocks / vmess / tuic
        var serverHost: String     // ingress
        var serverPort: Int        // listenPort
        var serverDomain: String?
        var password: String
        var security: String       // "reality" | "tls" | ""
        var tlsServerName: String?
        var realityServerName: String?
        var realityPublicKey: String?
        var realityShortID: String?
        var publicIp: String?

        init(connect: NodeConnectData, nodeId: String, serverDomain: String? = nil) {
            self.nodeId = nodeId
            proto = connect.proto
            serverHost = connect.ingress
            serverPort = connect.listenPort
            self.serverDomain = serverDomain ?? connect.ingress
            password = connect.password
            security = connect.security
            tlsServerName = connect.tlsServerName
            realityServerName = connect.securityConfig?.serverName
            realityPublicKey = connect.securityConfig?.publicKey
            realityShortID = connect.securityConfig?.shortId
            publicIp = connect.publicIp
        }
    }

    struct Input {
        var node: NodeProfile
        var mode: Mode = .smart
        var fakeIP: Bool = true
        /// RoutingRulesData.bypassAddresses — CIDRs forced to direct.
        var bypassAddresses: [String] = []
        /// Bundled rule-set paths (copied to a writable dir at first launch).
        var geositeCNPath: String?
        var geositeNotCNPath: String?
        var geoipCNPath: String?
        var logLevel: String = "info"
        var mtu: Int = 9000
    }

    // MARK: - Public entry

    static func build(_ input: Input) throws -> String {
        let node = input.node
        guard !node.serverHost.isEmpty, node.serverPort > 0, !node.password.isEmpty else {
            throw ConfigError.missingCredentials
        }

        var options: [String: Any] = [:]
        options["log"] = ["level": input.logLevel, "timestamp": true]
        options["dns"] = buildDNS(input)
        options["inbounds"] = [buildTunInbound(input)]
        options["outbounds"] = try buildOutbounds(node, mode: input.mode)
        options["route"] = try buildRoute(input)
        options["experimental"] = [
            "cache_file": [
                "enabled": true,
                "path": cacheFilePath(),
                "cache_id": "arknet"
            ]
        ]
        // "version": 3 — sing-box 1.12+ configuration version
        options["version"] = 3

        let data = try JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - DNS (v1.12+ server objects; fakeip as a server type)

    private static func buildDNS(_ input: Input) -> [String: Any] {
        var servers: [[String: Any]] = [
            [
                "tag": "dns-remote",
                "type": "https",
                "server": "8.8.8.8",
                "path": "/dns-query",
                "detour": "proxy"
            ],
            [
                "tag": "dns-direct",
                "type": "udp",
                "server": "223.5.5.5",
                "detour": "direct"
            ]
        ]
        var rules: [[String: Any]] = [
            // Resolve outbound server domains through the direct path.
            ["outbound": "any", "server": "dns-direct"]
        ]
        if input.fakeIP {
            servers.append([
                "tag": "dns-fakeip",
                "type": "fakeip",
                "inet4_range": "198.18.0.0/15"
            ])
            rules.append([
                "inbound": ["tun-in"],
                "query_type": ["A", "AAAA"],
                "server": "dns-fakeip"
            ])
        }
        if input.mode == .smart, input.geositeCNPath != nil {
            rules.append(["rule_set": ["geosite-cn", "geoip-cn"], "server": "dns-direct"])
        }
        rules.append(["rule_set": ["geosite-cn"], "server": "dns-direct"]) // CN domains resolve locally
        return [
            "servers": servers,
            "rules": rules,
            "final": "dns-remote",
            "independent_cache": true,
            "strategy": "ipv4_only"
        ]
    }

    // MARK: - TUN inbound (IPv4 only — ipv6Enabled=false parity)

    private static func buildTunInbound(_ input: Input) -> [String: Any] {
        [
            "type": "tun",
            "tag": "tun-in",
            "address": ["198.18.0.1/30"],
            "mtu": input.mtu,
            "auto_route": true,
            "strict_route": true,
            "stack": "gvisor"
        ]
    }

    // MARK: - Outbounds (protocol mapping + selector/urltest groups)

    /// Tag of the server-issued node outbound; referenced by the groups below.
    private static let nodeTag = "node"

    private static func buildOutbounds(_ node: NodeProfile, mode: Mode) throws -> [[String: Any]] {
        if mode == .protect {
            return [["type": "block", "tag": "block"]]
        }
        let nodeOutbound = try buildNodeOutbound(node)
        var outbounds: [[String: Any]] = [nodeOutbound]
        outbounds.append([
            "type": "urltest",
            "tag": "auto",
            "outbounds": [nodeTag],
            "url": "https://www.gstatic.com/generate_204",
            "interval": "5m",
            "tolerance": 50
        ])
        outbounds.append([
            "type": "selector",
            "tag": "proxy",
            "outbounds": ["auto", nodeTag],
            "default": "auto"
        ])
        outbounds.append(["type": "direct", "tag": "direct"])
        outbounds.append(["type": "block", "tag": "block"])
        outbounds.append(["type": "dns", "tag": "dns-out"])
        return outbounds
    }

    private static func buildNodeOutbound(_ node: NodeProfile) throws -> [String: Any] {
        var outbound: [String: Any] = [
            "tag": nodeTag,
            "server": node.serverHost,
            "server_port": node.serverPort
        ]
        let tlsBlock = buildTLS(node)
        if let tlsBlock {
            outbound["tls"] = tlsBlock
        }
        switch node.proto.lowercased() {
        case "vless":
            outbound["type"] = "vless"
            outbound["uuid"] = node.password
            outbound["packet_encoding"] = "xudp"
        case "vmess":
            outbound["type"] = "vmess"
            outbound["uuid"] = node.password
            outbound["security"] = "auto"
            outbound["alter_id"] = 0
        case "trojan":
            outbound["type"] = "trojan"
            outbound["password"] = node.password
        case "hysteria", "hysteria2":
            outbound["type"] = "hysteria2"
            outbound["password"] = node.password
        case let proto where proto.hasPrefix("shadowsocks"):
            outbound["type"] = "shadowsocks"
            outbound["password"] = node.password
            // method may ride along as "shadowsocks:<method>"; default 256-GCM
            if let idx = proto.firstIndex(of: ":") {
                outbound["method"] = String(proto[proto.index(after: idx)...])
            } else {
                outbound["method"] = "aes-256-gcm"
            }
        case "tuic":
            outbound["type"] = "tuic"
            outbound["uuid"] = node.password
            outbound["password"] = node.password
            outbound["congestion_control"] = "bbr"
            outbound["udp_relay_mode"] = "native"
        default:
            throw ConfigError.unsupportedProtocol(node.proto)
        }
        return outbound
    }

    /// TLS block with Reality triad (publicKey/shortId/serverName) parity.
    private static func buildTLS(_ node: NodeProfile) -> [String: Any]? {
        let isReality = node.security.lowercased() == "reality"
        let hasTLS = isReality || !(node.tlsServerName ?? "").isEmpty
            || node.security.lowercased() == "tls"
        guard hasTLS else { return nil }

        var tls: [String: Any] = [
            "enabled": true,
            "insecure": false,
            "utls": ["enabled": true, "fingerprint": "chrome"]
        ]
        if isReality {
            tls["server_name"] = node.realityServerName ?? node.tlsServerName ?? ""
            var reality: [String: Any] = ["enabled": true]
            reality["public_key"] = node.realityPublicKey ?? ""
            reality["short_id"] = node.realityShortID ?? ""
            tls["reality"] = reality
        } else if let sni = node.tlsServerName, !sni.isEmpty {
            tls["server_name"] = sni
        }
        return tls
    }

    // MARK: - Route (mode-driven rule chain)

    private static func buildRoute(_ input: Input) throws -> [String: Any] {
        var rules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"]
        ]
        var ruleSets: [[String: Any]] = []

        if input.mode != .global {
            if !input.bypassAddresses.isEmpty {
                rules.append(["ip_cidr": input.bypassAddresses, "outbound": "direct"])
            }
            if let geoip = input.geoipCNPath, let geosite = input.geositeCNPath {
                ruleSets.append(localRuleSet("geoip-cn", geoip))
                ruleSets.append(localRuleSet("geosite-cn", geosite))
                if let notCN = input.geositeNotCNPath {
                    ruleSets.append(localRuleSet("geosite-geolocation-!cn", notCN))
                }
                rules.append(["rule_set": ["geoip-cn", "geosite-cn"], "outbound": "direct"])
            }
        }

        var route: [String: Any] = [
            "rules": rules,
            "final": input.mode == .protect ? "block" : "proxy",
            "auto_detect_interface": false,   // iOS NE: provider traffic bypasses the tunnel
            "default_domain_resolver": ["server": "dns-direct"]
        ]
        if !ruleSets.isEmpty {
            route["rule_set"] = ruleSets
        }
        return route
    }

    private static func localRuleSet(_ tag: String, _ path: String) -> [String: Any] {
        ["type": "local", "tag": tag, "format": "binary", "path": path]
    }

    // MARK: - Paths

    /// App-group writable copy of the bundled .srs files (sing-box needs real
    /// file paths; the app bundle is read-only).
    static func prepareRuleSets() -> (geositeCN: String?, geositeNotCN: String?, geoipCN: String?) {
        let fm = FileManager.default
        guard let groupURL = fm.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroupID
        ) else {
            return (nil, nil, nil)
        }
        let dest = groupURL.appendingPathComponent("rule-set", isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        func copy(_ name: String) -> String? {
            // The bundler may sanitize '!' in resource names — try both forms.
            let candidates = [name, name.replacingOccurrences(of: "!", with: "_")]
            let source = candidates.lazy
                .compactMap { Bundle.main.url(forResource: $0, withExtension: "srs") }
                .first
            guard let source else { return nil }
            let target = dest.appendingPathComponent(name + ".srs")
            if !fm.fileExists(atPath: target.path) {
                try? fm.removeItem(at: target)
                try? fm.copyItem(at: source, to: target)
            }
            return target.path
        }
        return (
            geositeCN: copy("geosite-cn"),
            geositeNotCN: copy("geosite-geolocation-!cn"),
            geoipCN: copy("geoip-cn")
        )
    }

    static func cacheFilePath() -> String {
        let fm = FileManager.default
        guard let groupURL = fm.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.appGroupID
        ) else {
            return NSTemporaryDirectory() + "cache.db"
        }
        let dir = groupURL.appendingPathComponent("engine", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.db").path
    }
}
