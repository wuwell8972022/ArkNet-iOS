import Foundation
import UIKit

/// App Group backed shared storage — the iOS counterpart of the Android app's
/// MMKV store. Holds endpoint lists, the tunnel profile, and lightweight
/// session state. Secrets (Bearer token) also live here so the tunnel
/// extension can read the disconnect fallback token.
enum SharedStore {

    static let appGroupID = "group.com.at.arknetprod2.ios"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    // MARK: Keys
    enum Key {
        static let bffEndpoints = "bff.endpoints"           // [String]
        static let primaryEndpoint = "bff.primary"          // String
        static let tunnelProfile = "tunnel.profile"         // Data (JSON)
        static let tunnelConfig = "tunnel.config"           // Data (sing-box JSON)
        static let disconnectToken = "auth.disconnectToken" // String
        static let deviceId = "device.id"                   // String (identifierForVendor)
        static let keepaliveProbeURL = "tunnel.probeURL"
    }

    // MARK: Endpoints

    static let defaultEndpoints = [
        "https://zz1.qjfifnbotx.top:14215",
        "https://zz2.qjfifnbotx.top:14215",
        "https://zz3.qjfifnbotx.top:14215"
    ]

    static var bffEndpoints: [String] {
        let stored = defaults.stringArray(forKey: Key.bffEndpoints) ?? []
        return stored.isEmpty ? defaultEndpoints : stored
    }

    static func updateEndpoints(_ list: [String]) {
        guard !list.isEmpty else { return }
        defaults.set(list, forKey: Key.bffEndpoints)
    }

    // MARK: Tunnel profile / config handoff to the extension

    static var tunnelProfile: Data? {
        get { defaults.data(forKey: Key.tunnelProfile) }
        set { newValue == nil ? defaults.removeObject(forKey: Key.tunnelProfile)
                              : defaults.set(newValue, forKey: Key.tunnelProfile) }
    }

    static var tunnelConfig: Data? {
        get { defaults.data(forKey: Key.tunnelConfig) }
        set { newValue == nil ? defaults.removeObject(forKey: Key.tunnelConfig)
                              : defaults.set(newValue, forKey: Key.tunnelConfig) }
    }

    static var disconnectToken: String? {
        get { defaults.string(forKey: Key.disconnectToken) }
        set { newValue == nil ? defaults.removeObject(forKey: Key.disconnectToken)
                              : defaults.set(newValue, forKey: Key.disconnectToken) }
    }

    /// Stable device identifier — iOS counterpart of Android's `deviceId`.
    ///
    /// Android derives it from `Settings.Secure.ANDROID_ID` (16 lowercase hex
    /// chars), so we keep the same shape to stay within anything the BFF may
    /// assume about the header value.
    static var deviceID: String {
        if let stored = defaults.string(forKey: Key.deviceId), isAndroidStyleID(stored) {
            return stored
        }
        let fresh = randomHexID()
        defaults.set(fresh, forKey: Key.deviceId)
        return fresh
    }

    private static func isAndroidStyleID(_ value: String) -> Bool {
        value.count == 16 && value.allSatisfy { $0.isHexDigit }
    }

    private static func randomHexID() -> String {
        var chars = ""
        for _ in 0..<16 {
            chars.append(Character(String(format: "%x", Int.random(in: 0..<16))))
        }
        return chars
    }
}

enum UIDeviceHelper {
    static var vendorIdentifier: String? {
        UIDevice.current.identifierForVendor?.uuidString
    }
}

/// Darwin-notification helpers — lightweight App Group change signalling
/// (no cross-process timers needed for one-shot events).
enum DarwinNotify {
    static let configChanged = "com.at.arknetprod2.ios.configChanged"

    static func post(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    static func observe(_ name: String, _ block: @escaping () -> Void) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passRetained(CallbackBox(block)).toOpaque()
        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let box = Unmanaged<CallbackBox>.fromOpaque(observer).takeRetainedValue()
                box.block()
            },
            name as CFString, nil, .deliverImmediately
        )
    }

    private final class CallbackBox {
        let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
    }
}
