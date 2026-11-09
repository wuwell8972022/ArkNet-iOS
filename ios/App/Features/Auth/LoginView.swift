import SwiftUI

/// 登录 — LoginActivity parity:
/// GET captcha → POST /auth/login {identifier, password, captchaId, captchaAnswer}
/// → LoginData (含 evictedDeviceId 顶号提示)。
struct LoginView: View {

    @EnvironmentObject private var session: UserSession
    @Environment(\.dismiss) private var dismiss

    @State private var identifier = ""
    @State private var password = ""
    @State private var captcha: CaptchaData?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var evictionNotice: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 30)

                Text("安心加速器").font(.title2).bold()

                field("用户名 / 邮箱", text: $identifier, isSecure: false)
                field("密码", text: $password, isSecure: true)

                if AuthConfig.captchaEnabled {
                    if let captcha {
                        SlideCaptchaView(
                            captcha: captcha,
                            onSuccess: { draggedX in
                                attemptLogin(captchaAnswer: String(draggedX))
                            },
                            onFail: { errorMessage = "验证未通过，请重试" }
                        )
                    } else {
                        Button("加载验证码") { loadCaptcha() }
                            .buttonStyle(.bordered)
                    }
                }

                if let evictionNotice {
                    Label(evictionNotice, systemImage: "person.2.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(Theme.danger)
                }

                Button {
                    if AuthConfig.captchaEnabled {
                        // 需先拿到验证码让用户滑动
                        if captcha == nil { loadCaptcha() }
                    } else {
                        attemptLogin(captchaAnswer: nil)
                    }
                } label: {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("登 录").bold()
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading)

                NavigationLink("没有账号？注册") {
                    RegisterView()
                }
                .font(.footnote)

                Spacer(minLength: 30)
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if AuthConfig.captchaEnabled { loadCaptcha() }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, isSecure: Bool) -> some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(Theme.textPrimary)
    }

    private func loadCaptcha() {
        errorMessage = nil
        Task {
            do {
                captcha = try await APIService().getCaptcha()
            } catch {
                errorMessage = "验证码获取失败: \(AppError.describe(error))"
            }
        }
    }

    private func attemptLogin(captchaAnswer: String?) {
        loading = true
        errorMessage = nil
        let useCaptcha = AuthConfig.captchaEnabled
        Task {
            do {
                let data = try await APIService().login(LoginRequest(
                    identifier: identifier,
                    password: password,
                    captchaId: useCaptcha ? captcha?.captchaId : nil,
                    captchaAnswer: useCaptcha ? captchaAnswer : nil,
                    email: nil
                ))
                session.applyLogin(data)
                if let evicted = data.evictedDeviceId, evicted > 0 {
                    evictionNotice = "已在当前设备登录（原设备 #\(evicted) 已被顶下线）"
                } else {
                    dismiss()
                }
            } catch {
                errorMessage = AppError.describe(error)
                if AuthConfig.captchaEnabled { loadCaptcha() }
            }
            loading = false
        }
    }
}

/// 注册 — RegisterView parity:
/// email verify code + captcha + inviteCode → POST /auth/register。
struct RegisterView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var inviteCode = ""
    @State private var captcha: CaptchaData?
    @State private var codeSent = false
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                field("邮箱", text: $email)
                if AuthConfig.emailCodeEnabled {
                    Button(codeSent ? "重新发送验证码" : "发送验证码") { sendCode() }
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    field("验证码", text: $code)
                }
                field("用户名", text: $username)
                field("密码", text: $password, secure: true)
                field("邀请码（选填）", text: $inviteCode)

                if AuthConfig.captchaEnabled {
                    if let captcha {
                        SlideCaptchaView(
                            captcha: captcha,
                            onSuccess: { draggedX in
                                register(captchaAnswer: String(draggedX))
                            },
                            onFail: { errorMessage = "验证未通过，请重试" }
                        )
                    } else {
                        Button("加载验证码") { loadCaptcha() }
                            .buttonStyle(.bordered)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(Theme.danger)
                }

                Button {
                    if AuthConfig.captchaEnabled {
                        if captcha == nil { loadCaptcha() }
                    } else {
                        register(captchaAnswer: nil)
                    }
                } label: {
                    if loading { ProgressView() } else { Text("注 册").bold() }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading)
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationTitle("注册")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if AuthConfig.captchaEnabled { loadCaptcha() }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool = false) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(Theme.textPrimary)
    }

    private func loadCaptcha() {
        Task { captcha = try? await APIService().getCaptcha() }
    }

    private func sendCode() {
        Task {
            do {
                try await APIService().sendVerificationCode(SendVerificationCodeRequest(
                    email: email, purpose: "register",
                    captchaId: nil, captchaAnswer: nil
                ))
                codeSent = true
            } catch {
                errorMessage = AppError.describe(error)
            }
        }
    }

    private func register(captchaAnswer: String?) {
        loading = true
        let useCaptcha = AuthConfig.captchaEnabled
        let useEmailCode = AuthConfig.emailCodeEnabled
        Task {
            do {
                _ = try await APIService().register(RegisterRequest(
                    email: email, username: username, password: password,
                    code: useEmailCode ? code : nil,
                    captchaId: useCaptcha ? captcha?.captchaId : nil,
                    captchaAnswer: useCaptcha ? captchaAnswer : nil,
                    inviteCode: inviteCode.isEmpty ? nil : inviteCode
                ))
                errorMessage = nil
                dismiss()
            } catch {
                errorMessage = AppError.describe(error)
            }
            loading = false
        }
    }
}
