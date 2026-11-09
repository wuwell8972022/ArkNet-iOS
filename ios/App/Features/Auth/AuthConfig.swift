import Foundation

/// 账号流程的可切换项。
///
/// 官方后端当前**既不校验滑块验证码，也不下发邮箱验证码**，因此两项默认关闭：
/// 登录/注册按钮直接提交，`captchaId` / `captchaAnswer` / `code` 均不发送。
///
/// 等服务端开始要求时，把对应开关改为 `true` 即可——界面的滑块、验证码输入框
/// 与请求字段都已保留，无需改动其他代码。
enum AuthConfig {

    /// 是否启用滑块验证码（`/api/v1/auth/captcha`）。
    static let captchaEnabled = false

    /// 是否启用注册邮箱验证码（`/api/v1/auth/verification-codes`）。
    static let emailCodeEnabled = false
}
