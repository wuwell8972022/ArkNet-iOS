import Foundation
import UIKit

/// BFF 请求头 —— 与 Android 客户端逐项对齐。
///
/// Android 侧在 `ArkApplication.onCreate` 里通过 `lk3.e(...)` 注册了 8 个头的
/// supplier（见反编译的 `defpackage/wf.java`），服务端按这份白名单校验；缺少任意
/// 一项会返回：
///     HTTP 400 {"code":9009,"msg":"header 参数错误"}
///
/// 对应关系（Android → iOS）：
///   channel-code         t54.p                       → "8e847e67"（内置常量）
///   device-id            t54.H()  ANDROID_ID/UUID    → SharedStore.deviceID（16 位 hex）
///   platform             常量 "android"              → 见下方说明
///   model                Build.MODEL                 → utsname.machine
///   locale               Locale.toLanguageTag()      → BCP-47
///   distribution-channel 常量 "free"                 → "free"
///   user-agent           System.getProperty("http.agent")
///   timezone             TimeZone.getDefault().getID()
enum ClientHeaders {

    /// 渠道号（Android `t54.p`），服务端下发/内置的固定值。
    static let channelCode = "8e847e67"

    /// 分发渠道（Android 常量）。
    static let distributionChannel = "free"

    /// 平台标识。
    ///
    /// 服务端目前只接受 Android 客户端，header 校验大概率按枚举匹配，因此这里
    /// 先沿用 "android" 以保证通过；iOS 正式上线、服务端放行后改为 "ios" 即可。
    static let platform = "android"

    static var deviceID: String { SharedStore.deviceID }

    /// 机型，等价 Build.MODEL，如 "iPhone15,2"。
    static var model: String {
        var info = utsname()
        guard uname(&info) == 0 else { return "iPhone" }
        return withUnsafeBytes(of: &info.machine) { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return "iPhone"
            }
            return String(cString: base)
        }
    }

    /// 与 Android `toLanguageTag()` 一致：`zh_CN` → `zh-CN`。
    static var locale: String {
        Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    }

    static var timeZone: String { TimeZone.current.identifier }

    /// Android 侧用 `System.getProperty("http.agent")`（Dalvik UA），可能被记入
    /// 设备列表展示；这里给出等价的可读 UA。
    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1"
        let os = UIDevice.current.systemVersion
        return "Dalvik/2.1.0 (Linux; U; iOS \(os); \(model) ArkNet/\(version))"
    }
}
